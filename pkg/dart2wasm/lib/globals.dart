// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

import 'package:dart2wasm/translator.dart';

class Globals {
  final Translator translator;

  Map<Field, w.Global> globals = {};

  Globals(this.translator);

  w.Global getGlobal(Field variable) {
    return globals.putIfAbsent(variable, () {
      w.ValueType type =
          translator.translateType(variable.type).withNullability(true);
      w.DefinedGlobal global = translator.m.addGlobal(w.GlobalType(type));
      final w.Instructions b = global.initializer;
      switch (global.type.type) {
        case w.NumType.i32:
          b.i32_const(0);
          break;
        case w.NumType.i64:
          b.i64_const(0);
          break;
        case w.NumType.f32:
          b.f32_const(0);
          break;
        case w.NumType.f64:
          b.f64_const(0);
          break;
        default:
          if (type is w.RefType) {
            assert(type.nullable);
            b.ref_null(type.heapType);
          } else {
            throw "Unsupported global type ${variable.type} ($type)";
          }
          break;
      }
      b.end();
      return global;
    });
  }
}
