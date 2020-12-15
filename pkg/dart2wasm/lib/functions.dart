// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class FunctionCollector extends MemberVisitor<void> {
  Translator translator;
  w.Module m;

  FunctionCollector(this.translator) : m = translator.m;

  void collect() {
    for (Library library in translator.libraries) {
      for (Member member in library.members) {
        member.accept(this);
      }
      for (Class cls in library.classes) {
        for (Member member in cls.members) {
          member.accept(this);
        }
      }
    }
  }

  void visitProcedure(Procedure node) {
    if (!node.isAbstract) {
      _makeFunction(node, node.function.returnType, node.isInstanceMember);
    }
  }

  void visitConstructor(Constructor node) {
    _makeFunction(node, VoidType(), true);
  }

  void _makeFunction(
      Member member, DartType returnType, bool receiverParameter) {
    if (translator.functions.containsKey(member)) return;

    FunctionNode function = member.function;
    if (function.namedParameters.isNotEmpty ||
        function.requiredParameterCount <
            function.positionalParameters.length) {
      throw "Optional parameters not supported";
    }

    List<w.ValueType> inputs = [];
    if (receiverParameter) {
      DartType receiverType =
          InterfaceType(member.enclosingClass!, Nullability.nonNullable);
      inputs.add(translator.translateType(receiverType));
    }
    inputs.addAll(function.positionalParameters
        .map((p) => translator.translateType(p.type)));

    List<w.ValueType> outputs = returnType is VoidType
        ? const []
        : [translator.translateType(returnType)];

    w.FunctionType functionType = m.addFunctionType(inputs, outputs);
    translator.functions[member] = m.addFunction(functionType);
  }
}
