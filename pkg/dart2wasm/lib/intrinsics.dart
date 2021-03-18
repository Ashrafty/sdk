// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';

import 'package:dart2wasm/body_analyzer.dart';
import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/translator.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class Intrinsifier {
  final BodyAnalyzer bodyAnalyzer;
  final w.ValueType intType;
  final w.ValueType doubleType;

  late final Map<w.ValueType, Map<String, Map<w.ValueType, CodeGenCallback>>>
      binaryOperatorMap;
  late final Map<w.ValueType, Map<String, CodeGenCallback>> unaryOperatorMap;
  late final Map<String, w.ValueType> unaryResultMap;
  late final Map<w.ValueType, Map<w.ValueType, Map<bool, CodeGenCallback>>>
      equalsMap;

  // Meaning of the `isNot` field of `EqualsCall`
  static const bool isEquals = false;
  static const bool isNotEquals = true;

  Translator get translator => bodyAnalyzer.translator;

  DartType dartTypeOf(Expression exp) {
    return exp.getStaticType(bodyAnalyzer.codeGen.typeContext);
  }

  static bool isComparison(String op) =>
      op == '<' || op == '<=' || op == '>' || op == '>=';

  Intrinsifier(this.bodyAnalyzer)
      : intType = w.NumType.i64,
        doubleType = w.NumType.f64 {
    binaryOperatorMap = {
      intType: {
        '+': {intType: (c) => c.b.i64_add()},
        '-': {intType: (c) => c.b.i64_sub()},
        '*': {intType: (c) => c.b.i64_mul()},
        '~/': {intType: (c) => c.b.i64_div_s()},
        '%': {intType: (c) => c.b.i64_rem_s()},
        '&': {intType: (c) => c.b.i64_and()},
        '|': {intType: (c) => c.b.i64_or()},
        '^': {intType: (c) => c.b.i64_xor()},
        '<<': {intType: (c) => c.b.i64_shl()},
        '>>': {intType: (c) => c.b.i64_shr_s()},
        '<': {intType: (c) => c.b.i64_lt_s()},
        '<=': {intType: (c) => c.b.i64_le_s()},
        '>': {intType: (c) => c.b.i64_gt_s()},
        '>=': {intType: (c) => c.b.i64_ge_s()},
      },
      doubleType: {
        '+': {doubleType: (c) => c.b.f64_add()},
        '-': {doubleType: (c) => c.b.f64_sub()},
        '*': {doubleType: (c) => c.b.f64_mul()},
        '/': {doubleType: (c) => c.b.f64_div()},
        '<': {doubleType: (c) => c.b.f64_lt()},
        '<=': {doubleType: (c) => c.b.f64_le()},
        '>': {doubleType: (c) => c.b.f64_gt()},
        '>=': {doubleType: (c) => c.b.f64_ge()},
      }
    };

    unaryOperatorMap = {
      intType: {
        'unary-': (c) {
          c.b.i64_const(-1);
          c.b.i64_mul();
        },
        '~': (c) {
          c.b.i64_const(-1);
          c.b.i64_xor();
        },
        'toDouble': (c) {
          c.b.f64_convert_i64_s();
        },
      },
      doubleType: {
        'unary-': (c) {
          c.b.f64_neg();
        },
        'toInt': (c) {
          c.b.i64_trunc_sat_f64_s();
        }
      },
    };

    unaryResultMap = {
      'toDouble': w.NumType.f64,
      'toInt': w.NumType.i64,
    };

    equalsMap = {
      intType: {
        intType: {
          isEquals: (c) => c.b.i64_eq(),
          isNotEquals: (c) => c.b.i64_ne(),
        }
      },
      doubleType: {
        doubleType: {
          isEquals: (c) => c.b.f64_eq(),
          isNotEquals: (c) => c.b.f64_ne(),
        }
      },
    };
  }

  w.ValueType? getInstanceGetterIntrinsic(InstanceGet node) {
    DartType receiverType = dartTypeOf(node.receiver);
    String name = node.name.text;
    if (node.interfaceTarget.enclosingClass == translator.wasmArrayBaseClass) {
      assert(name == 'length');
      DartType elementType =
          (receiverType as InterfaceType).typeArguments.single;
      w.ArrayType arrayType = translator.arrayType(elementType);
      Expression array = node.receiver;
      bodyAnalyzer.wrapExpression(array, bodyAnalyzer.typeOfExp(array));
      bodyAnalyzer.inject[node] = (c) {
        c.wrap(array);
        c.b.array_len(arrayType);
        c.b.i64_extend_i32_u();
      };
      return w.NumType.i64;
    }
  }

  w.ValueType? getInstanceIntrinsic(InstanceInvocation node) {
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
          bodyAnalyzer.wrapExpression(
              array, w.RefType.def(arrayType, nullable: true));
          bodyAnalyzer.wrapExpression(index, w.NumType.i64);
          bodyAnalyzer.inject[node] = (c) {
            c.wrap(array);
            c.wrap(index);
            c.b.i32_wrap_i64();
            if (innerExtend) {
              if (unsigned) {
                c.b.array_get_u(arrayType);
              } else {
                c.b.array_get_s(arrayType);
              }
            } else {
              c.b.array_get(arrayType);
            }
            if (outerExtend) {
              if (wasmType == w.NumType.f32) {
                c.b.f64_promote_f32();
              } else {
                if (unsigned) {
                  c.b.i64_extend_i32_u();
                } else {
                  c.b.i64_extend_i32_s();
                }
              }
            }
          };
          return bodyAnalyzer.translateType(elementType);
        case 'write':
          Expression array = node.receiver;
          Expression index = node.arguments.positional[0];
          Expression value = node.arguments.positional[1];
          bodyAnalyzer.wrapExpression(
              array, w.RefType.def(arrayType, nullable: true));
          bodyAnalyzer.wrapExpression(index, w.NumType.i64);
          bodyAnalyzer.wrapExpression(
              value, bodyAnalyzer.translateType(elementType));
          bodyAnalyzer.inject[node] = (c) {
            c.wrap(array);
            c.wrap(index);
            c.b.i32_wrap_i64();
            c.wrap(value);
            if (outerExtend) {
              if (wasmType == w.NumType.f32) {
                c.b.f32_demote_f64();
              } else {
                c.b.i32_wrap_i64();
              }
            }
            c.b.array_set(arrayType);
          };
          return bodyAnalyzer.voidMarker;
        default:
          throw "Unsupported array method: $name";
      }
    }

    if (node.arguments.positional.length == 1) {
      // Binary operator
      Expression left = node.receiver;
      Expression right = node.arguments.positional.single;
      DartType argType = dartTypeOf(right);
      w.ValueType leftType = translator.translateType(receiverType);
      w.ValueType rightType = translator.translateType(argType);
      var op = binaryOperatorMap[leftType]?[name]?[rightType];
      if (op != null) {
        // TODO: Support differing operand types
        w.ValueType outType = isComparison(name) ? w.NumType.i32 : leftType;
        bodyAnalyzer.wrapExpression(left, leftType);
        bodyAnalyzer.wrapExpression(right, rightType);
        bodyAnalyzer.inject[node] = (c) {
          c.wrap(left);
          c.wrap(right);
          op(c);
        };
        return outType;
      }
    } else if (node.arguments.positional.length == 0) {
      // Unary operator
      Expression operand = node.receiver;
      w.ValueType opType = translator.translateType(receiverType);
      var op = unaryOperatorMap[opType]?[name];
      if (op != null) {
        bodyAnalyzer.wrapExpression(operand, opType);
        bodyAnalyzer.inject[node] = (c) {
          c.wrap(node.receiver);
          op(c);
        };
        return unaryResultMap[name] ?? opType;
      }
    }
  }

  w.ValueType? getEqualsIntrinsic(EqualsCall node) {
    w.ValueType leftType = translator.translateType(dartTypeOf(node.left));
    w.ValueType rightType = translator.translateType(dartTypeOf(node.right));
    if (leftType == intType && rightType == intType) {
      bodyAnalyzer.wrapExpression(node.left, w.NumType.i64);
      bodyAnalyzer.wrapExpression(node.right, w.NumType.i64);
      bodyAnalyzer.inject[node] = (c) {
        c.wrap(node.left);
        c.wrap(node.right);
        c.b.i64_eq();
      };
      return w.NumType.i32;
    }

    if (leftType == doubleType && rightType == doubleType) {
      bodyAnalyzer.wrapExpression(node.left, w.NumType.f64);
      bodyAnalyzer.wrapExpression(node.right, w.NumType.f64);
      bodyAnalyzer.inject[node] = (c) {
        c.wrap(node.left);
        c.wrap(node.right);
        c.b.f64_eq();
      };
      return w.NumType.i32;
    }
  }

  w.ValueType? getStaticIntrinsic(StaticInvocation node) {
    if (node.target.enclosingLibrary == translator.coreTypes.coreLibrary &&
        node.name.text == "identical") {
      Expression first = node.arguments.positional[0];
      Expression second = node.arguments.positional[1];
      // TODO: Support non-reference types
      w.ValueType object = w.RefType.def(
          bodyAnalyzer.codeGen.object.repr.struct,
          nullable: true);
      bodyAnalyzer.wrapExpression(first, object);
      bodyAnalyzer.wrapExpression(second, object);
      bodyAnalyzer.inject[node] = (c) {
        c.wrap(first);
        c.wrap(second);
        c.b.ref_eq();
      };
      return w.NumType.i32;
    }

    if (node.target.enclosingLibrary.name == "dart._internal" &&
        node.name.text == "unsafeCast") {
      Expression operand = node.arguments.positional.single;
      w.ValueType object = w.RefType.def(
          bodyAnalyzer.codeGen.object.repr.struct,
          nullable: true);
      DartType targetType = node.arguments.types.single;
      InterfaceType interfaceType = targetType is InterfaceType
          ? targetType
          : translator.coreTypes.objectNullableRawType;
      ClassInfo info = translator.classInfo[interfaceType.classNode]!;
      bodyAnalyzer.wrapExpression(operand, object);
      bodyAnalyzer.inject[node] = (c) {
        c.wrap(operand);
        c.b.global_get(info.repr.rtt);
        c.b.ref_cast();
      };
      return w.RefType.def(info.repr.struct,
          nullable: targetType.isPotentiallyNullable);
    }

    if (node.target.enclosingClass?.superclass ==
        translator.wasmArrayBaseClass) {
      Expression length = node.arguments.positional[0];
      w.ArrayType arrayType = translator.arrayType(node.arguments.types.single);
      bodyAnalyzer.wrapExpression(length, w.NumType.i64);
      bodyAnalyzer.inject[node] = (c) {
        // TODO: Support filling with other than default value
        c.wrap(node.arguments.positional.first);
        c.b.i32_wrap_i64();
        c.b.rtt_canon(arrayType);
        c.b.array_new_default_with_rtt(arrayType);
      };
      return w.RefType.def(arrayType, nullable: false);
    }
  }
}
