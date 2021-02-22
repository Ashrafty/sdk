// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/translator.dart';
import 'package:dart2wasm/class_info.dart';

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class SelectorInfo {
  final Procedure example;

  final Map<int, Procedure> classes = {};
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
      ClassInfo? superInfo = info.superInfo;
      if (superInfo != null) {
        int superId = superInfo.classId;
        selectorIds = List.of(selectorsInClass[superId]);
        for (int selectorId in selectorIds) {
          SelectorInfo selector = selectorInfo[selectorId]!;
          selector.classes[info.classId] = selector.classes[superId]!;
        }
      }

      for (Member member in info.cls.members) {
        if (member is Procedure && member.isInstanceMember) {
          int selectorId = _idForMember(member);
          SelectorInfo? selector = selectorInfo[selectorId];
          if (selector == null) {
            selector = selectorInfo[selectorId] = SelectorInfo(member);
          } else {
            //FunctionType f1 = selector.example.function
            //    .computeFunctionType(Nullability.nonNullable);
            //FunctionType f2 =
            //    member.function.computeFunctionType(Nullability.nonNullable);
            //assert(
            //    f1 == f2,
            //    "Changing function type on override not supported: "
            //    "$f1 $f2");
          }
          selector.classes[info.classId] = member;
          selectorIds.add(selectorId);
        }
      }
      selectorsInClass.add(selectorIds);
    }

    // Compute signatures
    for (SelectorInfo selector in selectorInfo.values) {
      ClassInfo receiver =
          upperBound(selector.classes.keys.map((id) => translator.classes[id]));
      FunctionNode function = selector.example.function!;
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
