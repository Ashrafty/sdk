// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'module.dart';
import 'serialize.dart';
import 'types.dart';

abstract class Function {
  int index;
  final FunctionType type;

  Function(this.index, this.type);
}

class DefinedFunction extends Function
    with SerializerMixin
    implements Serializable {
  final List<Local> locals = [];
  late final Instructions body;

  DefinedFunction(Module module, int index, FunctionType type)
      : super(index, type) {
    for (ValueType paramType in type.inputs) {
      addLocal(paramType);
    }
    body = Instructions(module, type.outputs, locals);
  }

  Local addLocal(ValueType type) {
    Local local = Local(locals.length, type);
    locals.add(local);
    return local;
  }

  @override
  void serialize(Serializer s) {
    // Serialize locals internally
    int paramCount = type.inputs.length;
    int entries = 0;
    for (int i = paramCount + 1; i <= locals.length; i++) {
      if (i == locals.length || locals[i - 1].type != locals[i].type) entries++;
    }
    writeUnsigned(entries);
    int start = 0;
    for (int i = paramCount + 1; i <= locals.length; i++) {
      if (i == locals.length || locals[i - 1].type != locals[i].type) {
        writeUnsigned(i - start);
        write(locals[i - 1].type);
        start = i;
      }
    }

    // Bundle locals and body
    assert(body.isComplete);
    s.writeUnsigned(data.length + body.data.length);
    s.writeBytes(data);
    s.writeBytes(body.data);
  }
}

class Local {
  final int index;
  final ValueType type;

  Local(this.index, this.type);
}

abstract class Global {
  final int index;
  final FieldType type;

  Global(this.index, this.type);
}

class DefinedGlobal extends Global implements Serializable {
  final Instructions initializer;

  DefinedGlobal(Module module, int index, FieldType type)
      : initializer = Instructions(module, [type.type as ValueType]),
        super(index, type);

  @override
  void serialize(Serializer s) {
    assert(initializer.isComplete);
    s.write(type);
    s.writeBytes(initializer.data);
  }
}

abstract class Label {
  late final int depth;
  final List<ValueType> inputs;
  final List<ValueType> outputs;

  Label._(this.inputs, this.outputs);

  List<ValueType> get targetTypes;
}

class Expression extends Label {
  Expression(List<ValueType> inputs, List<ValueType> outputs)
      : super._(inputs, outputs) {
    depth = 0;
  }

  List<ValueType> get targetTypes => outputs;
}

class Block extends Label {
  Block(List<ValueType> inputs, List<ValueType> outputs)
      : super._(inputs, outputs);

  List<ValueType> get targetTypes => outputs;
}

class Loop extends Label {
  Loop(List<ValueType> inputs, List<ValueType> outputs)
      : super._(inputs, outputs);

  List<ValueType> get targetTypes => inputs;
}

class If extends Label {
  If(List<ValueType> inputs, List<ValueType> outputs)
      : super._(inputs, outputs);

  List<ValueType> get targetTypes => outputs;
}

class Instructions with SerializerMixin {
  final Module module;
  final List<Local> locals;
  final List<Label> labelStack = [];

  Instructions(this.module, List<ValueType> outputs, [this.locals = const []]) {
    labelStack.add(Expression(const [], outputs));
  }

  bool get isComplete => labelStack.isEmpty;

  // Control instructions

  void unreachable() {
    writeByte(0x00);
  }

  void nop() {
    writeByte(0x01);
  }

  Label _beginBlock(int encoding, Label label) {
    label.depth = labelStack.length;
    labelStack.add(label);
    writeByte(encoding);
    if (label.inputs.isEmpty && label.outputs.isEmpty) {
      writeByte(0x40);
    } else if (label.inputs.isEmpty && label.outputs.length == 1) {
      write(label.outputs.single);
    } else {
      FunctionType type = module.addFunctionType(label.inputs, label.outputs);
      writeSigned(type.index);
    }
    return label;
  }

  Label block(
          [List<ValueType> inputs = const [],
          List<ValueType> outputs = const []]) =>
      _beginBlock(0x02, Block(inputs, outputs));
  Label loop(
          [List<ValueType> inputs = const [],
          List<ValueType> outputs = const []]) =>
      _beginBlock(0x03, Loop(inputs, outputs));
  Label if_(
          [List<ValueType> inputs = const [],
          List<ValueType> outputs = const []]) =>
      _beginBlock(0x04, If(inputs, outputs));

  void else_(Label label) {
    assert(label == labelStack.last);
    writeByte(0x05);
  }

  void end() {
    labelStack.removeLast();
    writeByte(0x0B);
  }

  int _labelIndex(Label label) {
    int index = labelStack.length - label.depth - 1;
    assert(labelStack[label.depth] == label);
    return index;
  }

  void _writeLabel(Label label) {
    writeUnsigned(_labelIndex(label));
  }

  void br(Label label) {
    writeByte(0x0C);
    _writeLabel(label);
  }

  void br_if(Label label) {
    writeByte(0x0D);
    _writeLabel(label);
  }

  void br_table(List<Label> labels, Label defaultLabel) {
    writeByte(0x0E);
    writeUnsigned(labels.length);
    for (Label label in labels) {
      _writeLabel(label);
    }
    _writeLabel(defaultLabel);
  }

  void return_() {
    writeByte(0x0F);
  }

  void call(Function function) {
    writeByte(0x10);
    writeUnsigned(function.index);
  }

  void call_indirect(FunctionType type) {
    writeByte(0x11);
    writeUnsigned(type.index);
    writeByte(0x00);
  }

  // Parametric instructions

  void drop() {
    writeByte(0x1A);
  }

  void select() {
    writeByte(0x1B);
  }

  // Variable instructions

  void local_get(Local local) {
    assert(locals[local.index] == local);
    writeByte(0x20);
    writeUnsigned(local.index);
  }

  void local_set(Local local) {
    assert(locals[local.index] == local);
    writeByte(0x21);
    writeUnsigned(local.index);
  }

  void local_tee(Local local) {
    assert(locals[local.index] == local);
    writeByte(0x22);
    writeUnsigned(local.index);
  }

  void global_get(Global global) {
    writeByte(0x23);
    writeUnsigned(global.index);
  }

  void global_set(Global global) {
    assert(global.type.mutable);
    writeByte(0x24);
    writeUnsigned(global.index);
  }

  // TODO: memory instructions

  // Reference instructions

  void ref_null(HeapType type) {
    writeByte(0xD0);
    write(type);
  }

  void ref_is_null() {
    writeByte(0xD1);
  }

  void ref_func(Function function) {
    writeByte(0xD2);
    writeUnsigned(function.index);
  }

  void ref_as_non_null() {
    writeByte(0xD3);
  }

  void br_on_null(Label label) {
    writeByte(0xD4);
    _writeLabel(label);
  }

  void ref_eq() {
    writeByte(0xD5);
  }

  void struct_new_with_rtt(ValueType structType) {
    writeBytes(const [0xFB, 0x01]);
    write(structType);
  }

  void struct_new_default_with_rtt(ValueType structType) {
    writeBytes(const [0xFB, 0x02]);
    write(structType);
  }

  void struct_get(ValueType structType, int fieldIndex) {
    writeBytes(const [0xFB, 0x03]);
    write(structType);
    writeUnsigned(fieldIndex);
  }

  void struct_get_s(ValueType structType, int fieldIndex) {
    writeBytes(const [0xFB, 0x04]);
    write(structType);
    writeUnsigned(fieldIndex);
  }

  void struct_get_u(ValueType structType, int fieldIndex) {
    writeBytes(const [0xFB, 0x05]);
    write(structType);
    writeUnsigned(fieldIndex);
  }

  void struct_set(ValueType structType, int fieldIndex) {
    writeBytes(const [0xFB, 0x06]);
    write(structType);
    writeUnsigned(fieldIndex);
  }

  void array_new_with_rtt(ValueType arrayType) {
    writeBytes(const [0xFB, 0x11]);
    write(arrayType);
  }

  void array_new_default_with_rtt(ValueType arrayType) {
    writeBytes(const [0xFB, 0x12]);
    write(arrayType);
  }

  void array_get(ValueType arrayType) {
    writeBytes(const [0xFB, 0x13]);
    write(arrayType);
  }

  void array_get_s(ValueType arrayType) {
    writeBytes(const [0xFB, 0x14]);
    write(arrayType);
  }

  void array_get_u(ValueType arrayType) {
    writeBytes(const [0xFB, 0x15]);
    write(arrayType);
  }

  void array_set(ValueType arrayType) {
    writeBytes(const [0xFB, 0x16]);
    write(arrayType);
  }

  void array_len(ValueType arrayType) {
    writeBytes(const [0xFB, 0x17]);
    write(arrayType);
  }

  void i31_new() {
    writeBytes(const [0xFB, 0x20]);
  }

  void i31_get_s() {
    writeBytes(const [0xFB, 0x21]);
  }

  void i31_get_u() {
    writeBytes(const [0xFB, 0x22]);
  }

  void rtt_canon(HeapType type) {
    writeBytes(const [0xFB, 0x30]);
    write(type);
  }

  void rtt_sub(int depth, HeapType superType, HeapType subType) {
    writeBytes(const [0xFB, 0x31]);
    writeUnsigned(depth);
    write(superType);
    write(subType);
  }

  void ref_test(HeapType inputType, HeapType targetType) {
    writeBytes(const [0xFB, 0x40]);
    write(inputType);
    write(targetType);
  }

  void ref_cast(HeapType inputType, HeapType targetType) {
    writeBytes(const [0xFB, 0x41]);
    write(inputType);
    write(targetType);
  }

  void br_on_cast(Label label, HeapType inputType, HeapType targetType) {
    writeBytes(const [0xFB, 0x42]);
    _writeLabel(label);
    write(inputType);
    write(targetType);
  }

  // Numeric instructions

  void i32_const(int value) {
    assert(-1 << 31 <= value && value < 1 << 31);
    writeByte(0x41);
    writeSigned(value);
  }

  void i64_const(int value) {
    writeByte(0x42);
    writeSigned(value);
  }

  void f32_const(double value) {
    writeByte(0x43);
    writeF32(value);
  }

  void f64_const(double value) {
    writeByte(0x44);
    writeF64(value);
  }

  void i32_eqz() {
    writeByte(0x45);
  }

  void i32_eq() {
    writeByte(0x46);
  }

  void i32_ne() {
    writeByte(0x47);
  }

  void i32_lt_s() {
    writeByte(0x48);
  }

  void i32_lt_u() {
    writeByte(0x49);
  }

  void i32_gt_s() {
    writeByte(0x4A);
  }

  void i32_gt_u() {
    writeByte(0x4B);
  }

  void i32_le_s() {
    writeByte(0x4C);
  }

  void i32_le_u() {
    writeByte(0x4D);
  }

  void i32_ge_s() {
    writeByte(0x4E);
  }

  void i32_ge_u() {
    writeByte(0x4F);
  }

  void i64_eqz() {
    writeByte(0x50);
  }

  void i64_eq() {
    writeByte(0x51);
  }

  void i64_ne() {
    writeByte(0x52);
  }

  void i64_lt_s() {
    writeByte(0x53);
  }

  void i64_lt_u() {
    writeByte(0x54);
  }

  void i64_gt_s() {
    writeByte(0x55);
  }

  void i64_gt_u() {
    writeByte(0x56);
  }

  void i64_le_s() {
    writeByte(0x57);
  }

  void i64_le_u() {
    writeByte(0x58);
  }

  void i64_ge_s() {
    writeByte(0x59);
  }

  void i64_ge_u() {
    writeByte(0x5A);
  }

  void f32_eq() {
    writeByte(0x5B);
  }

  void f32_ne() {
    writeByte(0x5C);
  }

  void f32_lt() {
    writeByte(0x5D);
  }

  void f32_gt() {
    writeByte(0x5E);
  }

  void f32_le() {
    writeByte(0x5F);
  }

  void f32_ge() {
    writeByte(0x60);
  }

  void f64_eq() {
    writeByte(0x61);
  }

  void f64_ne() {
    writeByte(0x62);
  }

  void f64_lt() {
    writeByte(0x63);
  }

  void f64_gt() {
    writeByte(0x64);
  }

  void f64_le() {
    writeByte(0x65);
  }

  void f64_ge() {
    writeByte(0x66);
  }

  void i32_clz() {
    writeByte(0x67);
  }

  void i32_ctz() {
    writeByte(0x68);
  }

  void i32_popcnt() {
    writeByte(0x69);
  }

  void i32_add() {
    writeByte(0x6A);
  }

  void i32_sub() {
    writeByte(0x6B);
  }

  void i32_mul() {
    writeByte(0x6C);
  }

  void i32_div_s() {
    writeByte(0x6D);
  }

  void i32_div_u() {
    writeByte(0x6E);
  }

  void i32_rem_s() {
    writeByte(0x6F);
  }

  void i32_rem_u() {
    writeByte(0x70);
  }

  void i32_and() {
    writeByte(0x71);
  }

  void i32_or() {
    writeByte(0x72);
  }

  void i32_xor() {
    writeByte(0x73);
  }

  void i32_shl() {
    writeByte(0x74);
  }

  void i32_shr_s() {
    writeByte(0x75);
  }

  void i32_shr_u() {
    writeByte(0x76);
  }

  void i32_rotl() {
    writeByte(0x77);
  }

  void i32_rotr() {
    writeByte(0x78);
  }

  void i64_clz() {
    writeByte(0x79);
  }

  void i64_ctz() {
    writeByte(0x7A);
  }

  void i64_popcnt() {
    writeByte(0x7B);
  }

  void i64_add() {
    writeByte(0x7C);
  }

  void i64_sub() {
    writeByte(0x7D);
  }

  void i64_mul() {
    writeByte(0x7E);
  }

  void i64_div_s() {
    writeByte(0x7F);
  }

  void i64_div_u() {
    writeByte(0x80);
  }

  void i64_rem_s() {
    writeByte(0x81);
  }

  void i64_rem_u() {
    writeByte(0x82);
  }

  void i64_and() {
    writeByte(0x83);
  }

  void i64_or() {
    writeByte(0x84);
  }

  void i64_xor() {
    writeByte(0x85);
  }

  void i64_shl() {
    writeByte(0x86);
  }

  void i64_shr_s() {
    writeByte(0x87);
  }

  void i64_shr_u() {
    writeByte(0x88);
  }

  void i64_rotl() {
    writeByte(0x89);
  }

  void i64_rotr() {
    writeByte(0x8A);
  }

  void f32_abs() {
    writeByte(0x8B);
  }

  void f32_neg() {
    writeByte(0x8C);
  }

  void f32_ceil() {
    writeByte(0x8D);
  }

  void f32_floor() {
    writeByte(0x8E);
  }

  void f32_trunc() {
    writeByte(0x8F);
  }

  void f32_nearest() {
    writeByte(0x90);
  }

  void f32_sqrt() {
    writeByte(0x91);
  }

  void f32_add() {
    writeByte(0x92);
  }

  void f32_sub() {
    writeByte(0x93);
  }

  void f32_mul() {
    writeByte(0x94);
  }

  void f32_div() {
    writeByte(0x95);
  }

  void f32_min() {
    writeByte(0x96);
  }

  void f32_max() {
    writeByte(0x97);
  }

  void f32_copysign() {
    writeByte(0x98);
  }

  void f64_abs() {
    writeByte(0x99);
  }

  void f64_neg() {
    writeByte(0x9A);
  }

  void f64_ceil() {
    writeByte(0x9B);
  }

  void f64_floor() {
    writeByte(0x9C);
  }

  void f64_trunc() {
    writeByte(0x9D);
  }

  void f64_nearest() {
    writeByte(0x9E);
  }

  void f64_sqrt() {
    writeByte(0x9F);
  }

  void f64_add() {
    writeByte(0xA0);
  }

  void f64_sub() {
    writeByte(0xA1);
  }

  void f64_mul() {
    writeByte(0xA2);
  }

  void f64_div() {
    writeByte(0xA3);
  }

  void f64_min() {
    writeByte(0xA4);
  }

  void f64_max() {
    writeByte(0xA5);
  }

  void f64_copysign() {
    writeByte(0xA6);
  }

  void i32_wrap_i64() {
    writeByte(0xA7);
  }

  void i32_trunc_f32_s() {
    writeByte(0xA8);
  }

  void i32_trunc_f32_u() {
    writeByte(0xA9);
  }

  void i32_trunc_f64_s() {
    writeByte(0xAA);
  }

  void i32_trunc_f64_u() {
    writeByte(0xAB);
  }

  void i64_extend_i32_s() {
    writeByte(0xAC);
  }

  void i64_extend_i32_u() {
    writeByte(0xAD);
  }

  void i64_trunc_f32_s() {
    writeByte(0xAE);
  }

  void i64_trunc_f32_u() {
    writeByte(0xAF);
  }

  void i64_trunc_f64_s() {
    writeByte(0xB0);
  }

  void i64_trunc_f64_u() {
    writeByte(0xB1);
  }

  void f32_convert_i32_s() {
    writeByte(0xB2);
  }

  void f32_convert_i32_u() {
    writeByte(0xB3);
  }

  void f32_convert_i64_s() {
    writeByte(0xB4);
  }

  void f32_convert_i64_u() {
    writeByte(0xB5);
  }

  void f32_demote_f64() {
    writeByte(0xB6);
  }

  void f64_convert_i32_s() {
    writeByte(0xB7);
  }

  void f64_convert_i32_u() {
    writeByte(0xB8);
  }

  void f64_convert_i64_s() {
    writeByte(0xB9);
  }

  void f64_convert_i64_u() {
    writeByte(0xBA);
  }

  void f64_promote_f32() {
    writeByte(0xBB);
  }

  void i32_reinterpret_f32() {
    writeByte(0xBC);
  }

  void i64_reinterpret_f64() {
    writeByte(0xBD);
  }

  void f32_reinterpret_i32() {
    writeByte(0xBE);
  }

  void f64_reinterpret_i64() {
    writeByte(0xBF);
  }

  void i32_extend8_s() {
    writeByte(0xC0);
  }

  void i32_extend16_s() {
    writeByte(0xC1);
  }

  void i64_extend8_s() {
    writeByte(0xC2);
  }

  void i64_extend16_s() {
    writeByte(0xC3);
  }

  void i64_extend32_s() {
    writeByte(0xC4);
  }

  void i32_trunc_sat_f32_s() {
    writeBytes(const [0xFC, 0x00]);
  }

  void i32_trunc_sat_f32_u() {
    writeBytes(const [0xFC, 0x01]);
  }

  void i32_trunc_sat_f64_s() {
    writeBytes(const [0xFC, 0x02]);
  }

  void i32_trunc_sat_f64_u() {
    writeBytes(const [0xFC, 0x03]);
  }

  void i64_trunc_sat_f32_s() {
    writeBytes(const [0xFC, 0x04]);
  }

  void i64_trunc_sat_f32_u() {
    writeBytes(const [0xFC, 0x05]);
  }

  void i64_trunc_sat_f64_s() {
    writeBytes(const [0xFC, 0x06]);
  }

  void i64_trunc_sat_f64_u() {
    writeBytes(const [0xFC, 0x07]);
  }
}
