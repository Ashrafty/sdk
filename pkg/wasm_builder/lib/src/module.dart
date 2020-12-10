// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'instructions.dart';
import 'serialize.dart';
import 'types.dart';

class Module with SerializerMixin {
  Map<_FunctionTypeKey, FunctionType> functionTypeMap = {};

  List<DefType> defTypes = [];
  List<Function> functions = [];
  List<Global> globals = [];
  List<Export> exports = [];
  Function? startFunction = null;

  FunctionType addFunctionType(
      Iterable<ValueType> inputs, Iterable<ValueType> outputs) {
    final List<ValueType> inputList = List.unmodifiable(inputs);
    final List<ValueType> outputList = List.unmodifiable(outputs);
    final _FunctionTypeKey key = _FunctionTypeKey(inputList, outputList);
    return functionTypeMap.putIfAbsent(key, () {
      final type = FunctionType(inputList, outputList)..index = defTypes.length;
      defTypes.add(type);
      return type;
    });
  }

  StructType addStructType(String name, [Iterable<FieldType>? fields]) {
    final type = StructType(name)..index = defTypes.length;
    if (fields != null) type.fields.addAll(fields);
    defTypes.add(type);
    return type;
  }

  ArrayType addArrayType(String name, [FieldType? elementType]) {
    final type = ArrayType(name)..index = defTypes.length;
    if (elementType != null) type.elementType = elementType;
    defTypes.add(type);
    return type;
  }

  Function addFunction(FunctionType type) {
    final function = Function(functions.length, type);
    functions.add(function);
    return function;
  }

  void exportFunction(String name, Function function) {
    exports.add(FunctionExport(name, function));
  }

  void exportGlobal(String name, Global global) {
    exports.add(GlobalExport(name, global));
  }

  Uint8List encode() {
    writeBytes(const [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]);
    TypeSection(this).serialize(this);
    FunctionSection(this).serialize(this);
    GlobalSection(this).serialize(this);
    ExportSection(this).serialize(this);
    StartSection(this).serialize(this);
    CodeSection(this).serialize(this);
    return data;
  }
}

class _FunctionTypeKey {
  List<ValueType> inputs;
  List<ValueType> outputs;

  _FunctionTypeKey(this.inputs, this.outputs);

  @override
  bool operator ==(Object other) {
    if (other is! _FunctionTypeKey) return false;
    if (inputs.length != other.inputs.length) return false;
    if (outputs.length != other.outputs.length) return false;
    for (int i = 0; i < inputs.length; i++) {
      if (inputs[i] != other.inputs[i]) return false;
    }
    for (int i = 0; i < outputs.length; i++) {
      if (outputs[i] != other.outputs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    int inputHash = 13;
    for (var input in inputs) {
      inputHash = inputHash * 17 + input.hashCode;
    }
    int outputHash = 23;
    for (var output in outputs) {
      outputHash = outputHash * 29 + output.hashCode;
    }
    return (inputHash * 2 + 1) * (outputHash * 2 + 1);
  }
}

abstract class Export implements Serializable {
  String name;

  Export(this.name);
}

class FunctionExport extends Export {
  Function function;

  FunctionExport(String name, this.function) : super(name);

  @override
  void serialize(Serializer s) {
    s.writeName(name);
    s.writeByte(0x00);
    s.writeUnsigned(function.index);
  }
}

class GlobalExport extends Export {
  Global global;

  GlobalExport(String name, this.global) : super(name);

  @override
  void serialize(Serializer s) {
    s.writeName(name);
    s.writeByte(0x03);
    s.writeUnsigned(global.index);
  }
}

abstract class Section with SerializerMixin implements Serializable {
  final Module module;

  Section(this.module);

  void serialize(Serializer s) {
    serializeContents();
    s.writeByte(id);
    s.writeUnsigned(data.length);
    s.writeBytes(data);
  }

  int get id;

  void serializeContents();
}

class TypeSection extends Section {
  TypeSection(Module module) : super(module);

  @override
  int get id => 1;

  @override
  void serializeContents() {
    writeList(module.defTypes);
  }
}

class FunctionSection extends Section {
  FunctionSection(Module module) : super(module);

  @override
  int get id => 3;

  @override
  void serializeContents() {
    writeList(module.functions.map((f) => f.type).toList());
  }
}

class GlobalSection extends Section {
  GlobalSection(Module module) : super(module);

  @override
  int get id => 6;

  @override
  void serializeContents() {
    writeList(module.globals);
  }
}

class ExportSection extends Section {
  ExportSection(Module module) : super(module);

  @override
  int get id => 7;

  @override
  void serializeContents() {
    writeList(module.exports);
  }
}

class StartSection extends Section {
  StartSection(Module module) : super(module);

  @override
  int get id => 8;

  @override
  void serializeContents() {
    writeUnsigned(module.startFunction!.index);
  }
}

class CodeSection extends Section {
  CodeSection(Module module) : super(module);

  @override
  int get id => 10;

  @override
  void serializeContents() {
    writeList(module.functions);
  }
}
