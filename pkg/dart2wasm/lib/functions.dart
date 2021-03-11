// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
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

  void defaultMember(Member node) {}

  void visitField(Field node) {
    if (node.isInstanceMember) {
      translator.functions[node.getterReference] = m.addFunction(translator
          .dispatchTable
          .selectorForTarget(node.getterReference)
          .signature);
      if (node.hasSetter) {
        translator.functions[node.setterReference!] = m.addFunction(translator
            .dispatchTable
            .selectorForTarget(node.setterReference!)
            .signature);
      }
    }
  }

  void visitProcedure(Procedure node) {
    if (!node.isAbstract && !node.isExternal) {
      if (node.isInstanceMember) {
        translator.functions[node.reference] = m.addFunction(translator
            .dispatchTable
            .selectorForTarget(node.reference)
            .signature);
      } else {
        _makeFunction(node.reference, node.function!.returnType, null,
            getter: node.isGetter);
      }
    }
  }

  void visitConstructor(Constructor node) {
    _makeFunction(node.reference, VoidType(),
        InterfaceType(node.enclosingClass, Nullability.nonNullable),
        getter: false);
  }

  void _makeFunction(
      Reference target, DartType returnType, DartType? receiverType,
      {required bool getter}) {
    if (translator.functions.containsKey(target)) return;

    Member member = target.asMember;
    Iterable<DartType> params;
    if (member is Field) {
      params = [if (target.isImplicitSetter) member.setterType];
    } else {
      FunctionNode function = member.function!;
      // TODO: Support optional parameters
      params = function.positionalParameters.map((p) => p.type);
    }

    List<w.ValueType> inputs = [];
    if (receiverType != null) {
      inputs.add(translator.translateType(receiverType));
    }
    inputs.addAll(params.map((t) => translator.translateType(t)));

    List<w.ValueType> outputs = returnType is VoidType ||
            returnType is NeverType ||
            returnType is NullType
        ? const []
        : [translator.translateType(returnType)];

    w.FunctionType functionType = m.addFunctionType(inputs, outputs);
    translator.functions[target] = m.addFunction(functionType);
  }
}
