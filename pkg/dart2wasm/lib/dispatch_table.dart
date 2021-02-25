// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math';

import 'package:dart2wasm/translator.dart';
import 'package:dart2wasm/class_info.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class SelectorInfo {
  final int id;
  int paramCount;
  int returnCount;

  final Map<int, Reference> classes = {};
  late final int offset;
  late final w.FunctionType signature;

  SelectorInfo(this.id, this.paramCount, this.returnCount);
}

class DispatchTable {
  Translator translator;

  Map<int, SelectorInfo> selectorInfo = {};
  late List<Reference?> table;

  DispatchTable(this.translator);

  SelectorInfo selectorForTarget(Reference target) {
    // TODO: Tearoffs
    Member member = target.asMember;
    bool isGetter = target.isGetter;
    int selectorId = isGetter
        ? translator.tableSelectorAssigner.getterSelectorId(member)
        : translator.tableSelectorAssigner.methodOrSetterSelectorId(member);
    int paramCount = isGetter
        ? 0
        : member is Procedure
            ? member.function!.positionalParameters.length
            : 1;
    int returnCount = isGetter ||
            member is Procedure && member.function!.returnType is! VoidType
        ? 1
        : 0;
    var selector = selectorInfo.putIfAbsent(
        selectorId, () => SelectorInfo(selectorId, paramCount, returnCount));
    selector.paramCount = min(selector.paramCount, paramCount);
    selector.returnCount = max(selector.returnCount, returnCount);
    return selector;
  }

  void build() {
    // Collect class/selector combinations
    List<List<int>> selectorsInClass = [];
    for (ClassInfo info in translator.classes) {
      List<int> selectorIds = [];
      ClassInfo? superInfo = info.superInfo;
      if (superInfo != null) {
        int superId = superInfo.classId;
        selectorIds = List.of(selectorsInClass[superId]);
        for (int selectorId in selectorIds) {
          SelectorInfo selector = selectorInfo[selectorId]!;
          selector.classes[info.classId] = selector.classes[superId]!;
        }
      }

      void addMember(Reference reference) {
        SelectorInfo selector = selectorForTarget(reference);
        selector.classes[info.classId] = reference;
        selectorIds.add(selector.id);
      }

      for (Member member in info.cls.members) {
        if (member.isInstanceMember) {
          if (member is Field) {
            addMember(member.getterReference);
            if (member.hasSetter) addMember(member.setterReference!);
          } else {
            addMember(member.reference);
          }
        }
      }
      selectorsInClass.add(selectorIds);
    }

    // Compute signatures
    for (SelectorInfo selector in selectorInfo.values) {
      List<Set<ClassInfo>> inputSets =
          List.generate(1 + selector.paramCount, (_) => {});
      List<Set<ClassInfo>> outputSets =
          List.generate(selector.returnCount, (_) => {});
      List<bool> inputNullable = List.filled(1 + selector.paramCount, false);
      List<bool> outputNullable = List.filled(selector.returnCount, false);
      selector.classes.forEach((id, target) {
        ClassInfo receiver = translator.classes[id];
        List<DartType> params;
        List<DartType> returns;
        Member member = target.asMember;
        if (member is Field) {
          if (target.isImplicitGetter) {
            params = [];
            returns = [member.getterType];
          } else {
            params = [member.setterType];
            returns = [];
          }
        } else {
          FunctionNode function = member.function!;
          params = [
            for (VariableDeclaration param in function.positionalParameters)
              param.type
          ];
          returns =
              function.returnType is VoidType ? [] : [function.returnType];
        }
        assert(1 + params.length >= inputSets.length);
        assert(returns.length <= outputSets.length);
        inputSets[0].add(receiver);
        for (int i = 0; i < selector.paramCount; i++) {
          inputSets[1 + i]
              .add(translator.classInfo[translator.classForType(params[i])]!);
          inputNullable[1 + i] |= params[i].isPotentiallyNullable;
        }
        for (int i = 0; i < selector.returnCount; i++) {
          if (i < returns.length) {
            outputSets[i].add(
                translator.classInfo[translator.classForType(returns[i])]!);
            outputNullable[i] |= returns[i].isPotentiallyNullable;
          } else {
            outputNullable[i] = true;
          }
        }
      });
      List<w.ValueType> inputs = List.generate(
          inputSets.length,
          (i) => translator.translateType(InterfaceType(
              upperBound(inputSets[i]).cls,
              inputNullable[i]
                  ? Nullability.nullable
                  : Nullability.nonNullable)));
      List<w.ValueType> outputs = List.generate(
          outputSets.length,
          (i) => translator.translateType(InterfaceType(
              upperBound(outputSets[i]).cls,
              outputNullable[i]
                  ? Nullability.nullable
                  : Nullability.nonNullable)));
      selector.signature = translator.m.addFunctionType(inputs, outputs);
    }

    // Quick and wasteful offset assignment
    int nextAvailable = 0;
    for (SelectorInfo selector in selectorInfo.values) {
      List<int> classIds = selector.classes.keys
          .where((id) => !translator.classes[id].cls.isAbstract)
          .toList()
            ..sort();
      if (classIds.isNotEmpty) {
        selector.offset = nextAvailable - classIds.first;
        nextAvailable += classIds.last - classIds.first + 1;
      }
    }
    //print("Dispatch table size: $nextAvailable");

    // Fill table
    table = List.filled(nextAvailable, null);
    for (SelectorInfo selector in selectorInfo.values) {
      for (int classId in selector.classes.keys) {
        if (!translator.classes[classId].cls.isAbstract) {
          assert(table[selector.offset + classId] == null);
          table[selector.offset + classId] = selector.classes[classId];
        }
      }
    }
  }

  void output() {
    w.Module m = translator.m;
    w.Table wasmTable = m.addTable(table.length);
    for (int i = 0; i < table.length; i++) {
      Reference? target = table[i];
      if (target != null) {
        w.BaseFunction? fun = translator.functions[target];
        if (fun != null) {
          wasmTable.setElement(i, fun);
          //print("$i: $fun");
        }
      }
    }
  }
}
