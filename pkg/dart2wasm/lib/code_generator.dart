// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:kernel/ast.dart';
import 'package:kernel/type_environment.dart';
import 'package:kernel/visitor.dart';

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/intrinsics.dart';
import 'package:dart2wasm/translator.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class CodeGenerator extends Visitor<void> {
  Translator translator;

  Map<VariableDeclaration, w.Local> locals = {};
  w.Local? thisLocal;
  late w.DefinedFunction function;
  late w.Instructions b;
  late StaticTypeContext typeContext;

  CodeGenerator(this.translator);

  void defaultTreeNode(TreeNode node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void generate(Member member, w.DefinedFunction function) {
    if (member.isExternal) {
      print("External member: $member");
      return;
    }

    typeContext = StaticTypeContext(member, translator.typeEnvironment);

    List<VariableDeclaration> params = member.function.positionalParameters;
    int implicitParams = function.locals.length - params.length;
    assert(implicitParams == 0 || implicitParams == 1);
    thisLocal = implicitParams == 1 ? function.locals[0] : null;
    for (int i = 0; i < params.length; i++) {
      locals[params[i]] = function.locals[implicitParams + i];
    }

    this.function = function;
    b = function.body;
    b.traceEnabled = true;
    if (member is Constructor) visitList(member.initializers, this);
    member.function.body.accept(this);
    b.end();
  }

  void visitFieldInitializer(FieldInitializer node) {
    w.StructType struct =
        translator.classes[(node.parent as Constructor).enclosingClass]!.struct;
    int fieldIndex = translator.fieldIndex[node.field]!;

    b.local_get(thisLocal!);
    node.value.accept(this);
    b.struct_set(struct, fieldIndex);
  }

  void visitSuperInitializer(SuperInitializer node) {
    if ((node.parent as Constructor).enclosingClass.superclass?.superclass ==
        null) {
      return;
    }
    b.local_get(thisLocal!);
    node.arguments.accept(this);
    b.call(translator.functions[node.target]!);
  }

  void visitBlock(Block node) {
    node.visitChildren(this);
  }

  void visitVariableDeclaration(VariableDeclaration node) {
    w.ValueType type = translator.translateType(node.type);
    w.Local local = function.addLocal(type);
    locals[node] = local;
    if (node.initializer != null) {
      node.initializer!.accept(this);
      b.local_set(local);
    }
  }

  void visitEmptyStatement(EmptyStatement node) {}

  void visitExpressionStatement(ExpressionStatement node) {
    _visitVoidExpression(node.expression);
  }

  void _visitVoidExpression(Expression exp) {
    exp.accept(this);
    if (exp.getStaticType(typeContext) is! VoidType) {
      b.drop();
    }
  }

  void visitIfStatement(IfStatement node) {
    node.condition.accept(this);
    b.if_();
    node.then.accept(this);
    Statement? otherwise = node.otherwise;
    if (otherwise != null) {
      b.else_();
      otherwise.accept(this);
    }
    b.end();
  }

  void visitWhileStatement(WhileStatement node) {
    w.Label block = b.block();
    w.Label loop = b.loop();
    node.condition.accept(this);
    b.i32_eqz();
    b.br_if(block);
    node.body.accept(this);
    b.br(loop);
    b.end();
    b.end();
  }

  void visitForStatement(ForStatement node) {
    visitList(node.variables, this);
    w.Label block = b.block();
    w.Label loop = b.loop();
    node.condition.accept(this);
    b.i32_eqz();
    b.br_if(block);
    node.body.accept(this);
    for (Expression update in node.updates) {
      _visitVoidExpression(update);
    }
    b.br(loop);
    b.end();
    b.end();
  }

  void visitReturnStatement(ReturnStatement node) {
    node.visitChildren(this);
    b.return_();
  }

  void visitLet(Let node) {
    node.visitChildren(this);
  }

  void visitThisExpression(ThisExpression node) {
    b.local_get(thisLocal!);
  }

  void visitConstructorInvocation(ConstructorInvocation node) {
    ClassInfo info = translator.classes[node.target.enclosingClass]!;
    w.Local temp = function.addLocal(info.repr);
    b.rtt_canon(w.HeapType.def(info.struct));
    b.struct_new_default_with_rtt(info.struct);
    b.local_tee(temp);
    node.arguments.accept(this);
    b.call(translator.functions[node.target]!);
    b.local_get(temp);
  }

  void visitStaticInvocation(StaticInvocation node) {
    node.arguments.accept(this);
    w.BaseFunction target = translator.functions[node.target]!;
    b.call(target);
  }

  void visitMethodInvocation(MethodInvocation node) {
    node.receiver.accept(this);
    node.arguments.accept(this);
    Member target = node.interfaceTarget;
    if (target is Procedure && target.kind == ProcedureKind.Operator) {
      Intrinsic? intrinsic =
          translator.intrinsics.getOperatorIntrinsic(node, this);
      if (intrinsic != null) {
        intrinsic(this);
        return;
      }
    }
    // TODO: Virtual calls
    w.BaseFunction? function = translator.functions[target];
    if (function == null) {
      throw "No known target for $node";
    }
    b.call(function);
  }

  @override
  void visitVariableGet(VariableGet node) {
    w.Local? local = locals[node.variable];
    if (local == null) {
      throw "Read of undefined variable $node";
    }
    b.local_get(local);
  }

  @override
  void visitVariableSet(VariableSet node) {
    w.Local? local = locals[node.variable];
    if (local == null) {
      throw "Read of undefined variable $node";
    }
    node.value.accept(this);
    b.local_tee(local);
  }

  @override
  void visitPropertyGet(PropertyGet node) {
    Member target = node.interfaceTarget;
    if (target is Field) {
      node.receiver.accept(this);
      w.StructType struct = translator.classes[target.enclosingClass]!.struct;
      int fieldIndex = translator.fieldIndex[target]!;
      //b.rtt_canon(w.HeapType.def(struct));
      //b.ref_cast(w.HeapType.any, w.HeapType.def(struct));
      b.struct_get(struct, fieldIndex);
      return;
    }
    throw "PropertyGet of non-Field $target not supported";
  }

  @override
  void visitPropertySet(PropertySet node) {
    Member target = node.interfaceTarget;
    if (target is Field) {
      node.receiver.accept(this);
      w.StructType struct = translator.classes[target.enclosingClass]!.struct;
      int fieldIndex = translator.fieldIndex[target]!;
      //b.rtt_canon(w.HeapType.def(struct));
      //b.ref_cast(w.HeapType.any, w.HeapType.def(struct));
      w.Local temp = function.addLocal(struct.fields[fieldIndex].type.unpacked);
      node.value.accept(this);
      b.local_tee(temp);
      b.struct_set(struct, fieldIndex);
      b.local_get(temp);
      return;
    }
    throw "PropertyGet of non-Field $target not supported";
  }

  void visitLogicalExpression(LogicalExpression node) {
    w.Label block = b.block([], [w.NumType.i32]);
    bool isAnd = node.operatorEnum == LogicalExpressionOperator.AND;
    b.i32_const(isAnd ? 0 : 1);
    node.left.accept(this);
    if (isAnd) b.i32_eqz();
    b.br_if(block);
    b.drop();
    node.right.accept(this);
    b.end();
  }

  void visitNullCheck(NullCheck node) {
    node.operand.accept(this);
  }

  void visitArguments(Arguments node) {
    visitList(node.positional, this);
    visitList(node.named.map((n) => n.value).toList(), this);
  }

  void visitIntLiteral(IntLiteral node) {
    b.i64_const(node.value);
  }

  void visitNullLiteral(NullLiteral node) {
    TreeNode parent = node.parent;
    DartType type;
    if (parent is VariableDeclaration) {
      type = parent.type;
    } else if (parent is VariableSet) {
      type = parent.variable.type;
    } else if (parent is PropertySet) {
      Member target = parent.interfaceTarget;
      type = target is Field
          ? target.type
          : target.function.positionalParameters.single.type;
    } else if (parent is FieldInitializer) {
      type = parent.field.type;
    } else {
      throw "Unsupported null literal context: $parent";
    }
    w.ValueType wasmType = translator.translateType(type);
    w.HeapType heapType =
        wasmType is w.RefType ? wasmType.heapType : w.HeapType.any;
    b.ref_null(heapType);
  }
}
