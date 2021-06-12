// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/visitor.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class ConstantInfo {
  Constant constant;
  w.Global global;
  w.DefinedFunction function;

  ConstantInfo(this.constant, this.global, this.function);
}

typedef ConstantCodeGenerator = void Function(w.DefinedFunction);

class Constants {
  final Translator translator;
  final Map<Constant, ConstantInfo> constantInfo = {};
  final StringBuffer oneByteStrings = StringBuffer();
  final StringBuffer twoByteStrings = StringBuffer();
  late final w.DefinedFunction oneByteStringFunction;
  late final w.DefinedFunction twoByteStringFunction;
  late final w.DefinedGlobal emptyString;

  Constants(this.translator) {
    oneByteStringFunction = makeStringFunction(translator.oneByteStringClass);
    twoByteStringFunction = makeStringFunction(translator.twoByteStringClass);
    initEmptyString();
  }

  w.Module get m => translator.m;

  void initEmptyString() {
    ClassInfo info = translator.classInfo[translator.oneByteStringClass]!;
    w.ArrayType arrayType =
        ((info.struct.fields.last.type as w.RefType).heapType as w.DefHeapType)
            .def as w.ArrayType;

    w.RefType emptyStringType = info.nullableType;
    emptyString = m.addGlobal(w.GlobalType(emptyStringType));
    emptyString.initializer.ref_null(emptyStringType.heapType);
    emptyString.initializer.end();

    w.Instructions b = translator.initFunction.body;
    b.i32_const(info.classId);
    b.i32_const(initialIdentityHash);
    b.i32_const(0);
    b.rtt_canon(arrayType);
    b.array_new_default_with_rtt(arrayType);
    b.global_get(info.rtt);
    b.struct_new_with_rtt(info.struct);
    b.global_set(emptyString);
  }

  void finalize() {
    Uint8List oneByteStringsAsBytes =
        Uint8List.fromList(oneByteStrings.toString().codeUnits);
    assert(Endian.host == Endian.little);
    Uint8List twoByteStringsAsBytes =
        Uint16List.fromList(twoByteStrings.toString().codeUnits)
            .buffer
            .asUint8List();
    Uint8List stringsAsBytes = (BytesBuilder()
          ..add(twoByteStringsAsBytes)
          ..add(oneByteStringsAsBytes))
        .toBytes();

    w.Memory stringMemory = m.addMemory(
        stringsAsBytes.length, stringsAsBytes.length)
      ..addData(0, stringsAsBytes);
    makeStringFunctionBody(translator.oneByteStringClass, oneByteStringFunction,
        (b) {
      b.i32_load8_u(stringMemory, twoByteStringsAsBytes.length);
    });
    makeStringFunctionBody(translator.twoByteStringClass, twoByteStringFunction,
        (b) {
      b.i32_const(1);
      b.i32_shl();
      b.i32_load16_u(stringMemory, 0);
    });
  }

  w.DefinedFunction makeStringFunction(Class cls) {
    ClassInfo info = translator.classInfo[cls]!;
    w.FunctionType ftype = m.addFunctionType(
        const [w.NumType.i32, w.NumType.i32], [info.nonNullableType]);
    return m.addFunction(ftype);
  }

  void makeStringFunctionBody(Class cls, w.DefinedFunction function,
      void Function(w.Instructions) emitLoad) {
    ClassInfo info = translator.classInfo[cls]!;
    w.ArrayType arrayType =
        ((info.struct.fields.last.type as w.RefType).heapType as w.DefHeapType)
            .def as w.ArrayType;

    w.Local offset = function.locals[0];
    w.Local length = function.locals[1];
    w.Local array = function.addLocal(
        translator.typeForLocal(w.RefType.def(arrayType, nullable: false)));
    w.Local index = function.addLocal(w.NumType.i32);

    w.Instructions b = function.body;
    b.local_get(length);
    b.rtt_canon(arrayType);
    b.array_new_default_with_rtt(arrayType);
    b.local_set(array);

    b.i32_const(0);
    b.local_set(index);
    w.Label loop = b.loop();
    b.local_get(array);
    b.local_get(index);
    b.local_get(offset);
    b.local_get(index);
    b.i32_add();
    emitLoad(b);
    b.array_set(arrayType);
    b.local_get(index);
    b.i32_const(1);
    b.i32_add();
    b.local_tee(index);
    b.local_get(length);
    b.i32_lt_u();
    b.br_if(loop);
    b.end();

    b.i32_const(info.classId);
    b.i32_const(initialIdentityHash);
    b.local_get(array);
    b.global_get(info.rtt);
    b.struct_new_with_rtt(info.struct);
    b.end();
  }

  void instantiateConstant(
      w.DefinedFunction function, Constant constant, w.ValueType expectedType) {
    ConstantInstantiator(this, function, expectedType).instantiate(constant);
  }
}

class ConstantInstantiator extends ConstantVisitor<w.ValueType> {
  final Constants constants;
  final w.DefinedFunction function;
  final w.ValueType expectedType;

  ConstantInstantiator(this.constants, this.function, this.expectedType);

  Translator get translator => constants.translator;
  w.Module get m => translator.m;
  w.Instructions get b => function.body;

  void instantiate(Constant constant) {
    w.ValueType resultType = constant.accept(this);
    translator.convertType(function, resultType, expectedType);
  }

  void instantiateLazyConstant(
      Constant constant, w.RefType type, ConstantCodeGenerator generator) {
    assert(!type.nullable);
    ConstantInfo? info = constants.constantInfo[constant];
    if (info == null) {
      w.DefinedGlobal global =
          m.addGlobal(w.GlobalType(type.withNullability(true)));
      global.initializer.ref_null(type.heapType);
      global.initializer.end();
      w.FunctionType ftype = m.addFunctionType([], [type]);
      w.DefinedFunction function = m.addFunction(ftype);
      generator(function);
      w.Instructions b2 = function.body;
      b2.global_set(global);
      b2.global_get(global);
      b2.ref_as_non_null();
      b2.end();
      info = ConstantInfo(constant, global, function);
      constants.constantInfo[constant] = info;
    }
    w.Label b1 = b.block([], [type]);
    w.Label b2 = b.block([], []);
    b.global_get(info.global);
    b.br_on_null(b2);
    b.br(b1);
    b.end();
    b.call(info.function);
    b.end();
  }

  w.ValueType defaultConstant(Constant node) {
    final text = "Not implemented: $node";
    print(text);
    b.comment(text);
    b.block([], [expectedType]);
    b.unreachable();
    b.end();
    return expectedType;
  }

  @override
  w.ValueType visitNullConstant(NullConstant node) {
    w.ValueType? expectedType = this.expectedType;
    if (expectedType != constants.translator.voidMarker) {
      if (expectedType.nullable) {
        w.HeapType heapType =
            expectedType is w.RefType ? expectedType.heapType : w.HeapType.data;
        b.ref_null(heapType);
      } else {
        // This only happens in invalid but unreachable code produced by the
        // TFA dead-code elimination.
        b.comment("Non-nullable null constant");
        b.block([], [expectedType]);
        b.unreachable();
        b.end();
      }
    }
    return expectedType;
  }

  @override
  w.ValueType visitBoolConstant(BoolConstant constant) {
    b.i32_const(constant.value ? 1 : 0);
    return w.NumType.i32;
  }

  @override
  w.ValueType visitIntConstant(IntConstant constant) {
    b.i64_const(constant.value);
    return w.NumType.i64;
  }

  @override
  w.ValueType visitDoubleConstant(DoubleConstant constant) {
    b.f64_const(constant.value);
    return w.NumType.f64;
  }

  @override
  w.ValueType visitStringConstant(StringConstant constant) {
    w.Instructions b = function.body;
    if (constant.value.isEmpty) {
      b.global_get(constants.emptyString);
      return constants.emptyString.type.type;
    }
    bool isOneByte = constant.value.codeUnits.every((c) => c <= 255);
    ClassInfo info = translator.classInfo[isOneByte
        ? translator.oneByteStringClass
        : translator.twoByteStringClass]!;
    w.RefType type = info.nonNullableType;
    instantiateLazyConstant(constant, type, (function) {
      StringBuffer buffer =
          isOneByte ? constants.oneByteStrings : constants.twoByteStrings;
      int offset = buffer.length;
      int length = constant.value.length;
      buffer.write(constant.value);

      w.Instructions b = function.body;
      b.i32_const(offset);
      b.i32_const(length);
      b.call(isOneByte
          ? constants.oneByteStringFunction
          : constants.twoByteStringFunction);
    });
    return type;
  }

  @override
  w.ValueType visitInstanceConstant(InstanceConstant constant) {
    ClassInfo info = translator.classInfo[constant.classNode]!;
    w.RefType type = info.nonNullableType;
    instantiateLazyConstant(constant, type, (function) {
      const int baseFieldCount = 2;
      int fieldCount = constant.fieldValues.length;
      assert(info.struct.fields.length == baseFieldCount + fieldCount);
      List<Constant?> subConstants = List.filled(fieldCount, null);
      constant.fieldValues.forEach((reference, subConstant) {
        int index = translator.fieldIndex[reference.asField]! - baseFieldCount;
        assert(subConstants[index] == null);
        subConstants[index] = subConstant;
      });

      w.Instructions b = function.body;
      b.i32_const(info.classId);
      b.i32_const(initialIdentityHash);
      for (int i = 0; i < fieldCount; i++) {
        constants.instantiateConstant(function, subConstants[i]!,
            info.struct.fields[baseFieldCount + i].type.unpacked);
      }
      b.global_get(info.rtt);
      b.struct_new_with_rtt(info.struct);
    });
    return type;
  }

  @override
  w.ValueType visitListConstant(ListConstant constant) {
    // TODO: Use unmodifiable list
    ClassInfo info = translator.classInfo[translator.fixedLengthListClass]!;
    w.RefType type = info.nonNullableType;
    instantiateLazyConstant(constant, type, (function) {
      w.RefType refType = info.struct.fields.last.type.unpacked as w.RefType;
      w.ArrayType arrayType =
          (refType.heapType as w.DefHeapType).def as w.ArrayType;
      w.ValueType elementType = arrayType.elementType.type.unpacked;
      int length = constant.entries.length;
      w.Local arrayLocal = function.addLocal(
          refType.withNullability(!translator.options.localNullability));
      w.Instructions b = function.body;
      b.i32_const(info.classId);
      b.i32_const(initialIdentityHash);
      b.i64_const(length);
      b.i32_const(length);
      b.rtt_canon(arrayType);
      b.array_new_default_with_rtt(arrayType);
      b.local_set(arrayLocal);
      for (int i = 0; i < length; i++) {
        b.local_get(arrayLocal);
        b.i32_const(i);
        constants.instantiateConstant(
            function, constant.entries[i], elementType);
        b.array_set(arrayType);
      }
      b.local_get(arrayLocal);
      if (arrayLocal.type.nullable) {
        b.ref_as_non_null();
      }
      b.global_get(info.rtt);
      b.struct_new_with_rtt(info.struct);
    });
    return type;
  }

  @override
  w.ValueType visitTearOffConstant(TearOffConstant constant) {
    w.DefinedFunction closureFunction =
        translator.getTearOffFunction(constant.procedureReference.asProcedure);
    int parameterCount = closureFunction.type.inputs.length - 1;
    w.StructType struct = translator.functionStructType(parameterCount);
    w.RefType type = w.RefType.def(struct, nullable: false);
    instantiateLazyConstant(constant, type, (function) {
      w.DefinedGlobal global = translator.makeFunctionRef(closureFunction);
      ClassInfo info = translator.classInfo[translator.functionClass]!;
      w.DefinedGlobal rtt = translator.functionTypeRtt[parameterCount]!;

      w.Instructions b = function.body;
      b.i32_const(info.classId);
      b.i32_const(initialIdentityHash);
      // TODO: Put dummy context in global variable
      b.rtt_canon(translator.dummyContext);
      b.struct_new_with_rtt(translator.dummyContext);
      b.global_get(global);
      b.global_get(rtt);
      b.struct_new_with_rtt(struct);
    });
    return type;
  }

  @override
  w.ValueType visitTypeLiteralConstant(TypeLiteralConstant constant) {
    DartType type = constant.type;
    if (type is! InterfaceType) return defaultConstant(constant);
    ClassInfo info = translator.classInfo[translator.typeClass]!;
    instantiateLazyConstant(constant, info.nonNullableType, (function) {
      ClassInfo typeInfo = translator.classInfo[type.classNode]!;
      ListConstant typeArgs = ListConstant(
          InterfaceType(translator.typeClass, Nullability.nonNullable),
          type.typeArguments.map((t) => TypeLiteralConstant(t)).toList());

      w.Instructions b = function.body;
      b.i32_const(info.classId);
      b.i32_const(initialIdentityHash);
      b.i64_const(typeInfo.classId);
      constants.instantiateConstant(
          function, typeArgs, info.struct.fields[3].type.unpacked);
      b.global_get(info.rtt);
      b.struct_new_with_rtt(info.struct);
    });
    return info.nonNullableType;
  }
}
