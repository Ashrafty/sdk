// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:kernel/visitor.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

import 'translator.dart';

class Analyzer extends RecursiveVisitor<void> {
  Translator translator;
  w.Module m;

  Analyzer(this.translator) : m = translator.m;
}
