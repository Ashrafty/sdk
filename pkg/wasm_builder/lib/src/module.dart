// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library wasm_builder.module;

import 'serialize.dart';

part 'types.dart';

class Module {
  Map<_FunctionTypeKey, FunctionType> functionTypeMap = {};

  List<DefType> defTypes = [];

  FunctionType makeFunctionType(
      Iterable<ValueType> inputs, Iterable<ValueType> outputs) {
    List<ValueType> inputList = List.unmodifiable(inputs);
    List<ValueType> outputList = List.unmodifiable(outputs);
    _FunctionTypeKey key = _FunctionTypeKey(inputList, outputList);
    return functionTypeMap.putIfAbsent(key, () {
      var type = FunctionType._(defTypes.length, inputList, outputList);
      defTypes.add(type);
      return type;
    });
  }

  StructType makeStructType(String name, [Iterable<FieldType>? fieldTypes]) {
    var type = StructType._(defTypes.length, name);
    if (fieldTypes != null) {
      for (var fieldType in fieldTypes) type.fields.add(fieldType);
    }
    defTypes.add(type);
    return type;
  }

  ArrayType makeArrayType(String name, [FieldType? elementType]) {
    var type = ArrayType._(defTypes.length, name);
    if (elementType != null) type.elementType = elementType;
    defTypes.add(type);
    return type;
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
