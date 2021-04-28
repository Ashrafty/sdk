// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/body_analyzer.dart';
import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/closures.dart';
import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/param_info.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/type_environment.dart';
import 'package:kernel/visitor.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class CodeGenerator extends Visitor<void> with VisitorVoidMixin {
  Translator translator;
  w.ValueType voidMarker;

  late Member member;
  late w.DefinedFunction function;
  late StaticTypeContext typeContext;
  late List<w.Local> paramLocals;
  w.Label? returnLabel;
  late w.ValueType returnType;

  late BodyAnalyzer bodyAnalyzer;
  late Closures closures;

  Map<VariableDeclaration, w.Local> locals = {};
  w.Local? thisLocal;
  List<Statement> finalizers = [];

  late w.Instructions b;

  CodeGenerator(this.translator) : voidMarker = translator.voidMarker;

  TranslatorOptions get options => translator.options;

  ClassInfo get object => translator.classes[0];

  w.ValueType translateType(DartType type) => translator.translateType(type);

  w.ValueType typeForLocal(w.ValueType type) => translator.typeForLocal(type);

  void defaultNode(Node node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void defaultTreeNode(TreeNode node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void generate(Reference reference, w.DefinedFunction function,
      {List<w.Local>? inlinedLocals, w.Label? returnLabel}) {
    closures = Closures(this);

    Member member = reference.asMember;
    b = function.body;
    if (member.isExternal) {
      b.unreachable();
      b.end();
      return;
    }

    this.member = member;
    this.function = function;
    typeContext = StaticTypeContext(member, translator.typeEnvironment);
    paramLocals = inlinedLocals ?? function.locals;
    this.returnLabel = returnLabel;
    returnType = translator
        .outputOrVoid(returnLabel?.targetTypes ?? function.type.outputs);

    if (member is Field) {
      // Implicit getter or setter
      w.StructType struct =
          translator.classInfo[member.enclosingClass!]!.struct;
      int index = translator.fieldIndex[member]!;
      w.ValueType fieldType = struct.fields[index].type.unpacked;

      void getThis() {
        w.Local thisLocal = paramLocals[0];
        w.RefType structType = w.RefType.def(struct, nullable: true);
        b.local_get(thisLocal);
        translator.convertType(function, thisLocal.type, structType);
      }

      if (reference.isImplicitGetter) {
        // Implicit getter
        getThis();
        b.struct_get(struct, index);
        translator.convertType(function, fieldType, returnType);
      } else {
        // Implicit setter
        w.Local valueLocal = paramLocals[1];
        getThis();
        b.local_get(valueLocal);
        translator.convertType(function, valueLocal.type, fieldType);
        b.struct_set(struct, index);
      }
      b.end();
      return;
    }

    locals.clear();
    ParameterInfo paramInfo = translator.paramInfoFor(reference);
    int implicitParams =
        member.isInstanceMember || member is Constructor ? 1 : 0;
    assert(implicitParams == 0 || implicitParams == 1);
    List<VariableDeclaration> positional =
        member.function!.positionalParameters;
    for (int i = 0; i < positional.length; i++) {
      locals[positional[i]] = paramLocals[implicitParams + i];
    }
    List<VariableDeclaration> named = member.function!.namedParameters;
    for (var param in named) {
      locals[param] =
          paramLocals[implicitParams + paramInfo.nameIndex[param.name]!];
    }

    closures.findCaptures(member.function!);

    bool specializeThis = true;
    if (!options.stubBodies) {
      bodyAnalyzer = BodyAnalyzer(this);
      bodyAnalyzer.analyzeMember(member);
      specializeThis = bodyAnalyzer.specializeThis;
    }

    if (member is Constructor) {
      ClassInfo info = translator.classInfo[member.enclosingClass]!;
      thisLocal = paramLocals[0];
      if (!options.stubBodies) {
        Class cls = member.enclosingClass;
        for (Field field in cls.fields) {
          if (field.isInstanceMember && field.initializer != null) {
            int fieldIndex = translator.fieldIndex[field]!;
            b.local_get(thisLocal!);
            wrap(field.initializer!);
            b.struct_set(info.struct, fieldIndex);
          }
        }
        visitList(member.initializers, this);
      }
    } else if (implicitParams == 1) {
      ClassInfo info = translator.classInfo[member.enclosingClass]!;
      w.RefType thisType = w.RefType.def(info.repr.struct, nullable: false);
      if (specializeThis &&
          translator.needsConversion(paramLocals[0].type, thisType)) {
        thisLocal = function.addLocal(typeForLocal(thisType));
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

    closures.buildContexts(member.function!);
    allocateContext(member.function!);
    captureParameters();

    if (options.stubBodies) {
      member.function!.body!.accept(StubBodyTraversal(this));
      b.unreachable();
      b.end();
      return;
    }

    member.function!.body!.accept(this);

    if (function.type.outputs.length > 0) {
      w.ValueType returnType = function.type.outputs[0];
      if (returnType is w.RefType && returnType.nullable) {
        // Dart body may have an implicit return null.
        b.ref_null(returnType.heapType);
      }
    }
    b.end();
  }

  void generateLambda(Lambda lambda) {
    function = lambda.function;
    b = function.body;
    paramLocals = function.locals;
    returnType = function.type.outputs.single;

    locals.clear();
    final int implicitParams = 1;
    List<VariableDeclaration> positional =
        lambda.functionNode.positionalParameters;
    for (int i = 0; i < positional.length; i++) {
      locals[positional[i]] = paramLocals[implicitParams + i];
    }

    Context? context = closures.contexts[lambda.functionNode]?.parent;
    if (context != null) {
      b.local_get(function.locals[0]);
      b.rtt_canon(context.struct);
      b.ref_cast();
      while (true) {
        w.Local contextLocal = function.addLocal(
            typeForLocal(w.RefType.def(context!.struct, nullable: false)));
        context.currentLocal = contextLocal;
        if (context.parent != null || context.containsThis) {
          b.local_tee(contextLocal);
        } else {
          b.local_set(contextLocal);
        }
        if (context.parent == null) break;

        b.struct_get(context.struct, context.parentFieldIndex);
        context = context.parent!;
      }
      if (context.containsThis) {
        thisLocal = function.addLocal(typeForLocal(
            context.struct.fields[context.thisFieldIndex].type.unpacked));
        b.struct_get(context.struct, context.thisFieldIndex);
        b.local_set(thisLocal!);
      }
    }
    allocateContext(lambda.functionNode);
    captureParameters();

    if (options.stubBodies) {
      b.unreachable();
      b.end();
      return;
    }

    lambda.functionNode.body!.accept(this);
    if (lambda.functionNode.returnType is VoidType) {
      b.ref_null(w.HeapType.def(object.struct));
    }
    b.end();
  }

  void allocateContext(TreeNode node) {
    Context? context = closures.contexts[node];
    if (context != null && !context.isEmpty) {
      w.Local contextLocal = function.addLocal(
          typeForLocal(w.RefType.def(context.struct, nullable: false)));
      context.currentLocal = contextLocal;
      b.rtt_canon(context.struct);
      b.struct_new_default_with_rtt(context.struct);
      b.local_set(contextLocal);
      if (context.containsThis) {
        b.local_get(contextLocal);
        b.local_get(thisLocal!);
        b.struct_set(context.struct, context.thisFieldIndex);
      }
      if (context.parent != null) {
        w.Local parentLocal = context.parent!.currentLocal;
        b.local_get(contextLocal);
        b.local_get(parentLocal);
        b.struct_set(context.struct, context.parentFieldIndex);
      }
    }
  }

  void captureParameters() {
    locals.forEach((variable, local) {
      Capture? capture = closures.captures[variable];
      if (capture != null) {
        b.local_get(capture.context.currentLocal);
        b.local_get(local);
        translator.convertType(function, local.type,
            capture.context.struct.fields[capture.fieldIndex].type.unpacked);
        b.struct_set(capture.context.struct, capture.fieldIndex);
      }
    });
  }

  void wrap(TreeNode node) {
    CodeGenCallback? injection = bodyAnalyzer.inject[node];
    if (injection != null) {
      injection(b);
    } else {
      node.accept(this);
    }
  }

  void _call(Reference target) {
    assert(target.asMember is! Field);
    w.BaseFunction targetFunction = translator.functions.getFunction(target);
    if (translator.shouldInline(target)) {
      List<w.Local> inlinedLocals = targetFunction.type.inputs
          .map((t) => function.addLocal(typeForLocal(t)))
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

  void visitRedirectingInitializer(RedirectingInitializer node) {
    b.local_get(thisLocal!);
    if (options.parameterNullability && thisLocal!.type.nullable) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments, node.targetReference, 1);
    _call(node.targetReference);
  }

  void visitSuperInitializer(SuperInitializer node) {
    if ((node.parent as Constructor).enclosingClass.superclass?.superclass ==
        null) {
      return;
    }
    b.local_get(thisLocal!);
    if (options.parameterNullability && thisLocal!.type.nullable) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments, node.targetReference, 1);
    _call(node.targetReference);
  }

  void visitBlock(Block node) {
    visitList(node.statements, this);
  }

  void visitBlockExpression(BlockExpression node) {
    node.body.accept(this);
    wrap(node.value);
  }

  void visitVariableDeclaration(VariableDeclaration node) {
    w.ValueType type = translateType(node.type);
    w.Local? local;
    Capture? capture = closures.captures[node];
    if (capture == null || !capture.written) {
      local = function.addLocal(typeForLocal(type));
      locals[node] = local;
    }
    if (node.initializer != null) {
      if (capture != null) {
        b.local_get(capture.context.currentLocal);
        wrap(node.initializer!);
        if (!capture.written) {
          b.local_tee(local!);
        }
        b.struct_set(capture.context.struct, capture.fieldIndex);
      } else {
        wrap(node.initializer!);
        b.local_set(local!);
      }
    }
  }

  void visitEmptyStatement(EmptyStatement node) {}

  void visitAssertStatement(AssertStatement node) {}

  void visitTryCatch(TryCatch node) {
    // TODO: Include catches
    node.body.accept(this);
  }

  visitTryFinally(TryFinally node) {
    finalizers.add(node.finalizer);
    node.body.accept(this);
    finalizers.removeLast().accept(this);
  }

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
    allocateContext(node);
    wrap(node.body);
    _branchIf(node.condition, loop, negated: false);
    b.end();
  }

  void visitWhileStatement(WhileStatement node) {
    w.Label block = b.block();
    w.Label loop = b.loop();
    _branchIf(node.condition, block, negated: true);
    allocateContext(node);
    wrap(node.body);
    b.br(loop);
    b.end();
    b.end();
  }

  void visitForStatement(ForStatement node) {
    Context? context = closures.contexts[node];
    allocateContext(node);
    visitList(node.variables, this);
    w.Label block = b.block();
    w.Label loop = b.loop();
    _branchIf(node.condition, block, negated: true);
    node.body.accept(this);
    if (node.variables.any((v) => closures.captures.containsKey(v))) {
      w.Local oldContext = context!.currentLocal;
      allocateContext(node);
      w.Local newContext = context.currentLocal;
      for (VariableDeclaration variable in node.variables) {
        Capture? capture = closures.captures[variable];
        if (capture != null) {
          b.local_get(oldContext);
          b.struct_get(context.struct, capture.fieldIndex);
          b.local_get(newContext);
          b.struct_set(context.struct, capture.fieldIndex);
        }
      }
    } else {
      allocateContext(node);
    }
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
    } else {
      translator.convertType(function, voidMarker, returnType);
    }
    for (Statement finalizer in finalizers.reversed) {
      finalizer.accept(this);
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
    w.Local temp = function.addLocal(
        typeForLocal(w.RefType.def(info.repr.struct, nullable: false)));
    b.global_get(info.rtt);
    b.struct_new_default_with_rtt(info.struct);
    b.local_tee(temp);
    b.local_get(temp);
    b.i32_const(info.classId);
    b.struct_set(info.struct, 0);
    if (options.parameterNullability && temp.type.nullable) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments, node.targetReference, 1);
    _call(node.targetReference);
    if (bodyAnalyzer.preserved.contains(node)) {
      b.local_get(temp);
    }
  }

  void visitStaticInvocation(StaticInvocation node) {
    _visitArguments(node.arguments, node.targetReference, 0);
    _call(node.targetReference);
  }

  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    b.local_get(thisLocal!);
    if (options.parameterNullability && thisLocal!.type.nullable) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments, node.interfaceTargetReference!, 1);
    _call(node.interfaceTargetReference!);
  }

  void visitInstanceInvocation(InstanceInvocation node) {
    Procedure target = node.interfaceTarget;
    wrap(node.receiver);
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      _visitArguments(node.arguments, node.interfaceTargetReference, 1);
      _call(singleTarget.reference);
      return;
    }
    _virtualCall(target, () {
      _visitArguments(node.arguments, node.interfaceTargetReference, 1);
    }, getter: false, setter: false);
  }

  void visitEqualsCall(EqualsCall node) {
    // TODO: virtual call
    wrap(node.left);
    wrap(node.right);
    b.ref_eq();
  }

  void visitEqualsNull(EqualsNull node) {
    wrap(node.expression);
    b.ref_is_null();
  }

  void _virtualCall(Member interfaceTarget, void pushArguments(),
      {required bool getter, required bool setter}) {
    int selectorId = getter
        ? translator.tableSelectorAssigner.getterSelectorId(interfaceTarget)
        : translator.tableSelectorAssigner
            .methodOrSetterSelectorId(interfaceTarget);
    SelectorInfo selector = translator.dispatchTable.selectorInfo[selectorId]!;

    int? offset = selector.offset;
    if (offset == null) {
      // Singular target or unreachable call
      assert(selector.targetCount <= 1);
      if (selector.targetCount == 1) {
        pushArguments();
        _call(selector.singularTarget!);
      } else {
        b.unreachable();
      }
      return;
    }

    // Receiver is already on stack.
    w.Local receiver =
        function.addLocal(typeForLocal(selector.signature.inputs.first));
    b.local_tee(receiver);
    if (options.parameterNullability && receiver.type.nullable) {
      b.ref_as_non_null();
    }
    pushArguments();

    if (options.polymorphicSpecialization) {
      return _polymorphicSpecialization(selector, receiver);
    }

    b.local_get(receiver);
    b.struct_get(object.struct, 0);
    if (offset != 0) {
      b.i32_const(offset);
      b.i32_add();
    }
    b.call_indirect(selector.signature);

    translator.functions.activateSelector(selector);
  }

  void _polymorphicSpecialization(SelectorInfo selector, w.Local receiver) {
    Map<int, Reference> implementations = Map.from(selector.targets);
    implementations.removeWhere((id, target) => target.asMember.isAbstract);

    w.Local idVar = function.addLocal(w.NumType.i32);
    b.local_get(receiver);
    b.struct_get(object.struct, 0);
    b.local_set(idVar);

    w.Label block =
        b.block(selector.signature.inputs, selector.signature.outputs);
    calls:
    while (Set.from(implementations.values).length > 1) {
      for (int id in implementations.keys) {
        Reference target = implementations[id]!;
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
      Reference target = implementations[sorted.first]!;
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
    Reference target = implementations.values.first;
    _call(target);
    b.end();
  }

  @override
  void visitVariableGet(VariableGet node) {
    w.Local? local = locals[node.variable];
    Capture? capture = closures.captures[node.variable];
    if (capture != null) {
      if (!capture.written && local != null) {
        b.local_get(local);
      } else {
        b.local_get(capture.context.currentLocal);
        b.struct_get(capture.context.struct, capture.fieldIndex);
      }
    } else {
      if (local == null) {
        throw "Read of undefined variable ${node.variable}";
      }
      b.local_get(local);
    }
  }

  @override
  void visitVariableSet(VariableSet node) {
    w.Local? local = locals[node.variable];
    Capture? capture = closures.captures[node.variable];
    bool preserved = bodyAnalyzer.preserved.contains(node);
    if (capture != null) {
      assert(capture.written);
      b.local_get(capture.context.currentLocal);
      wrap(node.value);
      if (preserved) {
        w.Local temp =
            function.addLocal(typeForLocal(translateType(node.variable.type)));
        b.local_tee(temp);
        b.struct_set(capture.context.struct, capture.fieldIndex);
        b.local_get(temp);
      } else {
        b.struct_set(capture.context.struct, capture.fieldIndex);
      }
    } else {
      if (local == null) {
        throw "Write of undefined variable ${node.variable}";
      }
      wrap(node.value);
      if (preserved) {
        b.local_tee(local);
      } else {
        b.local_set(local);
      }
    }
  }

  @override
  void visitStaticGet(StaticGet node) {
    Member target = node.target;
    if (target is Field) {
      w.Global global = translator.globals.getGlobal(target);
      b.global_get(global);
    } else {
      _call(target.reference);
    }
  }

  @override
  void visitStaticSet(StaticSet node) {
    bool preserved = bodyAnalyzer.preserved.contains(node);
    w.Local? temp = preserved
        ? function
            .addLocal(translateType(node.value.getStaticType(typeContext)))
        : null;
    wrap(node.value);
    if (preserved) {
      b.local_tee(temp!);
    }
    Member target = node.target;
    if (target is Field) {
      w.Global global = translator.globals.getGlobal(target);
      b.global_set(global);
    } else {
      _call(target.reference);
    }
    if (preserved) {
      b.local_get(temp!);
    }
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    wrap(node.receiver);
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      if (singleTarget is Field) {
        w.StructType struct =
            translator.classInfo[singleTarget.enclosingClass]!.struct;
        int fieldIndex = translator.fieldIndex[singleTarget]!;
        b.struct_get(struct, fieldIndex);
      } else {
        assert(singleTarget is Procedure && singleTarget.isGetter);
        _call(singleTarget.reference);
      }
    } else {
      _virtualCall(node.interfaceTarget, () {}, getter: true, setter: false);
    }
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    wrap(node.receiver);
    bool preserved = bodyAnalyzer.preserved.contains(node);
    w.Local? temp = preserved
        ? function
            .addLocal(translateType(node.value.getStaticType(typeContext)))
        : null;
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      wrap(node.value);
      if (preserved) b.local_tee(temp!);
      if (singleTarget is Field) {
        w.StructType struct =
            translator.classInfo[singleTarget.enclosingClass]!.struct;
        int fieldIndex = translator.fieldIndex[singleTarget]!;
        b.struct_set(struct, fieldIndex);
      } else {
        _call(singleTarget.reference);
      }
    } else {
      _virtualCall(node.interfaceTarget, () {
        wrap(node.value);
        if (preserved) b.local_tee(temp!);
      }, getter: false, setter: true);
    }
    if (preserved) b.local_get(temp!);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    Capture? capture = closures.captures[node.variable];
    bool locallyClosurized = closures.closurizedFunctions.contains(node);
    if (capture != null || locallyClosurized) {
      if (capture != null) {
        b.local_get(capture.context.currentLocal);
      }
      w.StructType struct = _instantiateClosure(node.function);
      if (locallyClosurized) {
        w.Local local = function
            .addLocal(typeForLocal(w.RefType.def(struct, nullable: false)));
        locals[node.variable] = local;
        if (capture != null) {
          b.local_tee(local);
        } else {
          b.local_set(local);
        }
      }
      if (capture != null) {
        b.struct_set(capture.context.struct, capture.fieldIndex);
      }
    }
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    _instantiateClosure(node.function);
  }

  w.StructType _instantiateClosure(FunctionNode functionNode) {
    int parameterCount = functionNode.requiredParameterCount;
    Lambda lambda = closures.lambdas[functionNode]!;
    w.DefinedGlobal global = translator.makeFunctionRef(lambda.function);

    ClassInfo info = translator.classInfo[translator.functionClass]!;
    w.StructType struct = translator.functionStructType(parameterCount);
    w.DefinedGlobal rtt = translator.functionTypeRtt[parameterCount]!;

    b.i32_const(info.classId);
    _pushContext(functionNode);
    b.global_get(global);
    b.global_get(rtt);
    b.struct_new_with_rtt(struct);

    return struct;
  }

  void _pushContext(FunctionNode functionNode) {
    Context? context = closures.contexts[functionNode]?.parent;
    if (context != null) {
      b.local_get(context.currentLocal);
      if (context.currentLocal.type.nullable) {
        b.ref_as_non_null();
      }
    } else {
      // TODO: Put dummy context in global variable
      b.rtt_canon(translator.dummyContext);
      b.struct_new_with_rtt(translator.dummyContext);
    }
  }

  @override
  void visitFunctionInvocation(FunctionInvocation node) {
    FunctionType functionType = node.functionType!;
    int parameterCount = functionType.requiredParameterCount;
    w.StructType struct = translator.functionStructType(parameterCount);
    w.Local temp = function.addLocal(typeForLocal(translateType(functionType)));
    wrap(node.receiver);
    b.local_tee(temp);
    b.struct_get(struct, 1); // Context
    for (Expression arg in node.arguments.positional) {
      wrap(arg);
    }
    b.local_get(temp);
    b.struct_get(struct, 2); // Function
    b.call_ref();
  }

  @override
  void visitLocalFunctionInvocation(LocalFunctionInvocation node) {
    var decl = node.variable.parent as FunctionDeclaration;
    _pushContext(decl.function);
    for (Expression arg in node.arguments.positional) {
      wrap(arg);
    }
    Lambda lambda = closures.lambdas[decl.function]!;
    b.call(lambda.function);
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
    _conditional(node.condition, node.then, node.otherwise,
        [if (type != null && type != voidMarker) type]);
  }

  void visitNullCheck(NullCheck node) {
    wrap(node.operand);
  }

  void _visitArguments(Arguments node, Reference target, int signatureOffset) {
    final w.FunctionType signature = translator.signatureFor(target);
    final ParameterInfo paramInfo = translator.paramInfoFor(target);
    for (Expression arg in node.positional) {
      wrap(arg);
    }
    // Default values for positional parameters
    for (int i = node.positional.length; i < paramInfo.positional.length; i++) {
      final w.ValueType type = signature.inputs[signatureOffset + i];
      translator.constants
          .instantiateConstant(function, paramInfo.positional[i]!, type);
    }
    // Named arguments
    final Map<String, w.Local> namedLocals = {};
    for (var namedArg in node.named) {
      final w.ValueType type = signature
          .inputs[signatureOffset + paramInfo.nameIndex[namedArg.name]!];
      final w.Local namedLocal = function.addLocal(typeForLocal(type));
      namedLocals[namedArg.name] = namedLocal;
      wrap(namedArg.value);
      b.local_set(namedLocal);
    }
    for (String name in paramInfo.names) {
      w.Local? namedLocal = namedLocals[name];
      final w.ValueType type =
          signature.inputs[signatureOffset + paramInfo.nameIndex[name]!];
      if (namedLocal != null) {
        b.local_get(namedLocal);
        translator.convertType(function, namedLocal.type, type);
      } else {
        translator.constants
            .instantiateConstant(function, paramInfo.named[name]!, type);
      }
    }
  }

  void visitStringConcatenation(StringConcatenation node) {
    // TODO: Call toString and concatenate
    for (Expression expression in node.expressions) {
      wrap(expression);
      b.drop();
    }
    ClassInfo info = translator.classInfo[translator.coreTypes.stringClass]!;
    b.i32_const(info.classId);
    b.global_get(info.rtt);
    b.struct_new_with_rtt(info.struct);
  }

  void visitThrow(Throw node) {
    wrap(node.expression);
    // TODO: Throw exception
    b.unreachable();
  }

  void visitConstantExpression(ConstantExpression node) {
    translator.constants.instantiateConstant(
        function, node.constant, bodyAnalyzer.expressionType[node]);
  }

  void visitNullLiteral(NullLiteral node) {
    translator.constants.instantiateConstant(
        function, NullConstant(), bodyAnalyzer.expressionType[node]);
  }

  void visitStringLiteral(StringLiteral node) {
    translator.constants
        .instantiateConstant(function, StringConstant(node.value), null);
  }

  void visitBoolLiteral(BoolLiteral node) {
    b.i32_const(node.value ? 1 : 0);
  }

  void visitIntLiteral(IntLiteral node) {
    b.i64_const(node.value);
  }

  void visitDoubleLiteral(DoubleLiteral node) {
    b.f64_const(node.value);
  }

  void visitIsExpression(IsExpression node) {
    DartType type = node.type;
    if (type is! InterfaceType) throw "Unsupported type in 'is' check: $type";
    Class? singular = null;
    for (Class subclass in translator.subtypes.getSubtypesOf(type.classNode)) {
      if (!subclass.isAbstract) {
        if (singular != null) {
          throw "Only supports 'is' check with singular concrete subclass";
        }
        singular = subclass;
      }
    }
    wrap(node.operand);
    if (singular == null) {
      b.drop();
      b.i32_const(0);
      return;
    }
    ClassInfo info = translator.classInfo[singular]!;
    b.struct_get(object.struct, 0);
    b.i32_const(info.classId);
    b.i32_eq();
  }

  void visitAsExpression(AsExpression node) {
    wrap(node.operand);
    // TODO: Check
  }
}

class StubBodyTraversal extends RecursiveVisitor {
  final CodeGenerator codeGen;

  StubBodyTraversal(this.codeGen);

  Translator get translator => codeGen.translator;

  void visitRedirectingInitializer(RedirectingInitializer node) {
    super.visitRedirectingInitializer(node);
    _call(node.targetReference);
  }

  void visitSuperInitializer(SuperInitializer node) {
    super.visitSuperInitializer(node);
    if ((node.parent as Constructor).enclosingClass.superclass?.superclass ==
        null) {
      return;
    }
    _call(node.targetReference);
  }

  void visitConstructorInvocation(ConstructorInvocation node) {
    super.visitConstructorInvocation(node);
    _call(node.targetReference);
  }

  void visitStaticInvocation(StaticInvocation node) {
    super.visitStaticInvocation(node);
    _call(node.targetReference);
  }

  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    super.visitSuperMethodInvocation(node);
    _call(node.interfaceTargetReference!);
  }

  void visitInstanceInvocation(InstanceInvocation node) {
    super.visitInstanceInvocation(node);
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      _call(singleTarget.reference);
    } else {
      _virtualCall(node.interfaceTarget, getter: false, setter: false);
    }
  }

  void visitEqualsCall(EqualsCall node) {
    super.visitEqualsCall(node);
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      _call(singleTarget.reference);
    } else {
      _virtualCall(node.interfaceTarget, getter: false, setter: false);
    }
  }

  @override
  void visitStaticGet(StaticGet node) {
    super.visitStaticGet(node);
    Member target = node.target;
    if (target is Procedure) {
      _call(target.reference);
    }
  }

  @override
  void visitStaticSet(StaticSet node) {
    super.visitStaticSet(node);
    Member target = node.target;
    if (target is Procedure) {
      _call(target.reference);
    }
  }

  @override
  void visitInstanceGet(InstanceGet node) {
    super.visitInstanceGet(node);
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      if (singleTarget is Procedure) {
        _call(singleTarget.reference);
      }
    } else {
      _virtualCall(node.interfaceTarget, getter: true, setter: false);
    }
  }

  @override
  void visitInstanceSet(InstanceSet node) {
    super.visitInstanceSet(node);
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      if (singleTarget is Procedure) {
        _call(singleTarget.reference);
      }
    } else {
      _virtualCall(node.interfaceTarget, getter: false, setter: true);
    }
  }

  void _call(Reference target) {
    if (!target.asMember.isAbstract) {
      translator.functions.getFunction(target);
    }
  }

  void _virtualCall(Member interfaceTarget,
      {required bool getter, required bool setter}) {
    int selectorId = getter
        ? translator.tableSelectorAssigner.getterSelectorId(interfaceTarget)
        : translator.tableSelectorAssigner
            .methodOrSetterSelectorId(interfaceTarget);
    SelectorInfo selector = translator.dispatchTable.selectorInfo[selectorId]!;
    translator.functions.activateSelector(selector);
  }
}
