// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of wasm_builder.module;

abstract class StorageType implements Serializable {
  bool isSubtypeOf(StorageType other);
}

abstract class ValueType implements StorageType {
  const ValueType();
}

enum NumTypeKind { i32, i64, f32, f64, v128 }

class NumType extends ValueType {
  final NumTypeKind kind;

  const NumType._(this.kind);

  static const i32 = NumType._(NumTypeKind.i32);
  static const i64 = NumType._(NumTypeKind.i64);
  static const f32 = NumType._(NumTypeKind.f32);
  static const f64 = NumType._(NumTypeKind.f64);
  static const v128 = NumType._(NumTypeKind.v128);

  @override
  bool isSubtypeOf(StorageType other) => this == other;

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

class Rtt extends ValueType {
  final HeapType heapType;
  final int depth;

  const Rtt(this.heapType, this.depth);

  @override
  bool isSubtypeOf(StorageType other) => this == other;

  @override
  void serialize(Serializer s) {
    s.writeByte(0x69);
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

class RefType extends ValueType {
  final HeapType heapType;
  final bool nullable;

  RefType._(this.heapType, bool? nullable)
      : this.nullable = nullable ??
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
  bool isSubtypeOf(StorageType other) {
    if (other is! RefType) return false;
    if (!nullable && other.nullable) return false;
    return heapType.isSubtypeOf(other.heapType);
  }

  @override
  void serialize(Serializer s) {
    if (nullable != heapType.defaultNullability) {
      s.writeByte(nullable ? 0x6C : 0x6B);
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
  void serialize(Serializer s) => s.writeByte(0x6E);

  @override
  String toString() => "any";
}

class EqHeapType extends HeapType {
  const EqHeapType._();

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.eq;

  @override
  void serialize(Serializer s) => s.writeByte(0x6D);

  @override
  String toString() => "eq";
}

class I31HeapType extends HeapType {
  const I31HeapType._();

  @override
  bool? get defaultNullability => false;

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.eq || other == HeapType.i31;

  @override
  void serialize(Serializer s) => s.writeByte(0x6A);

  @override
  String toString() => "i31";
}

class FuncHeapType extends HeapType {
  const FuncHeapType._();

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.func;

  @override
  void serialize(Serializer s) => s.writeByte(0x70);

  @override
  String toString() => "func";
}

class ExternHeapType extends HeapType {
  const ExternHeapType._();

  @override
  bool isSubtypeOf(HeapType other) =>
      other == HeapType.any || other == HeapType.extern;

  @override
  void serialize(Serializer s) => s.writeByte(0x6F);

  @override
  String toString() => "extern";
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

abstract class DefType implements Serializable {
  int index;

  DefType._(this.index);

  bool isSubtypeOf(DefType other);
}

class FunctionType extends DefType {
  final List<ValueType> inputs;
  final List<ValueType> outputs;

  FunctionType._(int index, this.inputs, this.outputs) : super._(index);

  @override
  bool isSubtypeOf(DefType other) {
    if (other is! FunctionType) return false;
    if (inputs.length != other.inputs.length) return false;
    if (outputs.length != other.outputs.length) return false;
    for (int i = 0; i < inputs.length; i++) {
      // Inputs are contravariant.
      if (!other.inputs[i].isSubtypeOf(inputs[i])) return false;
    }
    for (int i = 0; i < outputs.length; i++) {
      // Outputs are covariant.
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

  @override
  bool isSubtypeOf(DefType other) {
    if (other is! StructType) return false;
    if (fields.length < other.fields.length) return false;
    for (int i = 0; i < other.fields.length; i++) {
      if (!fields[i].isSubtypeOf(other.fields[i])) return false;
    }
    return true;
  }

  @override
  void serialize(Serializer s) {
    s.writeByte(0x5F);
    s.writeList(fields);
  }

  @override
  String toString() => name;
}

class ArrayType extends DefType {
  final String name;
  late final FieldType elementType;

  ArrayType._(int index, this.name) : super._(index);

  @override
  bool isSubtypeOf(DefType other) =>
      other is ArrayType && elementType.isSubtypeOf(other.elementType);

  @override
  void serialize(Serializer s) {
    s.writeByte(0x5E);
    s.write(elementType);
  }

  @override
  String toString() => name;
}

class FieldType implements Serializable {
  final StorageType type;
  final bool mutable;

  FieldType(this.type, {this.mutable = true});

  FieldType.i8({bool mutable: true}) : this(PackedType.i8, mutable: mutable);
  FieldType.i16({bool mutable: true}) : this(PackedType.i16, mutable: mutable);

  bool isSubtypeOf(FieldType other) {
    if (mutable != other.mutable) return false;
    if (mutable) {
      // Mutable fields are invariant.
      return type == other.type;
    } else {
      // Immutable fields are covariant.
      return type.isSubtypeOf(other.type);
    }
  }

  @override
  void serialize(Serializer s) {
    s.write(type);
    s.writeByte(mutable ? 0x01 : 0x00);
  }

  @override
  String toString() => "${mutable ? "var " : "const "}$type";
}

enum PackedTypeKind { i8, i16 }

class PackedType implements StorageType {
  final PackedTypeKind kind;

  const PackedType._(this.kind);

  static const i8 = PackedType._(PackedTypeKind.i8);
  static const i16 = PackedType._(PackedTypeKind.i16);

  @override
  bool isSubtypeOf(StorageType other) => this == other;

  @override
  void serialize(Serializer s) {
    switch (kind) {
      case PackedTypeKind.i8:
        s.writeByte(0x7A);
        break;
      case PackedTypeKind.i16:
        s.writeByte(0x79);
        break;
    }
  }

  @override
  String toString() {
    switch (kind) {
      case PackedTypeKind.i8:
        return "i8";
      case PackedTypeKind.i16:
        return "i16";
    }
  }
}
