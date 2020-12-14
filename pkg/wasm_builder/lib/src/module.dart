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
  List<BaseFunction> functions = [];
  List<Global> globals = [];
  List<Export> exports = [];
  BaseFunction? startFunction = null;

  bool anyFunctionsDefined = false;
  bool anyGlobalsDefined = false;

  Iterable<Import> get imports =>
      functions.whereType<Import>().followedBy(globals.whereType<Import>());

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

  DefinedFunction addFunction(FunctionType type) {
    anyFunctionsDefined = true;
    final function = DefinedFunction(this, functions.length, type);
    functions.add(function);
    return function;
  }

  DefinedGlobal addGlobal(GlobalType type) {
    anyGlobalsDefined = true;
    final global = DefinedGlobal(this, functions.length, type);
    globals.add(global);
    return global;
  }

  ImportedFunction importFunction(
      String module, String name, FunctionType type) {
    if (anyFunctionsDefined) {
      throw "All function imports must be specified before any definitions.";
    }
    final function = ImportedFunction(module, name, functions.length, type);
    functions.add(function);
    return function;
  }

  ImportedGlobal importGlobal(String module, String name, GlobalType type) {
    if (anyGlobalsDefined) {
      throw "All global imports must be specified before any definitions.";
    }
    final global = ImportedGlobal(module, name, functions.length, type);
    globals.add(global);
    return global;
  }

  void exportFunction(String name, BaseFunction function) {
    exports.add(FunctionExport(name, function));
  }

  void exportGlobal(String name, Global global) {
    exports.add(GlobalExport(name, global));
  }

  Uint8List encode() {
    writeBytes(const [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]);
    TypeSection(this).serialize(this);
    ImportSection(this).serialize(this);
    FunctionSection(this).serialize(this);
    GlobalSection(this).serialize(this);
    ExportSection(this).serialize(this);
    if (startFunction != null) StartSection(this).serialize(this);
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

abstract class BaseFunction {
  int index;
  final FunctionType type;

  BaseFunction(this.index, this.type);
}

class DefinedFunction extends BaseFunction
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
  final GlobalType type;

  Global(this.index, this.type);
}

class DefinedGlobal extends Global implements Serializable {
  final Instructions initializer;

  DefinedGlobal(Module module, int index, GlobalType type)
      : initializer = Instructions(module, [type.type]),
        super(index, type);

  @override
  void serialize(Serializer s) {
    assert(initializer.isComplete);
    s.write(type);
    s.writeBytes(initializer.data);
  }
}

abstract class Import implements Serializable {
  String get module;
  String get name;
}

class ImportedFunction extends BaseFunction implements Import {
  String module;
  String name;

  ImportedFunction(this.module, this.name, int index, FunctionType type)
      : super(index, type);

  @override
  void serialize(Serializer s) {
    s.writeName(module);
    s.writeName(name);
    s.writeByte(0x00);
    s.writeUnsigned(type.index);
  }
}

class ImportedGlobal extends Global implements Import {
  String module;
  String name;

  ImportedGlobal(this.module, this.name, int index, GlobalType type)
      : super(index, type);

  @override
  void serialize(Serializer s) {
    s.writeName(module);
    s.writeName(name);
    s.writeByte(0x03);
    s.write(type);
  }
}

abstract class Export implements Serializable {
  String name;

  Export(this.name);
}

class FunctionExport extends Export {
  BaseFunction function;

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

class ImportSection extends Section {
  ImportSection(Module module) : super(module);

  @override
  int get id => 2;

  @override
  void serializeContents() {
    writeList(module.imports.toList());
  }
}

class FunctionSection extends Section {
  FunctionSection(Module module) : super(module);

  @override
  int get id => 3;

  @override
  void serializeContents() {
    writeUnsigned(module.functions.whereType<DefinedFunction>().length);
    for (var function in module.functions) {
      if (function is DefinedFunction) writeUnsigned(function.type.index);
    }
  }
}

class GlobalSection extends Section {
  GlobalSection(Module module) : super(module);

  @override
  int get id => 6;

  @override
  void serializeContents() {
    writeList(module.globals.whereType<DefinedGlobal>().toList());
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
    writeList(module.functions.whereType<DefinedFunction>().toList());
  }
}
