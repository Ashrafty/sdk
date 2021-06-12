// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math';

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/param_info.dart';
import 'package:dart2wasm/tearoff_reference.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

import 'package:vm/metadata/table_selector.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class SelectorInfo {
  final Translator translator;

  final int id;
  final int callCount;
  final bool tornOff;
  final ParameterInfo paramInfo;
  int returnCount;

  final Map<int, Reference> targets = {};
  late w.FunctionType signature = computeSignature();

  late final List<int> classIds;
  late final int targetCount;
  Reference? singularTarget;
  int? offset;

  String get name => paramInfo.member.name.text;

  int get sortWeight => classIds.length * 10 + callCount;

  SelectorInfo(this.translator, this.id, this.callCount, this.tornOff,
      this.paramInfo, this.returnCount);

  w.FunctionType computeSignature() {
    var nameIndex = paramInfo.nameIndex;
    List<Set<ClassInfo>> inputSets =
        List.generate(1 + paramInfo.paramCount, (_) => {});
    List<Set<ClassInfo>> outputSets = List.generate(returnCount, (_) => {});
    List<bool> inputNullable = List.filled(1 + paramInfo.paramCount, false);
    List<bool> outputNullable = List.filled(returnCount, false);
    targets.forEach((id, target) {
      ClassInfo receiver = translator.classes[id];
      List<DartType> positional;
      Map<String, DartType> named;
      List<DartType> returns;
      Member member = target.asMember;
      if (member is Field) {
        if (target.isImplicitGetter) {
          positional = [];
          named = {};
          returns = [member.getterType];
        } else {
          positional = [member.setterType];
          named = {};
          returns = [];
        }
      } else {
        FunctionNode function = member.function!;
        if (target.isTearOffReference) {
          positional = [];
          named = {};
          returns = [function.computeFunctionType(Nullability.nonNullable)];
        } else {
          positional = [
            for (VariableDeclaration param in function.positionalParameters)
              param.type
          ];
          named = {
            for (VariableDeclaration param in function.namedParameters)
              param.name!: param.type
          };
          returns =
              function.returnType is VoidType ? [] : [function.returnType];
        }
      }
      assert(returns.length <= outputSets.length);
      inputSets[0].add(receiver);
      for (int i = 0; i < positional.length; i++) {
        DartType type = positional[i];
        inputSets[1 + i]
            .add(translator.classInfo[translator.classForType(type)]!);
        inputNullable[1 + i] |= type.isPotentiallyNullable;
      }
      for (String name in named.keys) {
        int i = nameIndex[name]!;
        DartType type = named[name]!;
        inputSets[1 + i]
            .add(translator.classInfo[translator.classForType(type)]!);
        inputNullable[1 + i] |= type.isPotentiallyNullable;
      }
      for (int i = 0; i < returnCount; i++) {
        if (i < returns.length) {
          outputSets[i]
              .add(translator.classInfo[translator.classForType(returns[i])]!);
          outputNullable[i] |= returns[i].isPotentiallyNullable;
        } else {
          outputNullable[i] = true;
        }
      }
    });

    List<w.ValueType> typeParameters = List.filled(paramInfo.typeParamCount,
        translator.classInfo[translator.typeClass]!.nullableType);
    List<w.ValueType> inputs = List.generate(
        inputSets.length,
        (i) => translator.typeForInfo(
            upperBound(inputSets[i]), inputNullable[i]) as w.ValueType);
    inputs[0] = translator.ensureBoxed(inputs[0]);
    List<w.ValueType> outputs = List.generate(
        outputSets.length,
        (i) => translator.typeForInfo(
            upperBound(outputSets[i]), outputNullable[i]) as w.ValueType);
    return translator.m.addFunctionType(
        [inputs[0], ...typeParameters, ...inputs.sublist(1)], outputs);
  }
}

class DispatchTable {
  final Translator translator;
  final List<TableSelectorInfo> selectorMetadata;

  Map<int, SelectorInfo> selectorInfo = {};
  late List<Reference?> table;

  DispatchTable(this.translator)
      : selectorMetadata = translator.tableSelectorAssigner.metadata.selectors;

  SelectorInfo selectorForTarget(Reference target) {
    Member member = target.asMember;
    bool isGetter = target.isGetter || target.isTearOffReference;
    int selectorId = isGetter
        ? translator.tableSelectorAssigner.getterSelectorId(member)
        : translator.tableSelectorAssigner.methodOrSetterSelectorId(member);
    ParameterInfo paramInfo = ParameterInfo.fromMember(target);
    int returnCount = isGetter ||
            member is Procedure && member.function.returnType is! VoidType
        ? 1
        : 0;
    var selector = selectorInfo.putIfAbsent(
        selectorId,
        () => SelectorInfo(
            translator,
            selectorId,
            selectorMetadata[selectorId].callCount,
            selectorMetadata[selectorId].tornOff,
            paramInfo,
            returnCount));
    selector.paramInfo.merge(paramInfo);
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
          selector.targets[info.classId] = selector.targets[superId]!;
        }
      }

      SelectorInfo addMember(Reference reference) {
        SelectorInfo selector = selectorForTarget(reference);
        selector.targets[info.classId] = reference;
        selectorIds.add(selector.id);
        return selector;
      }

      for (Member member
          in info.cls?.members ?? translator.coreTypes.objectClass.members) {
        if (member.isInstanceMember) {
          if (member is Field) {
            addMember(member.getterReference);
            if (member.hasSetter) addMember(member.setterReference!);
          } else if (member is Procedure) {
            SelectorInfo method = addMember(member.reference);
            if (method.tornOff) {
              addMember(member.tearOffReference);
            }
          }
        }
      }
      selectorsInClass.add(selectorIds);
    }

    // Build lists of class IDs and count targets
    for (SelectorInfo selector in selectorInfo.values) {
      selector.classIds = selector.targets.keys
          .where((id) => !(translator.classes[id].cls?.isAbstract ?? true))
          .toList()
            ..sort();
      Set<Reference> targets =
          selector.targets.values.where((t) => !t.asMember.isAbstract).toSet();
      selector.targetCount = targets.length;
      if (targets.length == 1) selector.singularTarget = targets.single;
    }

    // Assign selector offsets
    List<SelectorInfo> selectors = selectorInfo.values
        .where((s) => s.callCount > 0 && s.targetCount > 1)
        .toList()
          ..sort((a, b) => b.sortWeight - a.sortWeight);
    int firstAvailable = 0;
    table = [];
    bool first = true;
    for (SelectorInfo selector in selectors) {
      int offset = first ? 0 : firstAvailable - selector.classIds.first;
      first = false;
      bool fits;
      do {
        fits = true;
        for (int classId in selector.classIds) {
          int entry = offset + classId;
          if (entry >= table.length) {
            // Fits
            break;
          }
          if (table[entry] != null) {
            fits = false;
            break;
          }
        }
        if (!fits) offset++;
      } while (!fits);
      selector.offset = offset;
      for (int classId in selector.classIds) {
        int entry = offset + classId;
        while (table.length <= entry) table.add(null);
        assert(table[entry] == null);
        table[entry] = selector.targets[classId];
      }
      while (firstAvailable < table.length && table[firstAvailable] != null) {
        firstAvailable++;
      }
    }
    //print(table.map((e) => e != null ? "!" : ".").join());
  }

  void output() {
    w.Module m = translator.m;
    w.Table wasmTable = m.addTable(table.length);
    for (int i = 0; i < table.length; i++) {
      Reference? target = table[i];
      if (target != null) {
        w.BaseFunction? fun = translator.functions.getExistingFunction(target);
        if (fun != null) {
          wasmTable.setElement(i, fun);
          //print("$i: $fun");
        }
      }
    }
  }
}
