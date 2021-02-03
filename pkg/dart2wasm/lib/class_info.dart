// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math';

import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class ClassInfo {
  Class cls;
  int classId;
  int depth;
  w.StructType struct;
  w.DefinedGlobal rtt;
  ClassInfo? superInfo;
  late w.ValueType repr;
  List<ClassInfo> implementedBy = [];

  ClassInfo(this.cls, this.classId, this.depth, this.struct, this.rtt) {
    implementedBy.add(this);
  }
}

ClassInfo upperBound(Iterable<ClassInfo> classes) {
  while (classes.length > 1) {
    Set<ClassInfo> newClasses = {};
    int minDepth = 999999999;
    int maxDepth = 0;
    for (ClassInfo info in classes) {
      minDepth = min(minDepth, info.depth);
      maxDepth = max(maxDepth, info.depth);
    }
    int targetDepth = minDepth == maxDepth ? minDepth - 1 : minDepth;
    for (ClassInfo info in classes) {
      while (info.depth > targetDepth) {
        info = info.superInfo!;
      }
      newClasses.add(info);
    }
    classes = newClasses;
  }
  return classes.single;
}

class ClassInfoCollector {
  Translator translator;
  w.Module m;
  int nextClassId = 0;

  ClassInfoCollector(this.translator) : m = translator.m;

  void initialize(Class cls) {
    ClassInfo? info = translator.classInfo[cls];
    if (info == null) {
      Class? superclass = cls.superclass;
      if (superclass == null) {
        const int depth = 0;
        final w.StructType struct = m.addStructType(cls.name);
        final w.DefinedGlobal rtt =
            m.addGlobal(w.GlobalType(w.Rtt(struct, depth), mutable: false));
        final w.Instructions b = rtt.initializer;
        b.rtt_canon(struct);
        b.end();
        info = ClassInfo(cls, nextClassId++, depth, struct, rtt);
      } else {
        initialize(superclass);
        for (Supertype interface in cls.implementedTypes) {
          initialize(interface.classNode);
        }
        ClassInfo superInfo = translator.classInfo[superclass]!;
        final int depth = superInfo.depth + 1;
        w.StructType struct =
            cls.fields.where((f) => f.isInstanceMember).isEmpty
                ? superInfo.struct
                : m.addStructType(cls.name);
        final w.DefinedGlobal rtt =
            m.addGlobal(w.GlobalType(w.Rtt(struct, depth), mutable: false));
        w.Instructions b = rtt.initializer;
        b.global_get(superInfo.rtt);
        b.rtt_sub(struct);
        b.end();
        info = ClassInfo(cls, nextClassId++, depth, struct, rtt);
        info.superInfo = superInfo;
        for (Supertype interface in cls.implementedTypes) {
          translator.classInfo[interface.classNode]!.implementedBy.add(info);
        }
      }
      translator.classes.add(info);
      translator.classInfo[cls] = info;
    }
  }

  void computeRepresentation(ClassInfo info) {
    ClassInfo upper = upperBound(info.implementedBy);
    info.repr = w.RefType.def(upper.struct, nullable: true);
  }

  void generateFields(ClassInfo info) {
    ClassInfo? superInfo = info.superInfo;
    if (superInfo == null) {
      // Object - add class id field
      info.struct.fields.add(w.FieldType(w.NumType.i32));
    } else if (info.struct != superInfo.struct) {
      // Copy fields from superclass
      for (w.FieldType fieldType in superInfo.struct.fields) {
        info.struct.fields.add(fieldType);
      }
    }
    for (Field field in info.cls.fields) {
      if (field.isInstanceMember) {
        w.ValueType wasmType = translator.translateType(field.type);
        translator.fieldIndex[field] = info.struct.fields.length;
        info.struct.fields.add(w.FieldType(wasmType));
      }
    }
  }

  void collect() {
    for (Library library in translator.component.libraries) {
      for (Class cls in library.classes) {
        initialize(cls);
      }
    }

    for (ClassInfo info in translator.classes) {
      computeRepresentation(info);
    }

    for (ClassInfo info in translator.classes) {
      generateFields(info);
    }
  }
}
