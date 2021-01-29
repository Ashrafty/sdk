// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class ClassInfo {
  Class cls;
  w.StructType struct;
  w.ValueType repr;
  late int depth;
  late w.DefinedGlobal rtt;
  late int classId;
  bool initialized = false;

  ClassInfo(this.cls, this.struct, this.repr);
}

class ClassInfoCollector {
  Translator translator;
  w.Module m;
  int nextClassId = 0;

  ClassInfoCollector(this.translator) : m = translator.m;

  void generateFields(Class cls) {
    ClassInfo info = translator.classInfo[cls]!;
    if (!info.initialized) {
      Class? superclass = cls.superclass;
      if (superclass == null) {
        // Object - add class id field
        info.struct.fields.add(w.FieldType(w.NumType.i32));

        info.depth = 0;
        info.rtt = m.addGlobal(
            w.GlobalType(w.Rtt(info.struct, info.depth), mutable: false));
        w.Instructions b = info.rtt.initializer;
        b.rtt_canon(info.struct);
        b.end();
      } else {
        generateFields(superclass);
        ClassInfo superInfo = translator.classInfo[superclass]!;
        for (w.FieldType fieldType in superInfo.struct.fields) {
          info.struct.fields.add(fieldType);
        }

        info.depth = superInfo.depth + 1;
        info.rtt = m.addGlobal(
            w.GlobalType(w.Rtt(info.struct, info.depth), mutable: false));
        w.Instructions b = info.rtt.initializer;
        b.global_get(superInfo.rtt);
        b.rtt_sub(info.struct);
        b.end();
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

      info.classId = nextClassId++;
      info.initialized = true;
      translator.classes.add(info);
    }
  }

  void collect() {
    for (Library library in translator.component.libraries) {
      for (Class cls in library.classes) {
        w.StructType structType = m.addStructType(cls.name);
        // TODO: Have less precise representation type to enable interfaces
        w.ValueType reprType = w.RefType.def(structType, nullable: true);
        translator.classInfo[cls] = ClassInfo(cls, structType, reprType);
      }
    }

    for (Library library in translator.libraries) {
      for (Class cls in library.classes) {
        generateFields(cls);
      }
    }
  }
}
