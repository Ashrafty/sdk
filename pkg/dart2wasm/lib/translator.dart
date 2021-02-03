// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/analyzer.dart';
import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/functions.dart';
import 'package:dart2wasm/intrinsics.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart'
    show ClassHierarchy, ClassHierarchySubtypes, ClosedWorldClassHierarchy;
import 'package:kernel/core_types.dart';
import 'package:kernel/type_environment.dart';
import 'package:vm/transformations/type_flow/table_selector_assigner.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class Translator {
  Component component;
  List<Library> libraries;
  CoreTypes coreTypes;
  TypeEnvironment typeEnvironment;
  TableSelectorAssigner tableSelectorAssigner;
  ClosedWorldClassHierarchy hierarchy;
  late ClassHierarchySubtypes subtypes;

  late Intrinsics intrinsics;
  late DispatchTable dispatchTable;

  List<ClassInfo> classes = [];
  Map<Class, ClassInfo> classInfo = {};
  Map<Field, int> fieldIndex = {};
  Map<Member, w.BaseFunction> functions = {};
  late Procedure mainFunction;
  late w.Module m;

  Translator(this.component, this.coreTypes, this.typeEnvironment,
      this.tableSelectorAssigner)
      : libraries = [component.libraries.first],
        hierarchy =
            ClassHierarchy(component, coreTypes) as ClosedWorldClassHierarchy {
    subtypes = hierarchy.computeSubtypesInformation();
    intrinsics = Intrinsics(this);
    dispatchTable = DispatchTable(this);
  }

  w.Module translate() {
    m = w.Module();

    ClassInfoCollector(this).collect();

    w.FunctionType printType = m.addFunctionType([w.NumType.i64], []);
    w.ImportedFunction printFun = m.importFunction("console", "log", printType);
    for (Procedure printMember in component.libraries
        .firstWhere((l) => l.name == "dart.core")
        .procedures
        .where((p) => p.name.name == "print")) {
      functions[printMember] = printFun;
    }

    dispatchTable.build();
    FunctionCollector(this).collect();
    dispatchTable.output();

    //mainFunction =
    //    libraries.first.procedures.firstWhere((p) => p.name.name == "main");
    //w.DefinedFunction mainFun = functions[mainFunction] as w.DefinedFunction;
    //m.exportFunction("main", mainFun);

    Analyzer(this).visitComponent(component);
    var codeGen = CodeGenerator(this);
    for (Member member in functions.keys) {
      w.BaseFunction function = functions[member]!;
      if (function is w.DefinedFunction) {
        //print("#${function.index}: $member");
        //print(member.function.body);
        m.exportFunction(member.toString(), function);
        codeGen.generate(member, function);
        //print(function.body.trace);
      }
    }

    return m;
  }

  w.ValueType translateType(DartType type) {
    assert(type is! VoidType);
    if (type is InterfaceType) {
      if (type.classNode == coreTypes.intClass) {
        if (!type.isPotentiallyNullable) {
          return w.NumType.i64;
        }
      }
      if (type.classNode == coreTypes.doubleClass) {
        if (!type.isPotentiallyNullable) {
          return w.NumType.f64;
        }
      }
      if (type.classNode == coreTypes.boolClass) {
        if (!type.isPotentiallyNullable) {
          return w.NumType.i32;
        }
      }
      return classInfo[type.classNode]!.repr;
    }
    if (type is DynamicType) {
      return translateType(coreTypes.objectNullableRawType);
    }
    if (type is TypeParameterType) {
      return translateType(type.bound);
    }
    if (type is FutureOrType) {
      return translateType(coreTypes.objectNullableRawType);
    }
    if (type is FunctionType) {
      // TODO
      return w.RefType.any();
    }
    throw "Unsupported type ${type.runtimeType}";
  }
}
