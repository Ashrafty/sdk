// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/analyzer.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class Translator {
  Component component;
  Map<Member, w.BaseFunction> functions = {};
  late Procedure mainFunction;
  late w.Module m;

  Translator(this.component);

  w.Module translate() {
    m = w.Module();

    w.FunctionType printType = m.addFunctionType([w.NumType.i64], []);
    w.ImportedFunction printFun = m.importFunction("console", "log", printType);
    Procedure printMember = component.libraries
        .firstWhere((l) => l.name == "dart.core")
        .procedures
        .firstWhere((p) => p.name.name == "print");
    functions[printMember] = printFun;

    w.FunctionType mainType = m.addFunctionType([], []);
    w.DefinedFunction mainFun = m.addFunction(mainType);
    m.exportFunction("main", mainFun);
    Procedure mainMember = component.libraries.first.procedures
        .firstWhere((p) => p.name.name == "main");
    functions[mainMember] = mainFun;
    mainFunction = mainMember;

    Analyzer(this).visitComponent(component);
    var codeGen = CodeGenerator(this);
    for (Member member in functions.keys) {
      w.BaseFunction function = functions[member]!;
      if (function is w.DefinedFunction) {
        print(member.function.body);
        codeGen.generate(member, function);
      }
    }

    return m;
  }
}
