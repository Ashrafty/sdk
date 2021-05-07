// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/tearoff_reference.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/external_name.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class FunctionCollector extends MemberVisitor1<w.FunctionType, Reference> {
  final Translator translator;
  final Map<Reference, w.BaseFunction> _functions = {};
  final List<Reference> pending = [];

  FunctionCollector(this.translator);

  w.Module get m => translator.m;

  void collectImports() {
    for (Library library in translator.libraries) {
      for (Procedure procedure in library.procedures) {
        _import(procedure);
      }
      for (Class cls in library.classes) {
        for (Procedure procedure in cls.procedures) {
          _import(procedure);
        }
      }
    }
  }

  void _import(Procedure procedure) {
    String? externalName = getExternalName(procedure);
    if (externalName != null) {
      int dot = externalName.indexOf('.');
      if (dot != -1) {
        assert(!procedure.isInstanceMember);
        String module = externalName.substring(0, dot);
        String name = externalName.substring(dot + 1);
        w.FunctionType ftype = _makeFunctionType(
            procedure.reference, procedure.function.returnType, null,
            getter: procedure.isGetter);
        _functions[procedure.reference] = m.importFunction(module, name, ftype);
      }
    }
  }

  w.BaseFunction? getExistingFunction(Reference target) {
    return _functions[target];
  }

  w.BaseFunction getFunction(Reference target) {
    return _functions.putIfAbsent(target, () {
      pending.add(target);
      w.FunctionType ftype = target.isTearOffReference
          ? translator.dispatchTable.selectorForTarget(target).signature
          : target.asMember.accept1(this, target);
      return m.addFunction(ftype);
    });
  }

  void activateSelector(SelectorInfo selector) {
    for (Reference target in selector.targets.values) {
      if (!target.asMember.isAbstract) {
        getFunction(target);
      }
    }
  }

  w.FunctionType defaultMember(Member node, Reference target) {
    throw "No Wasm function for member: $node";
  }

  w.FunctionType visitField(Field node, Reference target) {
    if (!node.isInstanceMember) {
      String kind = target == node.setterReference ? "setter" : "getter";
      throw "No implicit $kind function for static field: $node";
    }
    return translator.dispatchTable.selectorForTarget(target).signature;
  }

  w.FunctionType visitProcedure(Procedure node, Reference target) {
    assert(!node.isAbstract);
    return node.isInstanceMember
        ? translator.dispatchTable.selectorForTarget(node.reference).signature
        : _makeFunctionType(target, node.function.returnType, null,
            getter: node.isGetter);
  }

  w.FunctionType visitConstructor(Constructor node, Reference target) {
    return _makeFunctionType(
        target,
        VoidType(),
        w.RefType.def(translator.classInfo[node.enclosingClass]!.struct,
            nullable: false),
        getter: false);
  }

  w.FunctionType _makeFunctionType(
      Reference target, DartType returnType, w.ValueType? receiverType,
      {required bool getter}) {
    Member member = target.asMember;
    Iterable<DartType> params;
    if (member is Field) {
      params = [if (target.isImplicitSetter) member.setterType];
    } else {
      FunctionNode function = member.function!;
      List<String> names = [for (var p in function.namedParameters) p.name!]
        ..sort();
      Map<String, DartType> nameTypes = {
        for (var p in function.namedParameters) p.name!: p.type
      };
      params = [
        for (var p in function.positionalParameters) p.type,
        for (String name in names) nameTypes[name]!
      ];
      function.positionalParameters.map((p) => p.type);
    }

    List<w.ValueType> inputs = [];
    if (receiverType != null) {
      inputs.add(receiverType);
    }
    inputs.addAll(params.map((t) => translator.translateType(t)));

    List<w.ValueType> outputs = returnType is VoidType ||
            returnType is NeverType ||
            returnType is NullType
        ? const []
        : [translator.translateType(returnType)];

    return m.addFunctionType(inputs, outputs);
  }
}
