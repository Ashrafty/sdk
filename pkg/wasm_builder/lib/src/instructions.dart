// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'module.dart';
import 'serialize.dart';
import 'types.dart';

abstract class Label {
  final List<ValueType> inputs;
  final List<ValueType> outputs;

  int? index;
  late final int depth;
  late final int baseStackHeight;
  bool containsJump = false;

  Label._(this.inputs, this.outputs);

  void markJump() => containsJump = true;

  List<ValueType> get targetTypes;

  bool get jumpToEnd;

  bool get hasIndex => index != null;

  @override
  String toString() => "L$index";
}

class Expression extends Label {
  Expression(List<ValueType> inputs, List<ValueType> outputs)
      : super._(inputs, outputs) {
    depth = 0;
    baseStackHeight = 0;
  }

  List<ValueType> get targetTypes => outputs;

  bool get jumpToEnd => false;
}

class Block extends Label {
  Block(List<ValueType> inputs, List<ValueType> outputs)
      : super._(inputs, outputs);

  List<ValueType> get targetTypes => outputs;

  bool get jumpToEnd => containsJump;
}

class Loop extends Label {
  Loop(List<ValueType> inputs, List<ValueType> outputs)
      : super._(inputs, outputs);

  List<ValueType> get targetTypes => inputs;

  bool get jumpToEnd => false;
}

class If extends Label {
  bool hasElse = false;

  If(List<ValueType> inputs, List<ValueType> outputs)
      : super._(inputs, outputs);

  List<ValueType> get targetTypes => outputs;

  bool get jumpToEnd => containsJump || !hasElse;
}

class Instructions with SerializerMixin {
  final Module module;
  final List<Local> locals;

  bool traceEnabled = true;
  int instructionColumnWidth = 50;
  int _indent = 0;
  List<String> _traceLines = [];

  int labelIndex = 0;
  final List<Label> labelStack = [];
  final List<ValueType> _stackTypes = [];
  bool reachable = true;

  Instructions(this.module, List<ValueType> outputs, [this.locals = const []]) {
    labelStack.add(Expression(const [], outputs));
  }

  bool get isComplete => labelStack.isEmpty;

  String get trace => _traceLines.join();

  void _debugTrace(List<Object> trace,
      {required bool reachableAfter,
      int indentBefore = 0,
      int indentAfter = 0}) {
    if (traceEnabled) {
      _indent += indentBefore;
      String instr = "  " * _indent + trace.join(" ");
      instr = instr.length > instructionColumnWidth - 2
          ? instr.substring(0, instructionColumnWidth - 4) + "... "
          : instr.padRight(instructionColumnWidth);
      final String stack = reachableAfter ? _stackTypes.join(', ') : "-";
      final String line = "$instr$stack\n";
      _indent += indentAfter;

      _traceLines.add(line);
    }
  }

  Never _reportError(String error) {
    throw "$trace\n$error";
  }

  ValueType get _topOfStack {
    if (_stackTypes.isEmpty) _reportError("Stack underflow");
    return _stackTypes.last;
  }

  List<ValueType> _stack(int n) {
    if (_stackTypes.length < n) _reportError("Stack underflow");
    return _stackTypes.sublist(_stackTypes.length - n);
  }

  List<ValueType> _checkStackTypes(List<ValueType> inputs,
      [List<ValueType>? stack]) {
    stack ??= _stack(inputs.length);
    bool typesMatch = true;
    for (int i = 0; i < inputs.length; i++) {
      if (!stack[i].isSubtypeOf(inputs[i])) {
        typesMatch = false;
        break;
      }
    }
    if (!typesMatch) {
      final String expected = inputs.join(', ');
      final String got = stack.join(', ');
      _reportError("Expected [$expected], but stack contained [$got]");
    }
    return stack;
  }

  bool _verifyTypes(List<ValueType> inputs, List<ValueType> outputs,
      {List<Object>? trace, bool reachableAfter = true}) {
    return _verifyTypesFun(inputs, (_) => outputs,
        trace: trace, reachableAfter: reachableAfter);
  }

  bool _verifyTypesFun(List<ValueType> inputs,
      List<ValueType> Function(List<ValueType>) outputsFun,
      {List<Object>? trace, bool reachableAfter = true}) {
    if (!reachable) {
      return true;
    }
    if (_stackTypes.length - inputs.length < labelStack.last.baseStackHeight) {
      _reportError("Underflowing base stack of innermost block");
    }
    final List<ValueType> stack = _checkStackTypes(inputs);
    _stackTypes.length -= inputs.length;
    _stackTypes.addAll(outputsFun(stack));
    if (trace != null) _debugTrace(trace, reachableAfter: reachableAfter);
    return true;
  }

  bool _verifyBranchTypes(Label label,
      [int popped = 0, List<ValueType> pushed = const []]) {
    final List<ValueType> inputs = label.targetTypes;
    if (_stackTypes.length - popped + pushed.length - inputs.length <
        label.baseStackHeight) {
      _reportError("Underflowing base stack of target label");
    }
    final List<ValueType> stack = inputs.length <= pushed.length
        ? pushed.sublist(pushed.length - inputs.length)
        : [
            ..._stackTypes.sublist(
                _stackTypes.length - popped + pushed.length - inputs.length,
                _stackTypes.length - popped),
            ...pushed
          ];
    _checkStackTypes(inputs, stack);
    return true;
  }

  bool _verifyStartOfBlock(Label label, {required List<Object> trace}) {
    _debugTrace(
        ["$label:", ...trace, FunctionType(label.inputs, label.outputs)],
        reachableAfter: true, indentAfter: 1);
    return true;
  }

  bool _verifyEndOfBlock(List<ValueType> outputs,
      {required List<Object> trace,
      required bool reachableAfter,
      required bool reindent}) {
    final Label label = labelStack.last;
    if (reachable) {
      final int expectedHeight = label.baseStackHeight + label.outputs.length;
      if (_stackTypes.length != expectedHeight) {
        _reportError("Incorrect stack height at end of block"
            " (expected $expectedHeight, actual ${_stackTypes.length})");
      }
      _checkStackTypes(label.outputs);
    }
    assert(_stackTypes.length >= label.baseStackHeight);
    _stackTypes.length = label.baseStackHeight;
    _stackTypes.addAll(outputs);
    _debugTrace([if (label.hasIndex) "$label:", ...trace],
        reachableAfter: reachableAfter,
        indentBefore: -1,
        indentAfter: reindent ? 1 : 0);
    return true;
  }

  // Control instructions

  void unreachable() {
    assert(_verifyTypes(const [], const [],
        trace: const ['unreachable'], reachableAfter: false));
    reachable = false;
    writeByte(0x00);
  }

  void nop() {
    assert(_verifyTypes(const [], const [], trace: const ['nop']));
    writeByte(0x01);
  }

  Label _beginBlock(int encoding, Label label, {required List<Object> trace}) {
    assert(_verifyTypes(label.inputs, label.inputs));
    label.index = ++labelIndex;
    label.depth = labelStack.length;
    label.baseStackHeight = _stackTypes.length - label.inputs.length;
    labelStack.add(label);
    writeByte(encoding);
    if (label.inputs.isEmpty && label.outputs.isEmpty) {
      writeByte(0x40);
    } else if (label.inputs.isEmpty && label.outputs.length == 1) {
      write(label.outputs.single);
    } else {
      final type = module.addFunctionType(label.inputs, label.outputs);
      writeSigned(type.index);
    }
    assert(_verifyStartOfBlock(label, trace: trace));
    return label;
  }

  Label block(
      [List<ValueType> inputs = const [], List<ValueType> outputs = const []]) {
    return _beginBlock(0x02, Block(inputs, outputs), trace: const ['block']);
  }

  Label loop(
      [List<ValueType> inputs = const [], List<ValueType> outputs = const []]) {
    return _beginBlock(0x03, Loop(inputs, outputs), trace: const ['loop']);
  }

  Label if_(
      [List<ValueType> inputs = const [], List<ValueType> outputs = const []]) {
    assert(_verifyTypes(const [NumType.i32], const []));
    return _beginBlock(0x04, If(inputs, outputs), trace: const ['if']);
  }

  void else_() {
    assert(labelStack.last is If ||
        _reportError("Unexpected 'else' (not in 'if' block)"));
    final If label = labelStack.last as If;
    assert(!label.hasElse || _reportError("Duplicate 'else' in 'if' block"));
    assert(_verifyEndOfBlock(label.inputs,
        trace: const ['else'], reachableAfter: true, reindent: true));
    label.hasElse = true;
    if (reachable) label.markJump();
    reachable = true;
    writeByte(0x05);
  }

  void end() {
    assert(_verifyEndOfBlock(labelStack.last.outputs,
        trace: const ['end'],
        reachableAfter: reachable || labelStack.last.jumpToEnd,
        reindent: false));
    reachable |= labelStack.last.jumpToEnd;
    labelStack.removeLast();
    writeByte(0x0B);
  }

  int _labelIndex(Label label) {
    final int index = labelStack.length - label.depth - 1;
    assert(labelStack[label.depth] == label);
    return index;
  }

  void _writeLabel(Label label) {
    writeUnsigned(_labelIndex(label));
  }

  void br(Label label) {
    assert(_verifyTypes(const [], const [],
        trace: ['br', label], reachableAfter: false));
    assert(_verifyBranchTypes(label));
    label.markJump();
    reachable = false;
    writeByte(0x0C);
    _writeLabel(label);
  }

  void br_if(Label label) {
    assert(
        _verifyTypes(const [NumType.i32], const [], trace: ['br_if', label]));
    assert(_verifyBranchTypes(label));
    label.markJump();
    writeByte(0x0D);
    _writeLabel(label);
  }

  void br_table(List<Label> labels, Label defaultLabel) {
    assert(_verifyTypes(const [NumType.i32], const [],
        trace: ['br_table', ...labels, defaultLabel], reachableAfter: false));
    for (var label in labels) {
      assert(_verifyBranchTypes(label));
      label.markJump();
    }
    assert(_verifyBranchTypes(defaultLabel));
    defaultLabel.markJump();
    reachable = false;
    writeByte(0x0E);
    writeUnsigned(labels.length);
    for (Label label in labels) {
      _writeLabel(label);
    }
    _writeLabel(defaultLabel);
  }

  void return_() {
    assert(_verifyTypes(labelStack[0].outputs, const [],
        trace: const ['return'], reachableAfter: false));
    reachable = false;
    writeByte(0x0F);
  }

  void call(BaseFunction function) {
    assert(_verifyTypes(function.type.inputs, function.type.outputs,
        trace: ['call', function]));
    writeByte(0x10);
    writeUnsigned(function.index);
  }

  void call_indirect(FunctionType type, [Table? table]) {
    assert(_verifyTypes([...type.inputs, NumType.i32], type.outputs,
        trace: ['call_indirect', type, if (table != null) table.index]));
    writeByte(0x11);
    writeUnsigned(type.index);
    writeUnsigned(table?.index ?? 0);
  }

  bool _verifyCallRef() {
    ValueType fun = _topOfStack;
    if (fun is RefType) {
      var heapType = fun.heapType;
      if (heapType is DefHeapType) {
        var defType = heapType.def;
        if (defType is FunctionType) {
          return _verifyTypes([...defType.inputs, fun], defType.outputs,
              trace: ['call_ref']);
        }
      }
    }
    _reportError("Expected function type, got $fun");
  }

  void call_ref() {
    assert(_verifyCallRef());
    writeByte(0x14);
  }

  // Parametric instructions

  void drop() {
    assert(_verifyTypes([_topOfStack], const [], trace: const ['drop']));
    writeByte(0x1A);
  }

  void select([ValueType? type]) {
    assert(_verifyTypes(const [NumType.i32], const []));
    if (type != null) {
      assert(_verifyTypes([type, type], [type], trace: ['select', type]));
      writeByte(0x1C);
      writeUnsigned(1);
      write(type);
    } else {
      assert(_topOfStack is NumType ||
          _reportError(
              "Input to implicitly typed select instruction must be a numtype"
              " (was $_topOfStack)"));
      assert(_verifyTypes([_topOfStack, _topOfStack], [_topOfStack],
          trace: const ['select']));
      writeByte(0x1B);
    }
  }

  // Variable instructions

  void local_get(Local local) {
    assert(locals[local.index] == local);
    assert(_verifyTypes(const [], [local.type], trace: ['local.get', local]));
    writeByte(0x20);
    writeUnsigned(local.index);
  }

  void local_set(Local local) {
    assert(locals[local.index] == local);
    assert(_verifyTypes([local.type], const [], trace: ['local.set', local]));
    writeByte(0x21);
    writeUnsigned(local.index);
  }

  void local_tee(Local local) {
    assert(locals[local.index] == local);
    assert(
        _verifyTypes([local.type], [local.type], trace: ['local.tee', local]));
    writeByte(0x22);
    writeUnsigned(local.index);
  }

  void global_get(Global global) {
    assert(_verifyTypes(const [], [global.type.type],
        trace: ['global.get', global]));
    writeByte(0x23);
    writeUnsigned(global.index);
  }

  void global_set(Global global) {
    assert(global.type.mutable);
    assert(_verifyTypes([global.type.type], const [],
        trace: ['global.set', global]));
    writeByte(0x24);
    writeUnsigned(global.index);
  }

  // TODO: memory instructions

  // Reference instructions

  void ref_null(HeapType heapType) {
    assert(_verifyTypes(const [], [RefType(heapType, nullable: true)],
        trace: ['ref.null', heapType]));
    writeByte(0xD0);
    write(heapType);
  }

  void ref_is_null() {
    assert(_verifyTypes(const [RefType.any()], const [NumType.i32],
        trace: const ['ref.is_null']));
    writeByte(0xD1);
  }

  void ref_func(BaseFunction function) {
    assert(_verifyTypes(const [], [RefType.def(function.type, nullable: false)],
        trace: ['ref.func', function]));
    writeByte(0xD2);
    writeUnsigned(function.index);
  }

  void ref_as_non_null() {
    assert(_verifyTypes(
        const [RefType.any()], [_topOfStack.withNullability(false)],
        trace: const ['ref.as_non_null']));
    writeByte(0xD3);
  }

  void br_on_null(Label label) {
    assert(_verifyTypes(
        const [RefType.any()], [_topOfStack.withNullability(false)],
        trace: ['br_on_null', label]));
    assert(_verifyBranchTypes(label, 1));
    writeByte(0xD4);
    _writeLabel(label);
  }

  void ref_eq() {
    assert(_verifyTypes(const [RefType.eq(), RefType.eq()], const [NumType.i32],
        trace: const ['ref.eq']));
    writeByte(0xD5);
  }

  void struct_new_with_rtt(StructType structType) {
    assert(_verifyTypes(
        [...structType.fields.map((f) => f.type.unpacked), Rtt(structType)],
        [RefType.def(structType, nullable: false)],
        trace: ['struct.new_with_rtt', structType]));
    writeBytes(const [0xFB, 0x01]);
    writeUnsigned(structType.index);
  }

  void struct_new_default_with_rtt(StructType structType) {
    assert(_verifyTypes(
        [Rtt(structType)], [RefType.def(structType, nullable: false)],
        trace: ['struct.new_default_with_rtt', structType]));
    writeBytes(const [0xFB, 0x02]);
    writeUnsigned(structType.index);
  }

  void struct_get(StructType structType, int fieldIndex) {
    assert(structType.fields[fieldIndex].type is ValueType);
    assert(_verifyTypes([RefType.def(structType, nullable: true)],
        [structType.fields[fieldIndex].type.unpacked],
        trace: ['struct.get', structType, fieldIndex]));
    writeBytes(const [0xFB, 0x03]);
    writeUnsigned(structType.index);
    writeUnsigned(fieldIndex);
  }

  void struct_get_s(StructType structType, int fieldIndex) {
    assert(structType.fields[fieldIndex].type is PackedType);
    assert(_verifyTypes([RefType.def(structType, nullable: true)],
        [structType.fields[fieldIndex].type.unpacked],
        trace: ['struct.get_s', structType, fieldIndex]));
    writeBytes(const [0xFB, 0x04]);
    writeUnsigned(structType.index);
    writeUnsigned(fieldIndex);
  }

  void struct_get_u(StructType structType, int fieldIndex) {
    assert(structType.fields[fieldIndex].type is PackedType);
    assert(_verifyTypes([RefType.def(structType, nullable: true)],
        [structType.fields[fieldIndex].type.unpacked],
        trace: ['struct.get_u', structType, fieldIndex]));
    writeBytes(const [0xFB, 0x05]);
    writeUnsigned(structType.index);
    writeUnsigned(fieldIndex);
  }

  void struct_set(StructType structType, int fieldIndex) {
    assert(_verifyTypes([
      RefType.def(structType, nullable: true),
      structType.fields[fieldIndex].type.unpacked
    ], const [], trace: [
      'struct.set',
      structType,
      fieldIndex
    ]));
    writeBytes(const [0xFB, 0x06]);
    writeUnsigned(structType.index);
    writeUnsigned(fieldIndex);
  }

  void array_new_with_rtt(ArrayType arrayType) {
    assert(_verifyTypes(
        [arrayType.elementType.type.unpacked, NumType.i32, Rtt(arrayType)],
        [RefType.def(arrayType, nullable: false)],
        trace: ['array.new_with_rtt', arrayType]));
    writeBytes(const [0xFB, 0x11]);
    writeUnsigned(arrayType.index);
  }

  void array_new_default_with_rtt(ArrayType arrayType) {
    assert(_verifyTypes([NumType.i32, Rtt(arrayType)],
        [RefType.def(arrayType, nullable: false)],
        trace: ['array.new_default_with_rtt', arrayType]));
    writeBytes(const [0xFB, 0x12]);
    writeUnsigned(arrayType.index);
  }

  void array_get(ArrayType arrayType) {
    assert(arrayType.elementType.type is ValueType);
    assert(_verifyTypes([RefType.def(arrayType, nullable: true), NumType.i32],
        [arrayType.elementType.type.unpacked],
        trace: ['array.get', arrayType]));
    writeBytes(const [0xFB, 0x13]);
    writeUnsigned(arrayType.index);
  }

  void array_get_s(ArrayType arrayType) {
    assert(arrayType.elementType.type is PackedType);
    assert(_verifyTypes([RefType.def(arrayType, nullable: true), NumType.i32],
        [arrayType.elementType.type.unpacked],
        trace: ['array.get_s', arrayType]));
    writeBytes(const [0xFB, 0x14]);
    writeUnsigned(arrayType.index);
  }

  void array_get_u(ArrayType arrayType) {
    assert(arrayType.elementType.type is PackedType);
    assert(_verifyTypes([RefType.def(arrayType, nullable: true), NumType.i32],
        [arrayType.elementType.type.unpacked],
        trace: ['array.get_u', arrayType]));
    writeBytes(const [0xFB, 0x15]);
    writeUnsigned(arrayType.index);
  }

  void array_set(ArrayType arrayType) {
    assert(_verifyTypes([
      RefType.def(arrayType, nullable: true),
      NumType.i32,
      arrayType.elementType.type.unpacked
    ], const [], trace: [
      'array.set',
      arrayType
    ]));
    writeBytes(const [0xFB, 0x16]);
    writeUnsigned(arrayType.index);
  }

  void array_len(ArrayType arrayType) {
    assert(_verifyTypes(
        [RefType.def(arrayType, nullable: true)], const [NumType.i32],
        trace: ['array.len', arrayType]));
    writeBytes(const [0xFB, 0x17]);
    writeUnsigned(arrayType.index);
  }

  void i31_new() {
    assert(_verifyTypes(const [NumType.i32], const [RefType.i31()],
        trace: const ['i31.new']));
    writeBytes(const [0xFB, 0x20]);
  }

  void i31_get_s() {
    assert(_verifyTypes(const [RefType.i31()], const [NumType.i32],
        trace: const ['i31.get_s']));
    writeBytes(const [0xFB, 0x21]);
  }

  void i31_get_u() {
    assert(_verifyTypes(const [RefType.i31()], const [NumType.i32],
        trace: const ['i31.get_u']));
    writeBytes(const [0xFB, 0x22]);
  }

  void rtt_canon(DataType dataType) {
    assert(_verifyTypes(const [], [Rtt(dataType, 0)],
        trace: ['rtt.canon', dataType]));
    writeBytes(const [0xFB, 0x30]);
    writeSigned(dataType.index);
  }

  bool _verifyRttSub(DataType subType) {
    final ValueType input = _topOfStack;
    if (input is! Rtt) _reportError("Expected rtt, but stack contained $input");
    final int? depth = input.depth;
    if (depth == null) _reportError("Expected rtt with known depth");
    final DefType superType = input.defType;
    if (!subType.isSubtypeOf(superType)) {
      _reportError("Expected supertype of $subType, but got $superType");
    }
    return _verifyTypes([input], [Rtt(subType, depth + 1)],
        trace: ['rtt.sub', subType]);
  }

  void rtt_sub(DataType dataType) {
    assert(_verifyRttSub(dataType));
    writeBytes(const [0xFB, 0x31]);
    writeSigned(dataType.index);
  }

  bool _verifyCast(List<ValueType> Function(List<ValueType>) outputsFun,
      {List<Object>? trace}) {
    final stack = _stack(2);
    final ValueType value = stack[0];
    final ValueType rtt = stack[1];
    if (rtt is! Rtt ||
        !value.isSubtypeOf(const RefType.data(nullable: true)) &&
            !value.isSubtypeOf(const RefType.func(nullable: true))) {
      _reportError("Expected [data or func, rtt], but stack contained $stack");
    }
    return _verifyTypesFun(stack, outputsFun, trace: trace);
  }

  void ref_test() {
    assert(_verifyCast((_) => const [NumType.i32], trace: ['ref.test']));
    writeBytes(const [0xFB, 0x40]);
  }

  void ref_cast() {
    assert(_verifyCast(
        (inputs) => [
              RefType.def((inputs[1] as Rtt).defType,
                  nullable: inputs[0].nullable)
            ],
        trace: const ['ref.cast']));
    writeBytes(const [0xFB, 0x41]);
  }

  void br_on_cast(Label label) {
    late final DefType targetType;
    assert(_verifyCast((inputs) {
      targetType = (inputs[1] as Rtt).defType;
      return [inputs[0]];
    }, trace: ['br_on_cast', label]));
    assert(_verifyBranchTypes(
        label, 1, [RefType.def(targetType, nullable: false)]));
    writeBytes(const [0xFB, 0x42]);
    _writeLabel(label);
  }

  void ref_is_func() {
    assert(_verifyTypes(const [RefType.any()], const [NumType.i32],
        trace: const ['ref.is_func']));
    writeBytes(const [0xFB, 0x50]);
  }

  void ref_is_data() {
    assert(_verifyTypes(const [RefType.any()], const [NumType.i32],
        trace: const ['ref.is_data']));
    writeBytes(const [0xFB, 0x51]);
  }

  void ref_is_i31() {
    assert(_verifyTypes(const [RefType.any()], const [NumType.i32],
        trace: const ['ref.is_i31']));
    writeBytes(const [0xFB, 0x52]);
  }

  void ref_as_func() {
    assert(_verifyTypes(
        const [RefType.any()], const [RefType.func(nullable: false)],
        trace: const ['ref.as_func']));
    writeBytes(const [0xFB, 0x58]);
  }

  void ref_as_data() {
    assert(_verifyTypes(
        const [RefType.any()], const [RefType.data(nullable: false)],
        trace: const ['ref.as_data']));
    writeBytes(const [0xFB, 0x59]);
  }

  void ref_as_i31() {
    assert(_verifyTypes(
        const [RefType.any()], const [RefType.i31(nullable: false)],
        trace: const ['ref.as_i31']));
    writeBytes(const [0xFB, 0x5A]);
  }

  void br_on_func(Label label) {
    assert(_verifyTypes(const [RefType.any()], [_topOfStack],
        trace: ['br_on_func', label]));
    assert(_verifyBranchTypes(label, 1, const [RefType.func(nullable: false)]));
    writeBytes(const [0xFB, 0x60]);
    _writeLabel(label);
  }

  void br_on_data(Label label) {
    assert(_verifyTypes(const [RefType.any()], [_topOfStack],
        trace: ['br_on_data', label]));
    assert(_verifyBranchTypes(label, 1, const [RefType.data(nullable: false)]));
    writeBytes(const [0xFB, 0x61]);
    _writeLabel(label);
  }

  void br_on_i31(Label label) {
    assert(_verifyTypes(const [RefType.any()], [_topOfStack],
        trace: ['br_on_i31', label]));
    assert(_verifyBranchTypes(label, 1, const [RefType.i31(nullable: false)]));
    writeBytes(const [0xFB, 0x62]);
    _writeLabel(label);
  }

  // Numeric instructions

  void i32_const(int value) {
    assert(_verifyTypes(const [], const [NumType.i32],
        trace: ['i32.const', value]));
    assert(-1 << 31 <= value && value < 1 << 31);
    writeByte(0x41);
    writeSigned(value);
  }

  void i64_const(int value) {
    assert(_verifyTypes(const [], const [NumType.i64],
        trace: ['i64.const', value]));
    writeByte(0x42);
    writeSigned(value);
  }

  void f32_const(double value) {
    assert(_verifyTypes(const [], const [NumType.f32],
        trace: ['f32.const', value]));
    writeByte(0x43);
    writeF32(value);
  }

  void f64_const(double value) {
    assert(_verifyTypes(const [], const [NumType.f64],
        trace: ['f64.const', value]));
    writeByte(0x44);
    writeF64(value);
  }

  void i32_eqz() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.i32],
        trace: const ['i32.eqz']));
    writeByte(0x45);
  }

  void i32_eq() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.eq']));
    writeByte(0x46);
  }

  void i32_ne() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.ne']));
    writeByte(0x47);
  }

  void i32_lt_s() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.lt_s']));
    writeByte(0x48);
  }

  void i32_lt_u() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.lt_u']));
    writeByte(0x49);
  }

  void i32_gt_s() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.gt_s']));
    writeByte(0x4A);
  }

  void i32_gt_u() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.gt_u']));
    writeByte(0x4B);
  }

  void i32_le_s() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.le_s']));
    writeByte(0x4C);
  }

  void i32_le_u() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.le_u']));
    writeByte(0x4D);
  }

  void i32_ge_s() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.ge_s']));
    writeByte(0x4E);
  }

  void i32_ge_u() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.ge_u']));
    writeByte(0x4F);
  }

  void i64_eqz() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.i32],
        trace: const ['i64.eqz']));
    writeByte(0x50);
  }

  void i64_eq() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.eq']));
    writeByte(0x51);
  }

  void i64_ne() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.ne']));
    writeByte(0x52);
  }

  void i64_lt_s() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.lt_s']));
    writeByte(0x53);
  }

  void i64_lt_u() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.lt_u']));
    writeByte(0x54);
  }

  void i64_gt_s() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.gt_s']));
    writeByte(0x55);
  }

  void i64_gt_u() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.gt_u']));
    writeByte(0x56);
  }

  void i64_le_s() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.le_s']));
    writeByte(0x57);
  }

  void i64_le_u() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.le_u']));
    writeByte(0x58);
  }

  void i64_ge_s() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.ge_s']));
    writeByte(0x59);
  }

  void i64_ge_u() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i32],
        trace: const ['i64.ge_u']));
    writeByte(0x5A);
  }

  void f32_eq() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.i32],
        trace: const ['f32.eq']));
    writeByte(0x5B);
  }

  void f32_ne() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.i32],
        trace: const ['f32.ne']));
    writeByte(0x5C);
  }

  void f32_lt() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.i32],
        trace: const ['f32.lt']));
    writeByte(0x5D);
  }

  void f32_gt() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.i32],
        trace: const ['f32.gt']));
    writeByte(0x5E);
  }

  void f32_le() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.i32],
        trace: const ['f32.le']));
    writeByte(0x5F);
  }

  void f32_ge() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.i32],
        trace: const ['f32.ge']));
    writeByte(0x60);
  }

  void f64_eq() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.i32],
        trace: const ['f64.eq']));
    writeByte(0x61);
  }

  void f64_ne() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.i32],
        trace: const ['f64.ne']));
    writeByte(0x62);
  }

  void f64_lt() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.i32],
        trace: const ['f64.lt']));
    writeByte(0x63);
  }

  void f64_gt() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.i32],
        trace: const ['f64.gt']));
    writeByte(0x64);
  }

  void f64_le() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.i32],
        trace: const ['f64.le']));
    writeByte(0x65);
  }

  void f64_ge() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.i32],
        trace: const ['f64.ge']));
    writeByte(0x66);
  }

  void i32_clz() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.i32],
        trace: const ['i32.clz']));
    writeByte(0x67);
  }

  void i32_ctz() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.i32],
        trace: const ['i32.ctz']));
    writeByte(0x68);
  }

  void i32_popcnt() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.i32],
        trace: const ['i32.popcnt']));
    writeByte(0x69);
  }

  void i32_add() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.add']));
    writeByte(0x6A);
  }

  void i32_sub() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.sub']));
    writeByte(0x6B);
  }

  void i32_mul() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.mul']));
    writeByte(0x6C);
  }

  void i32_div_s() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.div_s']));
    writeByte(0x6D);
  }

  void i32_div_u() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.div_u']));
    writeByte(0x6E);
  }

  void i32_rem_s() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.rem_s']));
    writeByte(0x6F);
  }

  void i32_rem_u() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.rem_u']));
    writeByte(0x70);
  }

  void i32_and() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.and']));
    writeByte(0x71);
  }

  void i32_or() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.or']));
    writeByte(0x72);
  }

  void i32_xor() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.xor']));
    writeByte(0x73);
  }

  void i32_shl() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.shl']));
    writeByte(0x74);
  }

  void i32_shr_s() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.shr_s']));
    writeByte(0x75);
  }

  void i32_shr_u() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.shr_u']));
    writeByte(0x76);
  }

  void i32_rotl() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.rotl']));
    writeByte(0x77);
  }

  void i32_rotr() {
    assert(_verifyTypes(const [NumType.i32, NumType.i32], const [NumType.i32],
        trace: const ['i32.rotr']));
    writeByte(0x78);
  }

  void i64_clz() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.i64],
        trace: const ['i64.clz']));
    writeByte(0x79);
  }

  void i64_ctz() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.i64],
        trace: const ['i64.ctz']));
    writeByte(0x7A);
  }

  void i64_popcnt() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.i64],
        trace: const ['i64.popcnt']));
    writeByte(0x7B);
  }

  void i64_add() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.add']));
    writeByte(0x7C);
  }

  void i64_sub() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.sub']));
    writeByte(0x7D);
  }

  void i64_mul() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.mul']));
    writeByte(0x7E);
  }

  void i64_div_s() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.div_s']));
    writeByte(0x7F);
  }

  void i64_div_u() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.div_u']));
    writeByte(0x80);
  }

  void i64_rem_s() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.rem_s']));
    writeByte(0x81);
  }

  void i64_rem_u() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.rem_u']));
    writeByte(0x82);
  }

  void i64_and() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.and']));
    writeByte(0x83);
  }

  void i64_or() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.or']));
    writeByte(0x84);
  }

  void i64_xor() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.xor']));
    writeByte(0x85);
  }

  void i64_shl() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.shl']));
    writeByte(0x86);
  }

  void i64_shr_s() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.shr_s']));
    writeByte(0x87);
  }

  void i64_shr_u() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.shr_u']));
    writeByte(0x88);
  }

  void i64_rotl() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.rotl']));
    writeByte(0x89);
  }

  void i64_rotr() {
    assert(_verifyTypes(const [NumType.i64, NumType.i64], const [NumType.i64],
        trace: const ['i64.rotr']));
    writeByte(0x8A);
  }

  void f32_abs() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.f32],
        trace: const ['f32.abs']));
    writeByte(0x8B);
  }

  void f32_neg() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.f32],
        trace: const ['f32.neg']));
    writeByte(0x8C);
  }

  void f32_ceil() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.f32],
        trace: const ['f32.ceil']));
    writeByte(0x8D);
  }

  void f32_floor() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.f32],
        trace: const ['f32.floor']));
    writeByte(0x8E);
  }

  void f32_trunc() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.f32],
        trace: const ['f32.trunc']));
    writeByte(0x8F);
  }

  void f32_nearest() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.f32],
        trace: const ['f32.nearest']));
    writeByte(0x90);
  }

  void f32_sqrt() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.f32],
        trace: const ['f32.sqrt']));
    writeByte(0x91);
  }

  void f32_add() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.f32],
        trace: const ['f32.add']));
    writeByte(0x92);
  }

  void f32_sub() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.f32],
        trace: const ['f32.sub']));
    writeByte(0x93);
  }

  void f32_mul() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.f32],
        trace: const ['f32.mul']));
    writeByte(0x94);
  }

  void f32_div() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.f32],
        trace: const ['f32.div']));
    writeByte(0x95);
  }

  void f32_min() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.f32],
        trace: const ['f32.min']));
    writeByte(0x96);
  }

  void f32_max() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.f32],
        trace: const ['f32.max']));
    writeByte(0x97);
  }

  void f32_copysign() {
    assert(_verifyTypes(const [NumType.f32, NumType.f32], const [NumType.f32],
        trace: const ['f32.copysign']));
    writeByte(0x98);
  }

  void f64_abs() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.f64],
        trace: const ['f64.abs']));
    writeByte(0x99);
  }

  void f64_neg() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.f64],
        trace: const ['f64.neg']));
    writeByte(0x9A);
  }

  void f64_ceil() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.f64],
        trace: const ['f64.ceil']));
    writeByte(0x9B);
  }

  void f64_floor() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.f64],
        trace: const ['f64.floor']));
    writeByte(0x9C);
  }

  void f64_trunc() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.f64],
        trace: const ['f64.trunc']));
    writeByte(0x9D);
  }

  void f64_nearest() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.f64],
        trace: const ['f64.nearest']));
    writeByte(0x9E);
  }

  void f64_sqrt() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.f64],
        trace: const ['f64.sqrt']));
    writeByte(0x9F);
  }

  void f64_add() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.f64],
        trace: const ['f64.add']));
    writeByte(0xA0);
  }

  void f64_sub() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.f64],
        trace: const ['f64.sub']));
    writeByte(0xA1);
  }

  void f64_mul() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.f64],
        trace: const ['f64.mul']));
    writeByte(0xA2);
  }

  void f64_div() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.f64],
        trace: const ['f64.div']));
    writeByte(0xA3);
  }

  void f64_min() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.f64],
        trace: const ['f64.min']));
    writeByte(0xA4);
  }

  void f64_max() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.f64],
        trace: const ['f64.max']));
    writeByte(0xA5);
  }

  void f64_copysign() {
    assert(_verifyTypes(const [NumType.f64, NumType.f64], const [NumType.f64],
        trace: const ['f64.copysign']));
    writeByte(0xA6);
  }

  void i32_wrap_i64() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.i32],
        trace: const ['i32.wrap_i64']));
    writeByte(0xA7);
  }

  void i32_trunc_f32_s() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.i32],
        trace: const ['i32.trunc_f32_s']));
    writeByte(0xA8);
  }

  void i32_trunc_f32_u() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.i32],
        trace: const ['i32.trunc_f32_u']));
    writeByte(0xA9);
  }

  void i32_trunc_f64_s() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.i32],
        trace: const ['i32.trunc_f64_s']));
    writeByte(0xAA);
  }

  void i32_trunc_f64_u() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.i32],
        trace: const ['i32.trunc_f64_u']));
    writeByte(0xAB);
  }

  void i64_extend_i32_s() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.i64],
        trace: const ['i64.extend_i32_s']));
    writeByte(0xAC);
  }

  void i64_extend_i32_u() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.i64],
        trace: const ['i64.extend_i32_u']));
    writeByte(0xAD);
  }

  void i64_trunc_f32_s() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.i64],
        trace: const ['i64.trunc_f32_s']));
    writeByte(0xAE);
  }

  void i64_trunc_f32_u() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.i64],
        trace: const ['i64.trunc_f32_u']));
    writeByte(0xAF);
  }

  void i64_trunc_f64_s() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.i64],
        trace: const ['i64.trunc_f64_s']));
    writeByte(0xB0);
  }

  void i64_trunc_f64_u() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.i64],
        trace: const ['i64.trunc_f64_u']));
    writeByte(0xB1);
  }

  void f32_convert_i32_s() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.f32],
        trace: const ['f32.convert_i32_s']));
    writeByte(0xB2);
  }

  void f32_convert_i32_u() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.f32],
        trace: const ['f32.convert_i32_u']));
    writeByte(0xB3);
  }

  void f32_convert_i64_s() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.f32],
        trace: const ['f32.convert_i64_s']));
    writeByte(0xB4);
  }

  void f32_convert_i64_u() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.f32],
        trace: const ['f32.convert_i64_u']));
    writeByte(0xB5);
  }

  void f32_demote_f64() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.f32],
        trace: const ['f32.demote_f64']));
    writeByte(0xB6);
  }

  void f64_convert_i32_s() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.f64],
        trace: const ['f64.convert_i32_s']));
    writeByte(0xB7);
  }

  void f64_convert_i32_u() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.f64],
        trace: const ['f64.convert_i32_u']));
    writeByte(0xB8);
  }

  void f64_convert_i64_s() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.f64],
        trace: const ['f64.convert_i64_s']));
    writeByte(0xB9);
  }

  void f64_convert_i64_u() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.f64],
        trace: const ['f64.convert_i64_u']));
    writeByte(0xBA);
  }

  void f64_promote_f32() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.f64],
        trace: const ['f64.promote_f32']));
    writeByte(0xBB);
  }

  void i32_reinterpret_f32() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.i32],
        trace: const ['i32.reinterpret_f32']));
    writeByte(0xBC);
  }

  void i64_reinterpret_f64() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.i64],
        trace: const ['i64.reinterpret_f64']));
    writeByte(0xBD);
  }

  void f32_reinterpret_i32() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.f32],
        trace: const ['f32.reinterpret_i32']));
    writeByte(0xBE);
  }

  void f64_reinterpret_i64() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.f64],
        trace: const ['f64.reinterpret_i64']));
    writeByte(0xBF);
  }

  void i32_extend8_s() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.i32],
        trace: const ['i32.extend8_s']));
    writeByte(0xC0);
  }

  void i32_extend16_s() {
    assert(_verifyTypes(const [NumType.i32], const [NumType.i32],
        trace: const ['i32.extend16_s']));
    writeByte(0xC1);
  }

  void i64_extend8_s() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.i64],
        trace: const ['i64.extend8_s']));
    writeByte(0xC2);
  }

  void i64_extend16_s() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.i64],
        trace: const ['i64.extend16_s']));
    writeByte(0xC3);
  }

  void i64_extend32_s() {
    assert(_verifyTypes(const [NumType.i64], const [NumType.i64],
        trace: const ['i64.extend32_s']));
    writeByte(0xC4);
  }

  void i32_trunc_sat_f32_s() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.i32],
        trace: const ['i32.trunc_sat_f32_s']));
    writeBytes(const [0xFC, 0x00]);
  }

  void i32_trunc_sat_f32_u() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.i32],
        trace: const ['i32.trunc_sat_f32_u']));
    writeBytes(const [0xFC, 0x01]);
  }

  void i32_trunc_sat_f64_s() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.i32],
        trace: const ['i32.trunc_sat_f64_s']));
    writeBytes(const [0xFC, 0x02]);
  }

  void i32_trunc_sat_f64_u() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.i32],
        trace: const ['i32.trunc_sat_f64_u']));
    writeBytes(const [0xFC, 0x03]);
  }

  void i64_trunc_sat_f32_s() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.i64],
        trace: const ['i64.trunc_sat_f32_s']));
    writeBytes(const [0xFC, 0x04]);
  }

  void i64_trunc_sat_f32_u() {
    assert(_verifyTypes(const [NumType.f32], const [NumType.i64],
        trace: const ['i64.trunc_sat_f32_u']));
    writeBytes(const [0xFC, 0x05]);
  }

  void i64_trunc_sat_f64_s() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.i64],
        trace: const ['i64.trunc_sat_f64_s']));
    writeBytes(const [0xFC, 0x06]);
  }

  void i64_trunc_sat_f64_u() {
    assert(_verifyTypes(const [NumType.f64], const [NumType.i64],
        trace: const ['i64.trunc_sat_f64_u']));
    writeBytes(const [0xFC, 0x07]);
  }
}
