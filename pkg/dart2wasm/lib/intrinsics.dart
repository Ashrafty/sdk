// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class Intrinsifier {
  final CodeGenerator codeGen;
  final w.ValueType boolType;
  final w.ValueType intType;
  final w.ValueType doubleType;

  late final Map<w.ValueType, Map<String, Map<w.ValueType, CodeGenCallback>>>
      binaryOperatorMap;
  late final Map<w.ValueType, Map<String, CodeGenCallback>> unaryOperatorMap;
  late final Map<String, w.ValueType> unaryResultMap;

  Translator get translator => codeGen.translator;
  w.Instructions get b => codeGen.b;

  DartType dartTypeOf(Expression exp) {
    return exp.getStaticType(codeGen.typeContext);
  }

  w.ValueType typeOfExp(Expression exp) {
    return translator.translateType(dartTypeOf(exp));
  }

  static bool isComparison(String op) =>
      op == '<' || op == '<=' || op == '>' || op == '>=';

  Intrinsifier(this.codeGen)
      : boolType = w.NumType.i32,
        intType = w.NumType.i64,
        doubleType = w.NumType.f64 {
    binaryOperatorMap = {
      intType: {
        '+': {intType: (b) => b.i64_add()},
        '-': {intType: (b) => b.i64_sub()},
        '*': {intType: (b) => b.i64_mul()},
        '~/': {intType: (b) => b.i64_div_s()},
        '%': {intType: (b) => b.i64_rem_s()},
        '&': {intType: (b) => b.i64_and()},
        '|': {intType: (b) => b.i64_or()},
        '^': {intType: (b) => b.i64_xor()},
        '<<': {intType: (b) => b.i64_shl()},
        '>>': {intType: (b) => b.i64_shr_s()},
        '<': {intType: (b) => b.i64_lt_s()},
        '<=': {intType: (b) => b.i64_le_s()},
        '>': {intType: (b) => b.i64_gt_s()},
        '>=': {intType: (b) => b.i64_ge_s()},
      },
      doubleType: {
        '+': {doubleType: (b) => b.f64_add()},
        '-': {doubleType: (b) => b.f64_sub()},
        '*': {doubleType: (b) => b.f64_mul()},
        '/': {doubleType: (b) => b.f64_div()},
        '<': {doubleType: (b) => b.f64_lt()},
        '<=': {doubleType: (b) => b.f64_le()},
        '>': {doubleType: (b) => b.f64_gt()},
        '>=': {doubleType: (b) => b.f64_ge()},
      }
    };

    unaryOperatorMap = {
      intType: {
        'unary-': (b) {
          b.i64_const(-1);
          b.i64_mul();
        },
        '~': (b) {
          b.i64_const(-1);
          b.i64_xor();
        },
        'toDouble': (b) {
          b.f64_convert_i64_s();
        },
      },
      doubleType: {
        'unary-': (b) {
          b.f64_neg();
        },
        'toInt': (b) {
          b.i64_trunc_sat_f64_s();
        }
      },
    };

    unaryResultMap = {
      'toDouble': w.NumType.f64,
      'toInt': w.NumType.i64,
    };
  }

  w.ValueType? generateInstanceGetterIntrinsic(InstanceGet node) {
    DartType receiverType = dartTypeOf(node.receiver);
    String name = node.name.text;
    if (node.interfaceTarget.enclosingClass == translator.wasmArrayBaseClass) {
      assert(name == 'length');
      DartType elementType =
          (receiverType as InterfaceType).typeArguments.single;
      w.ArrayType arrayType = translator.arrayType(elementType);
      Expression array = node.receiver;
      codeGen.wrap(array, w.RefType.def(arrayType, nullable: true));
      b.array_len(arrayType);
      b.i64_extend_i32_u();
      return w.NumType.i64;
    }
    if (node.interfaceTarget.enclosingClass == translator.coreTypes.intClass &&
        name == 'bitLength') {
      w.Local temp = codeGen.function.addLocal(w.NumType.i64);
      b.i64_const(64);
      codeGen.wrap(node.receiver, w.NumType.i64);
      b.local_tee(temp);
      b.local_get(temp);
      b.i64_const(63);
      b.i64_shr_s();
      b.i64_xor();
      b.i64_clz();
      b.i64_sub();
      return w.NumType.i64;
    }
  }

  w.ValueType? generateInstanceIntrinsic(InstanceInvocation node) {
    DartType receiverType = dartTypeOf(node.receiver);
    String name = node.name.text;
    if (node.interfaceTarget.enclosingClass?.superclass ==
        translator.wasmArrayBaseClass) {
      DartType elementType =
          (receiverType as InterfaceType).typeArguments.single;
      w.ArrayType arrayType = translator.arrayType(elementType);
      w.StorageType wasmType = arrayType.elementType.type;
      bool innerExtend =
          wasmType == w.PackedType.i8 || wasmType == w.PackedType.i16;
      bool outerExtend =
          wasmType.unpacked == w.NumType.i32 || wasmType == w.NumType.f32;
      switch (name) {
        case 'read':
        case 'readSigned':
        case 'readUnsigned':
          bool unsigned = name == 'readUnsigned';
          Expression array = node.receiver;
          Expression index = node.arguments.positional.single;
          codeGen.wrap(array, w.RefType.def(arrayType, nullable: true));
          codeGen.wrap(index, w.NumType.i64);
          b.i32_wrap_i64();
          if (innerExtend) {
            if (unsigned) {
              b.array_get_u(arrayType);
            } else {
              b.array_get_s(arrayType);
            }
          } else {
            b.array_get(arrayType);
          }
          if (outerExtend) {
            if (wasmType == w.NumType.f32) {
              b.f64_promote_f32();
              return w.NumType.f64;
            } else {
              if (unsigned) {
                b.i64_extend_i32_u();
              } else {
                b.i64_extend_i32_s();
              }
              return w.NumType.i64;
            }
          }
          return wasmType.unpacked;
        case 'write':
          Expression array = node.receiver;
          Expression index = node.arguments.positional[0];
          Expression value = node.arguments.positional[1];
          codeGen.wrap(array, w.RefType.def(arrayType, nullable: true));
          codeGen.wrap(index, w.NumType.i64);
          b.i32_wrap_i64();
          codeGen.wrap(value, typeOfExp(value));
          if (outerExtend) {
            if (wasmType == w.NumType.f32) {
              b.f32_demote_f64();
            } else {
              b.i32_wrap_i64();
            }
          }
          b.array_set(arrayType);
          return codeGen.voidMarker;
        default:
          throw "Unsupported array method: $name";
      }
    }

    if (node.arguments.positional.length == 1) {
      // Binary operator
      Expression left = node.receiver;
      Expression right = node.arguments.positional.single;
      DartType argType = dartTypeOf(right);
      if (argType is VoidType) return null;
      w.ValueType leftType = translator.translateType(receiverType);
      w.ValueType rightType = translator.translateType(argType);
      var op = binaryOperatorMap[leftType]?[name]?[rightType];
      if (op != null) {
        // TODO: Support differing operand types
        w.ValueType outType = isComparison(name) ? w.NumType.i32 : leftType;
        codeGen.wrap(left, leftType);
        codeGen.wrap(right, rightType);
        op(b);
        return outType;
      }
    } else if (node.arguments.positional.length == 0) {
      // Unary operator
      Expression operand = node.receiver;
      w.ValueType opType = translator.translateType(receiverType);
      var op = unaryOperatorMap[opType]?[name];
      if (op != null) {
        codeGen.wrap(operand, opType);
        op(b);
        return unaryResultMap[name] ?? opType;
      }
    }
  }

  w.ValueType? generateEqualsIntrinsic(EqualsCall node) {
    w.ValueType leftType = translator.translateType(dartTypeOf(node.left));
    w.ValueType rightType = translator.translateType(dartTypeOf(node.right));

    if (leftType == boolType && rightType == boolType) {
      codeGen.wrap(node.left, w.NumType.i32);
      codeGen.wrap(node.right, w.NumType.i32);
      b.i32_eq();
      return w.NumType.i32;
    }

    if (leftType == intType && rightType == intType) {
      codeGen.wrap(node.left, w.NumType.i64);
      codeGen.wrap(node.right, w.NumType.i64);
      b.i64_eq();
      return w.NumType.i32;
    }

    if (leftType == doubleType && rightType == doubleType) {
      codeGen.wrap(node.left, w.NumType.f64);
      codeGen.wrap(node.right, w.NumType.f64);
      b.f64_eq();
      return w.NumType.i32;
    }
  }

  w.ValueType? generateStaticIntrinsic(StaticInvocation node) {
    if (node.target.enclosingLibrary == translator.coreTypes.coreLibrary &&
        node.name.text == "identical") {
      Expression first = node.arguments.positional[0];
      Expression second = node.arguments.positional[1];
      // TODO: Support non-reference types
      w.ValueType object = translator.nullableObjectType;
      codeGen.wrap(first, object);
      codeGen.wrap(second, object);
      b.ref_eq();
      return w.NumType.i32;
    }

    if (node.target.enclosingLibrary.name == "dart._internal" &&
        node.name.text == "unsafeCast") {
      w.ValueType targetType =
          translator.translateType(node.arguments.types.single);
      Expression operand = node.arguments.positional.single;
      return codeGen.wrap(operand, targetType);
    }

    if (node.target.enclosingClass?.superclass ==
        translator.wasmArrayBaseClass) {
      Expression length = node.arguments.positional[0];
      w.ArrayType arrayType = translator.arrayType(node.arguments.types.single);
      codeGen.wrap(length, w.NumType.i64);
      // TODO: Support filling with other than default value
      b.i32_wrap_i64();
      b.rtt_canon(arrayType);
      b.array_new_default_with_rtt(arrayType);
      return w.RefType.def(arrayType, nullable: false);
    }
  }

  bool generateMemberIntrinsic(Reference target, w.DefinedFunction function,
      List<w.Local> paramLocals, w.Label? returnLabel) {
    Member member = target.asMember;

    if (member == translator.coreTypes.objectEquals) {
      b.local_get(paramLocals[0]);
      b.local_get(paramLocals[1]);
      b.ref_eq();
      return true;
    }

    return false;
  }
}
