// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/translator.dart';
import 'package:dart2wasm/class_info.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class SelectorInfo {
  final Procedure example;

  final List<ClassInfo> classes = [];
  late final int offset;
  late final w.FunctionType signature;

  SelectorInfo(this.example);
}

class DispatchTable {
  Translator translator;

  Map<int, SelectorInfo> selectorInfo = {};
  late List<Procedure?> table;

  DispatchTable(this.translator);

  int _idForMember(Procedure member) {
    // TODO: Tearoffs
    return member.isGetter
        ? translator.tableSelectorAssigner.getterSelectorId(member)
        : translator.tableSelectorAssigner.methodOrSetterSelectorId(member);
  }

  int offsetForTarget(Procedure target) {
    return selectorInfo[_idForMember(target)]!.offset;
  }

  w.FunctionType signatureForTarget(Procedure target) {
    return selectorInfo[_idForMember(target)]!.signature;
  }

  void build() {
    // Collect class/selector combinations
    List<List<int>> selectorsInClass = [];
    for (ClassInfo info in translator.classes) {
      List<int> selectorIds = [];
      Class? superclass = info.cls.superclass;
      if (superclass != null) {
        int superId = translator.classInfo[superclass]!.classId;
        selectorIds = List.of(selectorsInClass[superId]);
        for (int selectorId in selectorIds) {
          selectorInfo[selectorId]!.classes.add(info);
        }
      }

      for (Member member in info.cls.members) {
        if (member is Procedure && member.isInstanceMember) {
          int selectorId = _idForMember(member);
          SelectorInfo? selector = selectorInfo[selectorId];
          if (selector != null) {
            if (selector.classes.last != info.classId) {
              selector.classes.add(info);
              selectorIds.add(selectorId);
            }
          } else {
            selector = selectorInfo[selectorId] = SelectorInfo(member);
            selector.classes.add(info);
            selectorIds.add(selectorId);
          }
        }
      }
      selectorsInClass.add(selectorIds);
    }

    // Compute signatures
    for (SelectorInfo selector in selectorInfo.values) {
      ClassInfo receiver = upperBound(selector.classes);
      FunctionNode function = selector.example.function;
      List<w.ValueType> inputs = [
        InterfaceType(receiver.cls, Nullability.nonNullable),
        ...function.positionalParameters.map((p) => p.type)
      ].map((t) => translator.translateType(t)).toList();
      List<w.ValueType> outputs = function.returnType is VoidType
          ? const []
          : [translator.translateType(function.returnType)];
      selector.signature = translator.m.addFunctionType(inputs, outputs);
    }

    // Quick and wasteful offset assignment
    int nextAvailable = 0;
    for (SelectorInfo selector in selectorInfo.values) {
      ClassInfo first = selector.classes.first;
      ClassInfo last = selector.classes.last;
      selector.offset = nextAvailable - first.classId;
      nextAvailable += last.classId - first.classId + 1;
    }

    // Fill table
    table = List.filled(nextAvailable, null);
    for (ClassInfo info in translator.classes) {
      Class? superclass = info.cls.superclass;
      if (superclass != null) {
        int superId = translator.classInfo[superclass]!.classId;
        for (int selectorId in selectorsInClass[superId]) {
          int offset = selectorInfo[selectorId]!.offset;
          table[offset + info.classId] = table[offset + superId];
          //print("$offset + ${info.classId} = ${table[offset + superId]}");
        }
      }
      for (Member member in info.cls.members) {
        if (member is Procedure &&
            member.isInstanceMember &&
            !member.isAbstract) {
          int selectorId = _idForMember(member);
          SelectorInfo selector = selectorInfo[selectorId]!;
          table[selector.offset + info.classId] = member;
          //print("${selector.offset} + ${info.classId} := $member");
        }
      }
    }
  }

  void output() {
    w.Module m = translator.m;
    w.Table wasmTable = m.addTable(table.length);
    for (int i = 0; i < table.length; i++) {
      Procedure? target = table[i];
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
