// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

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

typedef ConstantCodeGenerator = void Function(w.Instructions);

class Constants {
  final Translator translator;
  final Map<Constant, ConstantInfo> constantInfo = {};

  Constants(this.translator);

  void instantiateConstant(
      w.Instructions b, Constant constant, w.ValueType? expectedType) {
    constant.accept(ConstantInstantiator(this, b, expectedType));
  }
}

class ConstantInstantiator extends ConstantVisitor<void> {
  final Constants constants;
  final w.Instructions b;
  final w.ValueType? expectedType;

  ConstantInstantiator(this.constants, this.b, this.expectedType);

  Translator get translator => constants.translator;
  w.Module get m => translator.m;

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
      generator(function.body);
      function.body.global_set(global);
      function.body.global_get(global);
      function.body.ref_as_non_null();
      function.body.end();
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

  void defaultConstant(Constant node) {
    throw "Unsupported constant: $node";
  }

  @override
  void visitNullConstant(NullConstant node) {
    w.ValueType? expectedType = this.expectedType;
    if (expectedType != constants.translator.voidMarker) {
      w.HeapType heapType =
          expectedType is w.RefType ? expectedType.heapType : w.HeapType.data;
      b.ref_null(heapType);
    }
  }

  @override
  void visitBoolConstant(BoolConstant constant) {
    // TODO: box
    b.i32_const(constant.value ? 1 : 0);
  }

  @override
  void visitIntConstant(IntConstant constant) {
    // TODO: box
    b.i64_const(constant.value);
  }

  @override
  void visitDoubleConstant(DoubleConstant constant) {
    // TODO: box
    b.f64_const(constant.value);
  }

  @override
  void visitStringConstant(StringConstant constant) {
    // TODO: String contents
    ClassInfo info = translator.classInfo[translator.coreTypes.stringClass]!;
    b.i32_const(info.classId);
    b.global_get(info.rtt);
    b.struct_new_with_rtt(info.struct);
  }

  void visitInstanceConstant(InstanceConstant constant) {
    ClassInfo info = translator.classInfo[constant.classNode]!;
    w.RefType type = w.RefType.def(info.struct, nullable: false);
    instantiateLazyConstant(constant, type, (b) {
      int fieldCount = constant.fieldValues.length;
      assert(info.struct.fields.length == 1 + fieldCount);
      List<Constant?> subConstants = List.filled(1 + fieldCount, null);
      constant.fieldValues.forEach((reference, subConstant) {
        int fieldIndex = translator.fieldIndex[reference.asField]!;
        assert(subConstants[fieldIndex] == null);
        subConstants[fieldIndex] = subConstant;
      });

      b.i32_const(info.classId);
      for (int i = 1; i <= fieldCount; i++) {
        constants.instantiateConstant(
            b, subConstants[i]!, info.struct.fields[i].type.unpacked);
      }
      b.global_get(info.rtt);
      b.struct_new_with_rtt(info.struct);
    });
  }
}
