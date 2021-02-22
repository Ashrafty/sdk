// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:math';

import 'package:kernel/ast.dart';
import 'package:kernel/type_environment.dart';
import 'package:kernel/visitor.dart';

import 'package:dart2wasm/body_analyzer.dart';
import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/translator.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

typedef CodeGenCallback = void Function(CodeGenerator codeGen);

class CodeGenerator extends Visitor<void> with VisitorVoidMixin {
  Translator translator;

  late Member member;
  late w.DefinedFunction function;
  late StaticTypeContext typeContext;
  late List<w.Local> paramLocals;
  w.Label? returnLabel;

  late BodyAnalyzer bodyAnalyzer;

  Map<VariableDeclaration, w.Local> locals = {};
  w.Local? thisLocal;
  late w.Instructions b;

  CodeGenerator(this.translator);

  ClassInfo get object => translator.classes[0];

  void defaultNode(Node node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void defaultTreeNode(TreeNode node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void generate(Member member, w.DefinedFunction function,
      {List<w.Local>? inlinedLocals, w.Label? returnLabel}) {
    if (member.isExternal) {
      print("External member: $member");
      return;
    }

    this.member = member;
    this.function = function;
    typeContext = StaticTypeContext(member, translator.typeEnvironment);
    paramLocals = inlinedLocals ?? function.locals;
    this.returnLabel = returnLabel;

    bodyAnalyzer = BodyAnalyzer(this);
    bodyAnalyzer.analyzeMember(member);
    //print(bodyAnalyzer.preserved);
    //print(bodyAnalyzer.inject);

    List<VariableDeclaration> params = member.function!.positionalParameters;
    int implicitParams = paramLocals.length - params.length;
    assert(implicitParams == 0 || implicitParams == 1);
    for (int i = 0; i < params.length; i++) {
      locals[params[i]] = paramLocals[implicitParams + i];
    }

    b = function.body;
    if (member is Constructor) {
      ClassInfo info = translator.classInfo[member.enclosingClass]!;
      thisLocal = paramLocals[0];
      Class cls = member.enclosingClass!;
      for (Field field in cls.fields) {
        if (field.isInstanceMember && field.initializer != null) {
          int fieldIndex = translator.fieldIndex[field]!;
          b.local_get(thisLocal!);
          wrap(field.initializer!);
          b.struct_set(info.struct, fieldIndex);
        }
      }
      visitList(member.initializers, this);
    } else if (implicitParams == 1) {
      ClassInfo info = translator.classInfo[member.enclosingClass]!;
      if (bodyAnalyzer.specializeThis) {
        thisLocal = function.addLocal(info.repr);
        b.local_get(paramLocals[0]);
        b.global_get(info.rtt);
        b.ref_cast();
        b.local_set(thisLocal!);
      } else {
        thisLocal = paramLocals[0];
      }
    } else {
      thisLocal = null;
    }
    member.function!.body!.accept(this);
    b.end();
  }

  void wrap(TreeNode node) {
    CodeGenCallback? injection = bodyAnalyzer.inject[node];
    if (injection != null) {
      injection(this);
    } else {
      node.accept(this);
    }
  }

  void _call(Member target) {
    w.BaseFunction targetFunction = translator.functions[target]!;
    if (translator.shouldInline(target)) {
      List<w.Local> inlinedLocals = targetFunction.type.inputs
          .map((t) => function.addLocal(t.withNullability(true)))
          .toList();
      for (w.Local local in inlinedLocals.reversed) {
        b.local_set(local);
      }
      w.Label block = b.block([], targetFunction.type.outputs);
      CodeGenerator(translator).generate(target, function,
          inlinedLocals: inlinedLocals, returnLabel: block);
    } else {
      b.call(targetFunction);
    }
  }

  void visitFieldInitializer(FieldInitializer node) {
    w.StructType struct = translator
        .classInfo[(node.parent as Constructor).enclosingClass]!.struct;
    int fieldIndex = translator.fieldIndex[node.field]!;

    b.local_get(thisLocal!);
    wrap(node.value);
    b.struct_set(struct, fieldIndex);
  }

  void visitSuperInitializer(SuperInitializer node) {
    if ((node.parent as Constructor).enclosingClass!.superclass?.superclass ==
        null) {
      return;
    }
    b.local_get(thisLocal!);
    _visitArguments(node.arguments);
    _call(node.target);
  }

  void visitBlock(Block node) {
    visitList(node.statements, this);
  }

  void visitBlockExpression(BlockExpression node) {
    node.body.accept(this);
    wrap(node.value);
  }

  void visitVariableDeclaration(VariableDeclaration node) {
    w.ValueType type = translator.translateType(node.type);
    w.Local local = function.addLocal(type.withNullability(true));
    locals[node] = local;
    if (node.initializer != null) {
      wrap(node.initializer!);
      b.local_set(local);
    }
  }

  void visitEmptyStatement(EmptyStatement node) {}

  void visitExpressionStatement(ExpressionStatement node) {
    wrap(node.expression);
  }

  bool _hasLogicalOperator(Expression condition) {
    while (condition is Not) condition = condition.operand;
    return condition is LogicalExpression;
  }

  void _branchIf(Expression? condition, w.Label target,
      {required bool negated}) {
    if (condition == null) {
      b.br(target);
      return;
    }
    while (condition is Not) {
      negated = !negated;
      condition = condition.operand;
    }
    if (condition is LogicalExpression) {
      bool isConjunctive =
          (condition.operatorEnum == LogicalExpressionOperator.AND) ^ negated;
      if (isConjunctive) {
        w.Label conditionBlock = b.block();
        _branchIf(condition.left, conditionBlock, negated: !negated);
        _branchIf(condition.right, target, negated: negated);
        b.end();
      } else {
        _branchIf(condition.left, target, negated: negated);
        _branchIf(condition.right, target, negated: negated);
      }
    } else {
      wrap(condition!);
      if (negated) {
        b.i32_eqz();
      }
      b.br_if(target);
    }
  }

  void _conditional(Expression condition, TreeNode then, TreeNode? otherwise,
      List<w.ValueType> result) {
    if (!_hasLogicalOperator(condition)) {
      // Simple condition
      wrap(condition);
      b.if_(const [], result);
      wrap(then);
      if (otherwise != null) {
        b.else_();
        wrap(otherwise);
      }
      b.end();
    } else {
      // Complex condition
      w.Label ifBlock = b.block(const [], result);
      if (otherwise != null) {
        w.Label elseBlock = b.block();
        _branchIf(condition, elseBlock, negated: true);
        wrap(then);
        b.br(ifBlock);
        b.end();
        wrap(otherwise);
      } else {
        _branchIf(condition, ifBlock, negated: true);
        wrap(then);
      }
      b.end();
    }
  }

  void visitIfStatement(IfStatement node) {
    _conditional(node.condition, node.then, node.otherwise, const []);
  }

  void visitDoStatement(DoStatement node) {
    w.Label loop = b.loop();
    wrap(node.body);
    _branchIf(node.condition, loop, negated: false);
    b.end();
  }

  void visitWhileStatement(WhileStatement node) {
    w.Label block = b.block();
    w.Label loop = b.loop();
    _branchIf(node.condition, block, negated: true);
    wrap(node.body);
    b.br(loop);
    b.end();
    b.end();
  }

  void visitForStatement(ForStatement node) {
    visitList(node.variables, this);
    w.Label block = b.block();
    w.Label loop = b.loop();
    _branchIf(node.condition, block, negated: true);
    node.body.accept(this);
    for (Expression update in node.updates) {
      wrap(update);
    }
    b.br(loop);
    b.end();
    b.end();
  }

  void visitReturnStatement(ReturnStatement node) {
    Expression? expression = node.expression;
    if (expression != null) {
      wrap(expression);
    }
    if (returnLabel != null) {
      b.br(returnLabel!);
    } else {
      b.return_();
    }
  }

  void visitLet(Let node) {
    node.variable.accept(this);
    wrap(node.body);
  }

  void visitThisExpression(ThisExpression node) {
    b.local_get(thisLocal!);
  }

  void visitConstructorInvocation(ConstructorInvocation node) {
    ClassInfo info = translator.classInfo[node.target.enclosingClass]!;
    w.Local temp = function.addLocal(info.repr);
    b.global_get(info.rtt);
    b.struct_new_default_with_rtt(info.struct);
    b.local_tee(temp);
    b.local_get(temp);
    b.i32_const(info.classId);
    b.struct_set(info.struct, 0);
    _visitArguments(node.arguments);
    _call(node.target);
    if (bodyAnalyzer.preserved.contains(node)) {
      b.local_get(temp);
    }
  }

  void visitStaticInvocation(StaticInvocation node) {
    _visitArguments(node.arguments);
    _call(node.target);
  }

  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    b.local_get(thisLocal!);
    if (translator.optionParameterNullability && thisLocal!.type.nullable) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments);
    _call(node.interfaceTarget!);
  }

  void visitInstanceInvocation(InstanceInvocation node) {
    Procedure target = node.interfaceTarget;
    wrap(node.receiver);
    _virtualCall(target, node.arguments, getter: false, setter: false);
  }

  void visitEqualsCall(EqualsCall node) {
    // TODO: virtual call
    wrap(node.left);
    wrap(node.right);
    b.ref_eq();
    if (node.isNot) {
      b.i32_eqz();
    }
  }

  void visitEqualsNull(EqualsNull node) {
    wrap(node.expression);
    b.ref_is_null();
    if (node.isNot) {
      b.i32_eqz();
    }
  }

  void _virtualCall(Procedure interfaceTarget, Arguments arguments,
      {required bool getter, required bool setter}) {
    Member? singleTarget = translator.subtypes
        .getSingleTargetForInterfaceInvocation(interfaceTarget, setter: setter);
    if (singleTarget != null) {
      _visitArguments(arguments);
      _call(singleTarget);
      return;
    }

    int selectorId = getter
        ? translator.tableSelectorAssigner.getterSelectorId(interfaceTarget)
        : translator.tableSelectorAssigner
            .methodOrSetterSelectorId(interfaceTarget);
    SelectorInfo selector = translator.dispatchTable.selectorInfo[selectorId]!;

    // Receiver is already on stack.
    w.Local receiver =
        function.addLocal(w.RefType.def(object.struct, nullable: true));
    b.local_tee(receiver);
    _visitArguments(arguments);

    if (translator.optionPolymorphicSpecialization) {
      return _polymorphicSpecialization(selector, receiver);
    }

    b.i32_const(selector.offset);
    b.local_get(receiver);
    b.struct_get(object.struct, 0);
    b.i32_add();
    b.call_indirect(selector.signature);
  }

  void _polymorphicSpecialization(SelectorInfo selector, w.Local receiver) {
    Map<int, Procedure> implementations = Map.from(selector.classes);
    implementations.removeWhere((id, target) => target.isAbstract);

    w.Local idVar = function.addLocal(w.NumType.i32);
    b.local_get(receiver);
    b.struct_get(object.struct, 0);
    b.local_set(idVar);

    w.Label block =
        b.block(selector.signature.inputs, selector.signature.outputs);
    calls:
    while (Set.from(implementations.values).length > 1) {
      for (int id in implementations.keys) {
        Procedure target = implementations[id]!;
        if (implementations.values.where((t) => t == target).length == 1) {
          // Single class id implements method.
          b.local_get(idVar);
          b.i32_const(id);
          b.i32_eq();
          b.if_(selector.signature.inputs, selector.signature.inputs);
          _call(target);
          b.br(block);
          b.end();
          implementations.remove(id);
          continue calls;
        }
      }
      // Find class id that separates remaining classes in two.
      List<int> sorted = implementations.keys.toList()..sort();
      int pivotId = sorted.firstWhere(
          (id) => implementations[id] != implementations[sorted.first]);
      // Fail compilation if no such id exists.
      assert(sorted.lastWhere(
              (id) => implementations[id] != implementations[pivotId]) ==
          pivotId - 1);
      Procedure target = implementations[sorted.first]!;
      b.local_get(idVar);
      b.i32_const(pivotId);
      b.i32_lt_u();
      b.if_(selector.signature.inputs, selector.signature.inputs);
      _call(target);
      b.br(block);
      b.end();
      for (int id in sorted) {
        if (id == pivotId) break;
        implementations.remove(id);
      }
      continue calls;
    }
    // Call remaining implementation.
    Procedure target = implementations.values.first;
    _call(target);
    b.end();
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
    wrap(node.value);
    if (bodyAnalyzer.preserved.contains(node)) {
      b.local_tee(local);
    } else {
      b.local_set(local);
    }
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    Member target = node.interfaceTarget;
    if (target is Field) {
      wrap(node.receiver);
      w.StructType struct = translator.classInfo[target.enclosingClass]!.struct;
      int fieldIndex = translator.fieldIndex[target]!;
      b.struct_get(struct, fieldIndex);
      return;
    } else if (target is Procedure && target.isGetter) {
      wrap(node.receiver);
      _virtualCall(target, Arguments([]), getter: true, setter: false);
      return;
    }
    throw "InstanceGet of non-Field/Getter $target not supported";
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    Member target = node.interfaceTarget;
    if (target is Field) {
      wrap(node.receiver);
      w.StructType struct = translator.classInfo[target.enclosingClass]!.struct;
      int fieldIndex = translator.fieldIndex[target]!;
      wrap(node.value);
      if (bodyAnalyzer.preserved.contains(node)) {
        w.Local temp =
            function.addLocal(struct.fields[fieldIndex].type.unpacked);
        b.local_tee(temp);
        b.struct_set(struct, fieldIndex);
        b.local_get(temp);
      } else {
        b.struct_set(struct, fieldIndex);
      }
      return;
    }
    throw "InstanceSet of non-Field $target not supported";
  }

  void visitLogicalExpression(LogicalExpression node) {
    _conditional(
        node, BoolLiteral(true), BoolLiteral(false), const [w.NumType.i32]);
  }

  void visitNot(Not node) {
    wrap(node.operand);
    b.i32_eqz();
  }

  void visitConditionalExpression(ConditionalExpression node) {
    w.ValueType? type = bodyAnalyzer.expressionType[node]!;
    _conditional(
        node.condition, node.then, node.otherwise, [if (type != null) type]);
  }

  void visitNullCheck(NullCheck node) {
    wrap(node.operand);
  }

  void _visitArguments(Arguments node) {
    for (Expression arg in node.positional) {
      wrap(arg);
    }
  }

  void visitConstantExpression(ConstantExpression node) {
    node.constant.accept(this);
  }

  void visitBoolLiteral(BoolLiteral node) {
    b.i32_const(node.value ? 1 : 0);
  }

  void visitBoolConstant(BoolConstant node) {
    b.i32_const(node.value ? 1 : 0);
  }

  void visitIntLiteral(IntLiteral node) {
    b.i64_const(node.value);
  }

  void visitIntConstant(IntConstant node) {
    b.i64_const(node.value);
  }

  void visitDoubleLiteral(DoubleLiteral node) {
    b.f64_const(node.value);
  }

  void visitDoubleConstant(DoubleConstant node) {
    b.f64_const(node.value);
  }

  void visitAsExpression(AsExpression node) {
    wrap(node.operand);
    // TODO: Check
  }

  void visitNullLiteral(NullLiteral node) {
    w.ValueType wasmType = bodyAnalyzer.expressionType[node]!;
    w.HeapType heapType =
        wasmType is w.RefType ? wasmType.heapType : w.HeapType.any;
    b.ref_null(heapType);
  }

  void visitNullConstant(NullConstant node) {
    w.ValueType wasmType = bodyAnalyzer.expressionType[node]!;
    w.HeapType heapType =
        wasmType is w.RefType ? wasmType.heapType : w.HeapType.any;
    b.ref_null(heapType);
  }
}
