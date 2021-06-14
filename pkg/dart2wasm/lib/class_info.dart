// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math';

import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

const int initialIdentityHash = 0;

class ClassInfo {
  Class? cls;
  int classId;
  int depth;
  w.StructType struct;
  w.DefinedGlobal rtt;
  ClassInfo? superInfo;
  Map<TypeParameter, TypeParameter> typeParameterMatch = {};
  late ClassInfo repr;
  List<ClassInfo> implementedBy = [];

  late w.RefType nullableType = w.RefType.def(struct, nullable: true);
  late w.RefType nonNullableType = w.RefType.def(struct, nullable: false);

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
  late ClassInfo topInfo;

  ClassInfoCollector(this.translator) : m = translator.m;

  static w.DefinedGlobal makeRtt(
      w.Module m, w.StructType struct, ClassInfo? superInfo) {
    int depth = superInfo != null ? superInfo.depth + 1 : 0;
    final w.DefinedGlobal rtt =
        m.addGlobal(w.GlobalType(w.Rtt(struct, depth), mutable: false));
    final w.Instructions b = rtt.initializer;
    if (superInfo != null) {
      b.global_get(superInfo.rtt);
      b.rtt_sub(struct);
    } else {
      b.rtt_canon(struct);
    }
    b.end();
    return rtt;
  }

  void initializeTop() {
    final w.StructType struct = m.addStructType("#Top");
    final w.DefinedGlobal rtt = makeRtt(m, struct, null);
    topInfo = ClassInfo(null, nextClassId++, 0, struct, rtt);
    translator.classes.add(topInfo);
    translator.classForHeapType[w.HeapType.def(struct)] = topInfo;
  }

  void initialize(Class cls) {
    ClassInfo? info = translator.classInfo[cls];
    if (info == null) {
      Class? superclass = cls.superclass;
      if (superclass == null) {
        ClassInfo superInfo = topInfo;
        final w.StructType struct = m.addStructType(cls.name);
        final w.DefinedGlobal rtt = makeRtt(m, struct, superInfo);
        info = ClassInfo(cls, nextClassId++, superInfo.depth + 1, struct, rtt)
          ..superInfo = superInfo;
        // Mark Top type as implementing Object to force the representation
        // type of Object to be Top.
        info.implementedBy.add(topInfo);
      } else {
        initialize(superclass);
        for (Supertype interface in cls.implementedTypes) {
          initialize(interface.classNode);
        }
        // In the Wasm type hierarchy, Object, bool and num sit directly below
        // the Top type. The implementation classes (_StringBase, _Type and the
        // box classes) sit directly below the public classes they implement.
        // All other classes sit below their superclass.
        ClassInfo superInfo = cls == translator.coreTypes.boolClass ||
                cls == translator.coreTypes.numClass
            ? topInfo
            : cls == translator.stringBaseClass ||
                    cls == translator.typeClass ||
                    translator.boxedClasses.values.contains(cls)
                ? translator.classInfo[cls.implementedTypes.single.classNode]!
                : translator.classInfo[superclass]!;
        Map<TypeParameter, TypeParameter> typeParameterMatch = {};
        if (cls.typeParameters.isNotEmpty) {
          Supertype supertype = cls.superclass == superInfo.cls
              ? cls.supertype!
              : cls.implementedTypes.single;
          for (TypeParameter parameter in cls.typeParameters) {
            for (int i = 0; i < supertype.typeArguments.length; i++) {
              DartType arg = supertype.typeArguments[i];
              if (arg is TypeParameterType && arg.parameter == parameter) {
                typeParameterMatch[parameter] =
                    superInfo.cls!.typeParameters[i];
                break;
              }
            }
          }
        }
        bool canReuseSuperStruct =
            typeParameterMatch.length == cls.typeParameters.length &&
                cls.fields.where((f) => f.isInstanceMember).isEmpty;
        w.StructType struct =
            canReuseSuperStruct ? superInfo.struct : m.addStructType(cls.name);
        final w.DefinedGlobal rtt = makeRtt(m, struct, superInfo);
        info = ClassInfo(cls, nextClassId++, superInfo.depth + 1, struct, rtt)
          ..superInfo = superInfo
          ..typeParameterMatch = typeParameterMatch;
        for (Supertype interface in cls.implementedTypes) {
          translator.classInfo[interface.classNode]!.implementedBy.add(info);
        }
      }
      translator.classes.add(info);
      translator.classInfo[cls] = info;
      translator.classForHeapType
          .putIfAbsent(w.HeapType.def(info.struct), () => info!);
    }
  }

  void computeRepresentation(ClassInfo info) {
    info.repr = upperBound(info.implementedBy);
  }

  void generateFields(ClassInfo info) {
    ClassInfo? superInfo = info.superInfo;
    if (superInfo == null) {
      // Top - add class id field
      info.struct.fields.add(w.FieldType(w.NumType.i32));
    } else if (info.struct != superInfo.struct) {
      // Copy fields from superclass
      for (w.FieldType fieldType in superInfo.struct.fields) {
        info.struct.fields.add(fieldType);
      }
      if (info.cls!.superclass == null) {
        // Object - add identity hash code field
        info.struct.fields.add(w.FieldType(w.NumType.i32));
      }
      // Add fields for type variables
      late w.FieldType typeType =
          w.FieldType(translator.classInfo[translator.typeClass]!.nullableType);
      for (TypeParameter parameter in info.cls!.typeParameters) {
        TypeParameter? match = info.typeParameterMatch[parameter];
        if (match != null) {
          // Reuse supertype type variable
          translator.typeParameterIndex[parameter] =
              translator.typeParameterIndex[match]!;
        } else {
          translator.typeParameterIndex[parameter] = info.struct.fields.length;
          info.struct.fields.add(typeType);
        }
      }
      // Add fields for Dart instance fields
      for (Field field in info.cls!.fields) {
        if (field.isInstanceMember) {
          w.ValueType wasmType = translator.translateType(field.type);
          // TODO: Generalize this check for finer control
          if (wasmType != w.RefType.data()) {
            wasmType = wasmType.withNullability(true);
          }
          translator.fieldIndex[field] = info.struct.fields.length;
          info.struct.fields.add(w.FieldType(wasmType));
        }
      }
    } else {
      for (TypeParameter parameter in info.cls!.typeParameters) {
        // Reuse supertype type variable
        translator.typeParameterIndex[parameter] =
            translator.typeParameterIndex[info.typeParameterMatch[parameter]]!;
      }
    }
  }

  void collect() {
    initializeTop();
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
