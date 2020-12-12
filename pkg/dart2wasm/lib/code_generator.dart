// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:kernel/visitor.dart';

import 'translator.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class CodeGenerator extends Visitor<void> {
  Translator translator;

  late w.Instructions b;

  DartType expected = const VoidType();

  CodeGenerator(this.translator);

  void defaultTreeNode(TreeNode node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void generate(Member member, w.DefinedFunction function) {
    b = function.body;
    member.function.body.accept(this);
    b.end();
  }

  void visitBlock(Block node) {
    node.visitChildren(this);
  }

  void visitExpressionStatement(ExpressionStatement node) {
    expected = const VoidType();
    node.visitChildren(this);
  }

  void visitStaticInvocation(StaticInvocation node) {
    node.arguments.accept(this);
    w.Function target = translator.functions[node.target]!;
    b.call(target);
  }

  void visitArguments(Arguments node) {
    visitList(node.positional, this);
    visitList(node.named.map((n) => n.value).toList(), this);
  }

  void visitIntLiteral(IntLiteral node) {
    b.i64_const(node.value);
  }
}
