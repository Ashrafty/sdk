// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class ClassInfo {
  w.StructType struct;
  w.ValueType repr;
  bool initialized = false;

  ClassInfo(this.struct, this.repr);
}

class ClassInfoCollector {
  Translator translator;
  w.Module m;

  ClassInfoCollector(this.translator) : m = translator.m;

  void generateFields(Class cls) {
    ClassInfo info = translator.classes[cls]!;
    if (!info.initialized) {
      Class? superclass = cls.superclass;
      if (superclass == null) {
        // Object - add class id field
        info.struct.fields.add(w.FieldType(w.NumType.i32));
      } else {
        generateFields(superclass);
        ClassInfo superInfo = translator.classes[superclass]!;
        for (w.FieldType fieldType in superInfo.struct.fields) {
          info.struct.fields.add(fieldType);
        }
      }
      for (Field field in cls.fields) {
        DartType fieldType = field.type;
        if (fieldType is! InterfaceType) {
          throw "Only interface types supported for fields";
        }
        w.ValueType wasmType = translator.translateType(fieldType);
        translator.fieldIndex[field] = info.struct.fields.length;
        info.struct.fields.add(w.FieldType(wasmType));
      }
      info.initialized = true;
    }
  }

  void collect() {
    for (Library library in translator.component.libraries) {
      for (Class cls in library.classes) {
        w.StructType structType = m.addStructType(cls.name);
        // TODO: Have less precise representation type to enable interfaces
        w.ValueType reprType = w.RefType.def(structType, nullable: true);
        translator.classes[cls] = ClassInfo(structType, reprType);
      }
    }

    for (Library library in translator.libraries) {
      for (Class cls in library.classes) {
        generateFields(cls);
      }
    }
  }
}
