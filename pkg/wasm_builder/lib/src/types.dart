// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of wasm_builder.module;

abstract class ValueType implements Serializable {
  const ValueType();

  bool isSubtypeOf(ValueType other);
}

enum NumTypeKind { i32, i64, f32, f64, v128 }

class NumType extends ValueType {
  final NumTypeKind kind;

  const NumType._of(this.kind);

  static const i32 = NumType._of(NumTypeKind.i32);
  static const i64 = NumType._of(NumTypeKind.i64);
  static const f32 = NumType._of(NumTypeKind.f32);
  static const f64 = NumType._of(NumTypeKind.f64);
  static const v128 = NumType._of(NumTypeKind.v128);

  @override
  bool isSubtypeOf(ValueType other) => this == other;

  @override
  void serialize(Serializer s) {
    switch (kind) {
      case NumTypeKind.i32:
        s.writeByte(0x7F);
        break;
      case NumTypeKind.i64:
        s.writeByte(0x7E);
        break;
      case NumTypeKind.f32:
        s.writeByte(0x7D);
        break;
      case NumTypeKind.f64:
        s.writeByte(0x7C);
        break;
      case NumTypeKind.v128:
        s.writeByte(0x7B);
        break;
    }
  }

  @override
  String toString() {
    switch (kind) {
      case NumTypeKind.i32:
        return "i32";
      case NumTypeKind.i64:
        return "i64";
      case NumTypeKind.f32:
        return "f32";
      case NumTypeKind.f64:
        return "f64";
      case NumTypeKind.v128:
        return "v128";
    }
  }
}

abstract class HeapType implements Serializable {
  const HeapType();

  static const any = AnyHeapType._();
  static const eq = EqHeapType._();
  static const i31 = I31HeapType._();
  static const func = FuncHeapType._();
  static const extern = ExternHeapType._();
  static DefHeapType def(DefType defType) => DefHeapType._(defType);

  bool? get defaultNullability => true;

  bool isSubtypeOf(HeapType other);
}

class AnyHeapType extends HeapType {
  const AnyHeapType._();

  @override
  bool isSubtypeOf(HeapType other) => other == HeapType.any;

  @override
  void serialize(Serializer s) => s.writeSigned(-0x12);

  @override
  String toString() => "any";
}

class EqHeapType extends HeapType {
  const EqHeapType._();

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.eq;

  @override
  void serialize(Serializer s) => s.writeSigned(-0x13);

  @override
  String toString() => "eq";
}

class DefHeapType extends HeapType {
  final DefType def;

  DefHeapType._(this.def);

  @override
  bool? get defaultNullability => null;

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any ||
      other == HeapType.eq ||
      other is DefHeapType && def.isSubtypeOf(other.def);

  @override
  void serialize(Serializer s) => s.writeSigned(def.index);

  @override
  bool operator ==(Object other) => other is DefHeapType && other.def == def;

  @override
  int get hashCode => def.hashCode;

  @override
  String toString() => def.toString();
}

class I31HeapType extends HeapType {
  const I31HeapType._();

  @override
  bool? get defaultNullability => false;

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.eq || other == HeapType.i31;

  @override
  void serialize(Serializer s) => s.writeSigned(-0x16);

  @override
  String toString() => "i31";
}

class FuncHeapType extends HeapType {
  const FuncHeapType._();

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.func;

  @override
  void serialize(Serializer s) => s.writeSigned(-0x10);

  @override
  String toString() => "func";
}

class ExternHeapType extends HeapType {
  const ExternHeapType._();

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.extern;

  @override
  void serialize(Serializer s) => s.writeSigned(-0x11);

  @override
  String toString() => "extern";
}

class RefType extends ValueType {
  final HeapType heapType;
  final bool nullable;

  RefType._(this.heapType, bool? nullable)
      : nullable = nullable ??
            heapType.defaultNullability ??
            (throw "Unspecified nullability");

  RefType.any({bool? nullable}) : this._(HeapType.any, nullable);
  RefType.eq({bool? nullable}) : this._(HeapType.eq, nullable);
  RefType.i31({bool? nullable}) : this._(HeapType.i31, nullable);
  RefType.func({bool? nullable}) : this._(HeapType.func, nullable);
  RefType.extern({bool? nullable}) : this._(HeapType.extern, nullable);
  RefType.def(DefType defType, {required bool nullable})
      : this._(HeapType.def(defType), nullable);

  @override
  bool isSubtypeOf(ValueType other) {
    if (other is! RefType) return false;
    if (!nullable && other.nullable) return false;
    return heapType.isSubtypeOf(other.heapType);
  }

  @override
  void serialize(Serializer s) {
    if (nullable != heapType.defaultNullability) {
      s.writeSigned(nullable ? -0x14 : -0x15);
    }
    s.write(heapType);
  }

  @override
  String toString() {
    if (nullable == heapType.defaultNullability) return "${heapType}ref";
    return "ref${nullable ? " null " : " "}${heapType}";
  }

  @override
  bool operator ==(Object other) =>
      other is RefType &&
      other.heapType == heapType &&
      other.nullable == nullable;

  @override
  int get hashCode => heapType.hashCode * (nullable ? -1 : 1);
}

class Rtt extends ValueType {
  final HeapType heapType;
  final int depth;

  Rtt(this.heapType, this.depth);

  @override
  bool isSubtypeOf(ValueType other) => this == other;

  @override
  void serialize(Serializer s) {
    s.writeSigned(-0x17);
    s.writeUnsigned(depth);
    s.write(heapType);
  }

  @override
  String toString() => "rtt $depth $heapType";

  @override
  bool operator ==(Object other) =>
      other is Rtt && other.heapType == heapType && other.depth == depth;

  @override
  int get hashCode => heapType.hashCode * (3 + depth * 2);
}

abstract class DefType implements Serializable {
  int index;

  DefType._(this.index);

  bool isSubtypeOf(DefType other);
}

class FunctionType extends DefType {
  final List<ValueType> inputs;
  final List<ValueType> outputs;

  FunctionType._(int index, this.inputs, this.outputs) : super._(index);

  bool isSubtypeOf(DefType other) {
    if (other is! FunctionType) return false;
    if (inputs.length != other.inputs.length) return false;
    if (outputs.length != other.outputs.length) return false;
    for (int i = 0; i < inputs.length; i++) {
      if (!other.inputs[i].isSubtypeOf(inputs[i])) return false;
    }
    for (int i = 0; i < outputs.length; i++) {
      if (!outputs[i].isSubtypeOf(other.outputs[i])) return false;
    }
    return true;
  }

  @override
  void serialize(Serializer s) {
    s.writeByte(0x60);
    s.writeList(inputs);
    s.writeList(outputs);
  }

  @override
  String toString() => "(${inputs.join(", ")}) -> (${outputs.join(", ")})";
}

class StructType extends DefType {
  final String name;
  final List<FieldType> fields = [];

  StructType._(int index, this.name) : super._(index);

  bool isSubtypeOf(DefType other) {
    if (other is! StructType) return false;
    if (fields.length < other.fields.length) return false;
    for (int i = 0; i < other.fields.length; i++) {
      if (fields[i] != other.fields[i]) return false;
    }
    return true;
  }

  @override
  void serialize(Serializer s) {
    s.writeByte(0x5E);
    s.writeList(fields);
  }

  @override
  String toString() => name;
}

class ArrayType extends DefType {
  final String name;
  late final FieldType elementType;

  ArrayType._(int index, this.name) : super._(index);

  bool isSubtypeOf(DefType other) =>
      other is ArrayType && elementType == other.elementType;

  @override
  void serialize(Serializer s) {
    s.writeByte(0x5E);
    s.write(elementType);
  }

  @override
  String toString() => name;
}

abstract class FieldType implements Serializable {
  bool mutable;

  FieldType._(this.mutable);

  factory FieldType.i8({bool mutable: true}) =>
      PackedFieldType._(PackedType.i8, mutable);
  factory FieldType.i16({bool mutable: true}) =>
      PackedFieldType._(PackedType.i8, mutable);
  factory FieldType(ValueType valueType, {bool mutable: true}) =>
      ValueFieldType._(valueType, mutable);

  String toString() => "${_toStringInner()}${mutable ? " mut" : ""}";
  String _toStringInner();
}

enum PackedType { i8, i16 }

class PackedFieldType extends FieldType {
  PackedType packedType;

  PackedFieldType._(this.packedType, bool mutable) : super._(mutable);

  @override
  void serialize(Serializer s) {
    switch (packedType) {
      case PackedType.i8:
        s.writeByte(0x7A);
        break;
      case PackedType.i16:
        s.writeByte(0x79);
        break;
    }
    s.writeByte(mutable ? 0x01 : 0x00);
  }

  @override
  String _toStringInner() {
    switch (packedType) {
      case PackedType.i8:
        return "i8";
      case PackedType.i16:
        return "i16";
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PackedFieldType && other.packedType == packedType;

  @override
  int get hashCode => packedType.hashCode;
}

class ValueFieldType extends FieldType {
  ValueType valueType;

  ValueFieldType._(this.valueType, bool mutable) : super._(mutable);

  @override
  void serialize(Serializer s) {
    s.write(valueType);
    s.writeByte(mutable ? 0x01 : 0x00);
  }

  @override
  String _toStringInner() => valueType.toString();

  @override
  bool operator ==(Object other) =>
      other is ValueFieldType && other.valueType == valueType;

  @override
  int get hashCode => valueType.hashCode;
}
