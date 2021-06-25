// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'instructions.dart';
import 'serialize.dart';
import 'types.dart';

class Module with SerializerMixin {
  final List<int>? watchPoints;

  final Map<_FunctionTypeKey, FunctionType> functionTypeMap = {};

  final List<DefType> defTypes = [];
  final List<BaseFunction> functions = [];
  final List<Table> tables = [];
  final List<Memory> memories = [];
  final List<Global> globals = [];
  final List<Export> exports = [];
  BaseFunction? startFunction = null;

  bool anyFunctionsDefined = false;
  bool anyGlobalsDefined = false;

  Module({this.watchPoints}) {
    if (watchPoints != null) {
      SerializerMixin.traceEnabled = true;
    }
  }

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

  StructType addStructType(String name,
      {Iterable<FieldType>? fields, StructType? superType}) {
    final type = StructType(name, superType: superType)
      ..index = defTypes.length;
    if (fields != null) type.fields.addAll(fields);
    defTypes.add(type);
    return type;
  }

  ArrayType addArrayType(String name,
      {FieldType? elementType, ArrayType? superType}) {
    final type = ArrayType(name, superType: superType)..index = defTypes.length;
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

  Table addTable(int minSize, [int? maxSize]) {
    final table = Table(tables.length, minSize, maxSize);
    tables.add(table);
    return table;
  }

  Memory addMemory(int minSize, [int? maxSize]) {
    final memory = Memory(memories.length, minSize, maxSize);
    memories.add(memory);
    return memory;
  }

  DefinedGlobal addGlobal(GlobalType type) {
    anyGlobalsDefined = true;
    final global = DefinedGlobal(this, globals.length, type);
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

  void _addExport(Export export) {
    assert(!exports.any((e) => e.name == export.name), export.name);
    exports.add(export);
  }

  void exportFunction(String name, BaseFunction function) {
    function.exportedName = name;
    _addExport(FunctionExport(name, function));
  }

  void exportGlobal(String name, Global global) {
    exports.add(GlobalExport(name, global));
  }

  Uint8List encode() {
    writeBytes(const [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]);
    TypeSection(this).serialize(this);
    ImportSection(this).serialize(this);
    FunctionSection(this).serialize(this);
    TableSection(this).serialize(this);
    MemorySection(this).serialize(this);
    GlobalSection(this).serialize(this);
    ExportSection(this).serialize(this);
    StartSection(this).serialize(this);
    ElementSection(this).serialize(this);
    CodeSection(this).serialize(this);
    DataSection(this).serialize(this);
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
  String? exportedName;

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
    int start = paramCount;
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
    s.writeData(this);
    s.writeData(body);
  }

  @override
  String toString() => exportedName ?? "#$index";
}

class Local {
  final int index;
  final ValueType type;

  Local(this.index, this.type);

  @override
  String toString() => "$index";
}

class Table implements Serializable {
  int index;
  int minSize;
  int? maxSize;
  List<BaseFunction?> elements;

  Table(this.index, this.minSize, this.maxSize)
      : elements = List.filled(minSize, null);

  void setElement(int index, BaseFunction function) {
    elements[index] = function;
  }

  @override
  void serialize(Serializer s) {
    s.writeByte(0x70); // funcref
    if (maxSize == null) {
      s.writeByte(0x00);
      s.writeUnsigned(minSize);
    } else {
      s.writeByte(0x01);
      s.writeUnsigned(minSize);
      s.writeUnsigned(maxSize!);
    }
  }
}

class Memory implements Serializable {
  int index;
  int minSize;
  int? maxSize;
  List<Data> data = [];

  Memory(this.index, this.minSize, [this.maxSize]);

  void addData(int offset, Uint8List init) {
    assert(offset >= 0 && offset + init.length <= minSize);
    data.add(Data(offset, init));
  }

  @override
  void serialize(Serializer s) {
    if (maxSize == null) {
      s.writeByte(0x00);
      s.writeUnsigned(minSize);
    } else {
      s.writeByte(0x01);
      s.writeUnsigned(minSize);
      s.writeUnsigned(maxSize!);
    }
  }
}

class Data {
  int offset;
  Uint8List init;

  Data(this.offset, this.init);
}

abstract class Global {
  final int index;
  final GlobalType type;

  Global(this.index, this.type);

  @override
  String toString() => "$index";
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
    s.writeData(initializer);
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

  @override
  String toString() => "$module.$name";
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
    if (isNotEmpty) {
      serializeContents();
      s.writeByte(id);
      s.writeUnsigned(data.length);
      s.writeData(this, module.watchPoints);
    }
  }

  int get id;

  bool get isNotEmpty;

  void serializeContents();
}

class TypeSection extends Section {
  TypeSection(Module module) : super(module);

  @override
  int get id => 1;

  @override
  bool get isNotEmpty => module.defTypes.isNotEmpty;

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
  bool get isNotEmpty => module.imports.isNotEmpty;

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
  bool get isNotEmpty =>
      module.functions.whereType<DefinedFunction>().isNotEmpty;

  @override
  void serializeContents() {
    writeUnsigned(module.functions.whereType<DefinedFunction>().length);
    for (var function in module.functions) {
      if (function is DefinedFunction) writeUnsigned(function.type.index);
    }
  }
}

class TableSection extends Section {
  TableSection(Module module) : super(module);

  @override
  int get id => 4;

  @override
  bool get isNotEmpty => module.tables.isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.tables);
  }
}

class MemorySection extends Section {
  MemorySection(Module module) : super(module);

  @override
  int get id => 5;

  @override
  bool get isNotEmpty => module.memories.isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.memories);
  }
}

class GlobalSection extends Section {
  GlobalSection(Module module) : super(module);

  @override
  int get id => 6;

  @override
  bool get isNotEmpty => module.globals.whereType<DefinedGlobal>().isNotEmpty;

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
  bool get isNotEmpty => module.exports.isNotEmpty;

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
  bool get isNotEmpty => module.startFunction != null;

  @override
  void serializeContents() {
    writeUnsigned(module.startFunction!.index);
  }
}

class _Element implements Serializable {
  Table table;
  int startIndex;
  List<BaseFunction> entries = [];

  _Element(this.table, this.startIndex);

  @override
  void serialize(Serializer s) {
    s.writeUnsigned(table.index);
    s.writeByte(0x41); // i32.const
    s.writeSigned(startIndex);
    s.writeByte(0x0B); // end
    s.writeUnsigned(entries.length);
    for (var entry in entries) {
      s.writeUnsigned(entry.index);
    }
  }
}

class ElementSection extends Section {
  ElementSection(Module module) : super(module);

  @override
  int get id => 9;

  @override
  bool get isNotEmpty =>
      module.tables.any((table) => table.elements.any((e) => e != null));

  @override
  void serializeContents() {
    List<_Element> elements = [];
    for (Table table in module.tables) {
      _Element? current = null;
      for (int i = 0; i < table.elements.length; i++) {
        BaseFunction? function = table.elements[i];
        if (function != null) {
          if (current == null) {
            current = _Element(table, i);
            elements.add(current);
          }
          current.entries.add(function);
        } else {
          current = null;
        }
      }
    }
    writeList(elements);
  }
}

class CodeSection extends Section {
  CodeSection(Module module) : super(module);

  @override
  int get id => 10;

  @override
  bool get isNotEmpty =>
      module.functions.whereType<DefinedFunction>().isNotEmpty;

  @override
  void serializeContents() {
    writeList(module.functions.whereType<DefinedFunction>().toList());
  }
}

class DataSection extends Section {
  DataSection(Module module) : super(module);

  @override
  int get id => 11;

  @override
  bool get isNotEmpty =>
      module.memories.any((memory) => memory.data.isNotEmpty);

  @override
  void serializeContents() {
    int length = module.memories.fold(0, (a, m) => a + m.data.length);
    writeUnsigned(length);
    for (Memory memory in module.memories) {
      for (Data data in memory.data) {
        writeUnsigned(memory.index);
        writeByte(0x41); // i32.const
        writeSigned(data.offset);
        writeByte(0x0B); // end
        writeUnsigned(data.init.length);
        writeBytes(data.init);
      }
    }
  }
}
