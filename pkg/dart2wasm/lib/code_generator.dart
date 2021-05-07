// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/closures.dart';
import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/intrinsics.dart';
import 'package:dart2wasm/param_info.dart';
import 'package:dart2wasm/tearoff_reference.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/type_environment.dart';
import 'package:kernel/visitor.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class CodeGenerator extends ExpressionVisitor1<w.ValueType, w.ValueType>
    implements InitializerVisitor<void>, StatementVisitor<void> {
  final Translator translator;
  final w.ValueType voidMarker;
  late final Intrinsifier intrinsifier;

  late Member member;
  late w.DefinedFunction function;
  late StaticTypeContext typeContext;
  late List<w.Local> paramLocals;
  w.Label? returnLabel;
  late w.ValueType returnType;

  late Closures closures;

  Map<VariableDeclaration, w.Local> locals = {};
  w.Local? thisLocal;
  w.Local? preciseThisLocal;
  List<Statement> finalizers = [];

  late w.Instructions b;

  CodeGenerator(this.translator) : voidMarker = translator.voidMarker {
    intrinsifier = Intrinsifier(this);
  }

  TranslatorOptions get options => translator.options;

  ClassInfo get object => translator.classes[0];

  w.ValueType translateType(DartType type) => translator.translateType(type);

  w.ValueType typeForLocal(w.ValueType type) => translator.typeForLocal(type);

  @override
  void defaultInitializer(Initializer node) {
    throw "Not supported: ${node.runtimeType}";
  }

  @override
  w.ValueType defaultExpression(Expression node, w.ValueType expectedType) {
    throw "Not supported: ${node.runtimeType}";
  }

  @override
  void defaultStatement(Statement node) {
    throw "Not supported: ${node.runtimeType}";
  }

  void generate(Reference reference, w.DefinedFunction function,
      {List<w.Local>? inlinedLocals, w.Label? returnLabel}) {
    closures = Closures(this);

    Member member = reference.asMember;
    b = function.body;

    if (reference.isTearOffReference) {
      w.DefinedFunction closureFunction =
          translator.getTearOffFunction(member as Procedure);

      int parameterCount = member.function.requiredParameterCount;
      w.DefinedGlobal global = translator.makeFunctionRef(closureFunction);

      ClassInfo info = translator.classInfo[translator.functionClass]!;
      w.StructType struct = translator.functionStructType(parameterCount);
      w.DefinedGlobal rtt = translator.functionTypeRtt[parameterCount]!;

      b.i32_const(info.classId);
      b.local_get(function.locals[0]);
      b.global_get(global);
      b.global_get(rtt);
      b.struct_new_with_rtt(struct);
      b.end();
      return;
    }

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

    if (implicitParams == 1) {
      ClassInfo info = translator.classInfo[member.enclosingClass]!;
      thisLocal = paramLocals[0];
      w.RefType thisType = w.RefType.def(info.repr.struct, nullable: false);
      if (translator.needsConversion(paramLocals[0].type, thisType)) {
        preciseThisLocal = function.addLocal(typeForLocal(thisType));
        b.local_get(paramLocals[0]);
        b.global_get(info.rtt);
        b.ref_cast();
        b.local_set(preciseThisLocal!);
      } else {
        preciseThisLocal = paramLocals[0];
      }

      if (member is Constructor) {
        if (!options.stubBodies) {
          Class cls = member.enclosingClass;
          for (Field field in cls.fields) {
            if (field.isInstanceMember && field.initializer != null) {
              int fieldIndex = translator.fieldIndex[field]!;
              b.local_get(thisLocal!);
              wrap(field.initializer!,
                  info.struct.fields[fieldIndex].type.unpacked);
              b.struct_set(info.struct, fieldIndex);
            }
          }
          for (Initializer initializer in member.initializers) {
            initializer.accept(this);
          }
        }
      }
    } else {
      thisLocal = null;
      preciseThisLocal = null;
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
      } else {
        // This point is unreachable, but the Wasm validator still expects the
        // stack to contain a value matching the Wasm function return type.
        b.block(const [], function.type.outputs);
        b.unreachable();
        b.end();
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
        preciseThisLocal = thisLocal;
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
        b.local_get(preciseThisLocal!);
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
        translator.convertType(function, local.type, capture.type);
        b.struct_set(capture.context.struct, capture.fieldIndex);
      }
    });
  }

  w.ValueType wrap(Expression node, w.ValueType expectedType) {
    w.ValueType resultType = node.accept1(this, expectedType);
    translator.convertType(function, resultType, expectedType);
    return expectedType;
  }

  w.ValueType _call(Reference target) {
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
    return translator.outputOrVoid(targetFunction.type.outputs);
  }

  @override
  void visitInvalidInitializer(InvalidInitializer node) {}

  @override
  void visitAssertInitializer(AssertInitializer node) {}

  @override
  void visitLocalInitializer(LocalInitializer node) {
    node.variable.accept(this);
  }

  @override
  void visitFieldInitializer(FieldInitializer node) {
    w.StructType struct = translator
        .classInfo[(node.parent as Constructor).enclosingClass]!.struct;
    int fieldIndex = translator.fieldIndex[node.field]!;

    b.local_get(thisLocal!);
    wrap(node.value, struct.fields[fieldIndex].type.unpacked);
    b.struct_set(struct, fieldIndex);
  }

  @override
  void visitRedirectingInitializer(RedirectingInitializer node) {
    b.local_get(thisLocal!);
    if (options.parameterNullability && thisLocal!.type.nullable) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments, node.targetReference, 1);
    _call(node.targetReference);
  }

  @override
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

  @override
  void visitBlock(Block node) {
    for (Statement statement in node.statements) {
      statement.accept(this);
    }
  }

  @override
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
        wrap(node.initializer!, capture.type);
        if (!capture.written) {
          b.local_tee(local!);
        }
        b.struct_set(capture.context.struct, capture.fieldIndex);
      } else {
        wrap(node.initializer!, local!.type);
        b.local_set(local);
      }
    }
  }

  @override
  void visitEmptyStatement(EmptyStatement node) {}

  @override
  void visitAssertStatement(AssertStatement node) {}

  @override
  void visitAssertBlock(AssertBlock node) {}

  @override
  void visitTryCatch(TryCatch node) {
    // TODO: Include catches
    node.body.accept(this);
  }

  @override
  void visitTryFinally(TryFinally node) {
    finalizers.add(node.finalizer);
    node.body.accept(this);
    finalizers.removeLast().accept(this);
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    wrap(node.expression, voidMarker);
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
      wrap(condition!, w.NumType.i32);
      if (negated) {
        b.i32_eqz();
      }
      b.br_if(target);
    }
  }

  void _conditional(Expression condition, void then(), void otherwise()?,
      List<w.ValueType> result) {
    if (!_hasLogicalOperator(condition)) {
      // Simple condition
      wrap(condition, w.NumType.i32);
      b.if_(const [], result);
      then();
      if (otherwise != null) {
        b.else_();
        otherwise();
      }
      b.end();
    } else {
      // Complex condition
      w.Label ifBlock = b.block(const [], result);
      if (otherwise != null) {
        w.Label elseBlock = b.block();
        _branchIf(condition, elseBlock, negated: true);
        then();
        b.br(ifBlock);
        b.end();
        otherwise();
      } else {
        _branchIf(condition, ifBlock, negated: true);
        then();
      }
      b.end();
    }
  }

  @override
  void visitIfStatement(IfStatement node) {
    _conditional(
        node.condition,
        () => node.then.accept(this),
        node.otherwise != null ? () => node.otherwise!.accept(this) : null,
        const []);
  }

  @override
  void visitDoStatement(DoStatement node) {
    w.Label loop = b.loop();
    allocateContext(node);
    node.body.accept(this);
    _branchIf(node.condition, loop, negated: false);
    b.end();
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    w.Label block = b.block();
    w.Label loop = b.loop();
    _branchIf(node.condition, block, negated: true);
    allocateContext(node);
    node.body.accept(this);
    b.br(loop);
    b.end();
    b.end();
  }

  @override
  void visitForStatement(ForStatement node) {
    Context? context = closures.contexts[node];
    allocateContext(node);
    for (VariableDeclaration variable in node.variables) {
      variable.accept(this);
    }
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
      wrap(update, voidMarker);
    }
    b.br(loop);
    b.end();
    b.end();
  }

  @override
  void visitForInStatement(ForInStatement node) {
    throw "ForInStatement should have been desugared: $node";
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    Expression? expression = node.expression;
    if (expression != null) {
      wrap(expression, returnType);
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

  @override
  void visitLabeledStatement(LabeledStatement node) => defaultStatement(node);
  @override
  void visitBreakStatement(BreakStatement node) => defaultStatement(node);
  @override
  void visitSwitchStatement(SwitchStatement node) => defaultStatement(node);
  @override
  void visitContinueSwitchStatement(ContinueSwitchStatement node) =>
      defaultStatement(node);
  @override
  void visitYieldStatement(YieldStatement node) => defaultStatement(node);

  @override
  w.ValueType visitBlockExpression(
      BlockExpression node, w.ValueType expectedType) {
    node.body.accept(this);
    return wrap(node.value, expectedType);
  }

  @override
  w.ValueType visitLet(Let node, w.ValueType expectedType) {
    node.variable.accept(this);
    return wrap(node.body, expectedType);
  }

  @override
  w.ValueType visitThisExpression(
      ThisExpression node, w.ValueType expectedType) {
    return _visitThis(expectedType);
  }

  w.ValueType _visitThis(w.ValueType expectedType) {
    if (!thisLocal!.type.isSubtypeOf(expectedType) &&
        preciseThisLocal!.type.isSubtypeOf(expectedType)) {
      b.local_get(preciseThisLocal!);
      return preciseThisLocal!.type;
    } else {
      b.local_get(thisLocal!);
      return thisLocal!.type;
    }
  }

  @override
  w.ValueType visitConstructorInvocation(
      ConstructorInvocation node, w.ValueType expectedType) {
    ClassInfo info = translator.classInfo[node.target.enclosingClass]!;
    w.Local temp = function
        .addLocal(typeForLocal(w.RefType.def(info.struct, nullable: false)));
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
    if (expectedType != voidMarker) {
      b.local_get(temp);
      return temp.type;
    } else {
      return voidMarker;
    }
  }

  @override
  w.ValueType visitStaticInvocation(
      StaticInvocation node, w.ValueType expectedType) {
    w.ValueType? intrinsicResult = intrinsifier.getStaticIntrinsic(node);
    if (intrinsicResult != null) return intrinsicResult;
    _visitArguments(node.arguments, node.targetReference, 0);
    return _call(node.targetReference);
  }

  @override
  w.ValueType visitSuperMethodInvocation(
      SuperMethodInvocation node, w.ValueType expectedType) {
    w.ValueType thisType = _visitThis(expectedType);
    if (options.parameterNullability && thisType.nullable) {
      b.ref_as_non_null();
    }
    _visitArguments(node.arguments, node.interfaceTargetReference!, 1);
    return _call(node.interfaceTargetReference!);
  }

  @override
  w.ValueType visitInstanceInvocation(
      InstanceInvocation node, w.ValueType expectedType) {
    w.ValueType? intrinsicResult = intrinsifier.getInstanceIntrinsic(node);
    if (intrinsicResult != null) return intrinsicResult;
    Procedure target = node.interfaceTarget;
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      w.BaseFunction targetFunction =
          translator.functions.getFunction(singleTarget.reference);
      wrap(node.receiver, targetFunction.type.inputs.first);
      _visitArguments(node.arguments, node.interfaceTargetReference, 1);
      return _call(singleTarget.reference);
    }
    return _virtualCall(target, node.receiver, (_) {
      _visitArguments(node.arguments, node.interfaceTargetReference, 1);
    }, getter: false, setter: false);
  }

  @override
  w.ValueType visitEqualsCall(EqualsCall node, w.ValueType expectedType) {
    w.ValueType? intrinsicResult = intrinsifier.getEqualsIntrinsic(node);
    if (intrinsicResult != null) return intrinsicResult;
    // TODO: virtual call
    wrap(node.left, translator.nullableObjectType);
    wrap(node.right, translator.nullableObjectType);
    b.ref_eq();
    return w.NumType.i32;
  }

  @override
  w.ValueType visitEqualsNull(EqualsNull node, w.ValueType expectedType) {
    wrap(node.expression, translator.nullableObjectType);
    b.ref_is_null();
    return w.NumType.i32;
  }

  w.ValueType _virtualCall(Member interfaceTarget, Expression receiver,
      void pushArguments(w.FunctionType signature),
      {required bool getter, required bool setter}) {
    int selectorId = getter
        ? translator.tableSelectorAssigner.getterSelectorId(interfaceTarget)
        : translator.tableSelectorAssigner
            .methodOrSetterSelectorId(interfaceTarget);
    SelectorInfo selector = translator.dispatchTable.selectorInfo[selectorId]!;

    wrap(receiver, selector.signature.inputs.first);

    int? offset = selector.offset;
    if (offset == null) {
      // Singular target or unreachable call
      assert(selector.targetCount <= 1);
      if (selector.targetCount == 1) {
        pushArguments(selector.signature);
        return _call(selector.singularTarget!);
      } else {
        b.unreachable();
        return translator.nonNullableObjectType;
      }
    }

    // Receiver is already on stack.
    w.Local receiverVar =
        function.addLocal(typeForLocal(selector.signature.inputs.first));
    b.local_tee(receiverVar);
    if (options.parameterNullability && receiverVar.type.nullable) {
      b.ref_as_non_null();
    }
    pushArguments(selector.signature);

    if (options.polymorphicSpecialization) {
      _polymorphicSpecialization(selector, receiverVar);
    } else {
      b.local_get(receiverVar);
      b.struct_get(object.struct, 0);
      if (offset != 0) {
        b.i32_const(offset);
        b.i32_add();
      }
      b.call_indirect(selector.signature);

      translator.functions.activateSelector(selector);
    }

    return translator.outputOrVoid(selector.signature.outputs);
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
  w.ValueType visitVariableGet(VariableGet node, w.ValueType expectedType) {
    w.Local? local = locals[node.variable];
    Capture? capture = closures.captures[node.variable];
    if (capture != null) {
      if (!capture.written && local != null) {
        b.local_get(local);
        return local.type;
      } else {
        b.local_get(capture.context.currentLocal);
        b.struct_get(capture.context.struct, capture.fieldIndex);
        return capture.type;
      }
    } else {
      if (local == null) {
        throw "Read of undefined variable ${node.variable}";
      }
      b.local_get(local);
      return local.type;
    }
  }

  @override
  w.ValueType visitVariableSet(VariableSet node, w.ValueType expectedType) {
    w.Local? local = locals[node.variable];
    Capture? capture = closures.captures[node.variable];
    bool preserved = expectedType != voidMarker;
    if (capture != null) {
      assert(capture.written);
      b.local_get(capture.context.currentLocal);
      wrap(node.value, capture.type);
      if (preserved) {
        w.Local temp =
            function.addLocal(typeForLocal(translateType(node.variable.type)));
        b.local_tee(temp);
        b.struct_set(capture.context.struct, capture.fieldIndex);
        b.local_get(temp);
        return temp.type;
      } else {
        b.struct_set(capture.context.struct, capture.fieldIndex);
        return capture.type;
      }
    } else {
      if (local == null) {
        throw "Write of undefined variable ${node.variable}";
      }
      wrap(node.value, local.type);
      if (preserved) {
        b.local_tee(local);
        return local.type;
      } else {
        b.local_set(local);
        return voidMarker;
      }
    }
  }

  @override
  w.ValueType visitStaticGet(StaticGet node, w.ValueType expectedType) {
    Member target = node.target;
    if (target is Field) {
      w.Global global = translator.globals.getGlobal(target);
      b.global_get(global);
      return global.type.type;
    } else {
      return _call(target.reference);
    }
  }

  @override
  w.ValueType visitStaticTearOff(StaticTearOff node, w.ValueType expectedType) {
    translator.constants.instantiateConstant(
        function, TearOffConstant(node.target), expectedType);
    return expectedType;
  }

  @override
  w.ValueType visitStaticSet(StaticSet node, w.ValueType expectedType) {
    bool preserved = expectedType != voidMarker;
    Member target = node.target;
    if (target is Field) {
      w.Global global = translator.globals.getGlobal(target);
      wrap(node.value, global.type.type);
      b.global_set(global);
      if (preserved) {
        b.global_get(global);
        return global.type.type;
      } else {
        return voidMarker;
      }
    } else {
      w.BaseFunction targetFunction =
          translator.functions.getFunction(target.reference);
      wrap(node.value, targetFunction.type.inputs.single);
      w.Local? temp;
      if (preserved) {
        temp = function
            .addLocal(translateType(node.value.getStaticType(typeContext)));
        b.local_tee(temp);
      }
      _call(target.reference);
      if (preserved) {
        b.local_get(temp!);
        return temp.type;
      } else {
        return voidMarker;
      }
    }
  }

  @override
  w.ValueType visitInstanceGet(InstanceGet node, w.ValueType expectedType) {
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      if (singleTarget is Field) {
        w.StructType struct =
            translator.classInfo[singleTarget.enclosingClass]!.struct;
        int fieldIndex = translator.fieldIndex[singleTarget]!;
        w.ValueType receiverType = w.RefType.def(struct, nullable: true);
        w.ValueType fieldType = struct.fields[fieldIndex].type.unpacked;
        wrap(node.receiver, receiverType);
        b.struct_get(struct, fieldIndex);
        return fieldType;
      } else {
        // Instance call of getter
        assert(singleTarget is Procedure && singleTarget.isGetter);
        w.ValueType? intrinsicResult =
            intrinsifier.getInstanceGetterIntrinsic(node);
        if (intrinsicResult != null) return intrinsicResult;
        w.BaseFunction targetFunction =
            translator.functions.getFunction(singleTarget.reference);
        wrap(node.receiver, targetFunction.type.inputs.single);
        return _call(singleTarget.reference);
      }
    } else {
      return _virtualCall(node.interfaceTarget, node.receiver, (_) {},
          getter: true, setter: false);
    }
  }

  @override
  w.ValueType visitInstanceTearOff(
      InstanceTearOff node, w.ValueType expectedType) {
    return _virtualCall(node.interfaceTarget, node.receiver, (_) {},
        getter: true, setter: false);
  }

  @override
  w.ValueType visitInstanceSet(InstanceSet node, w.ValueType expectedType) {
    bool preserved = expectedType != voidMarker;
    w.Local? temp;
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      if (singleTarget is Field) {
        w.StructType struct =
            translator.classInfo[singleTarget.enclosingClass]!.struct;
        int fieldIndex = translator.fieldIndex[singleTarget]!;
        w.ValueType receiverType = w.RefType.def(struct, nullable: true);
        w.ValueType fieldType = struct.fields[fieldIndex].type.unpacked;
        wrap(node.receiver, receiverType);
        wrap(node.value, fieldType);
        if (preserved) {
          temp = function.addLocal(fieldType);
          b.local_tee(temp);
        }
        b.struct_set(struct, fieldIndex);
      } else {
        w.BaseFunction targetFunction =
            translator.functions.getFunction(singleTarget.reference);
        w.ValueType paramType = targetFunction.type.inputs.last;
        wrap(node.receiver, targetFunction.type.inputs.first);
        wrap(node.value, paramType);
        if (preserved) {
          temp = function.addLocal(typeForLocal(paramType));
          b.local_tee(temp);
          translator.convertType(function, temp.type, paramType);
        }
        _call(singleTarget.reference);
      }
    } else {
      _virtualCall(node.interfaceTarget, node.receiver, (signature) {
        w.ValueType paramType = signature.inputs.last;
        wrap(node.value, paramType);
        if (preserved) {
          temp = function.addLocal(paramType);
          b.local_tee(temp!);
        }
      }, getter: false, setter: true);
    }
    if (preserved) {
      b.local_get(temp!);
      return temp!.type;
    } else {
      return voidMarker;
    }
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
  w.ValueType visitFunctionExpression(
      FunctionExpression node, w.ValueType expectedType) {
    w.StructType struct = _instantiateClosure(node.function);
    return w.RefType.def(struct, nullable: false);
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
  w.ValueType visitFunctionInvocation(
      FunctionInvocation node, w.ValueType expectedType) {
    FunctionType functionType = node.functionType!;
    int parameterCount = functionType.requiredParameterCount;
    w.StructType struct = translator.functionStructType(parameterCount);
    w.Local temp = function.addLocal(typeForLocal(translateType(functionType)));
    wrap(node.receiver, temp.type);
    b.local_tee(temp);
    b.struct_get(struct, 1); // Context
    for (Expression arg in node.arguments.positional) {
      wrap(arg, translator.nullableObjectType);
    }
    b.local_get(temp);
    b.struct_get(struct, 2); // Function
    b.call_ref();
    return translator.nullableObjectType;
  }

  @override
  w.ValueType visitLocalFunctionInvocation(
      LocalFunctionInvocation node, w.ValueType expectedType) {
    var decl = node.variable.parent as FunctionDeclaration;
    _pushContext(decl.function);
    for (Expression arg in node.arguments.positional) {
      wrap(arg, translator.nullableObjectType);
    }
    Lambda lambda = closures.lambdas[decl.function]!;
    b.call(lambda.function);
    return translator.nullableObjectType;
  }

  @override
  w.ValueType visitLogicalExpression(
      LogicalExpression node, w.ValueType expectedType) {
    _conditional(node, () => b.i32_const(1), () => b.i32_const(0),
        const [w.NumType.i32]);
    return w.NumType.i32;
  }

  @override
  w.ValueType visitNot(Not node, w.ValueType expectedType) {
    wrap(node.operand, w.NumType.i32);
    b.i32_eqz();
    return w.NumType.i32;
  }

  @override
  w.ValueType visitConditionalExpression(
      ConditionalExpression node, w.ValueType expectedType) {
    _conditional(
        node.condition,
        () => wrap(node.then, expectedType),
        () => wrap(node.otherwise, expectedType),
        [if (expectedType != voidMarker) expectedType]);
    return expectedType;
  }

  @override
  w.ValueType visitNullCheck(NullCheck node, w.ValueType expectedType) {
    // TODO: Check and throw exception
    return wrap(node.operand, expectedType);
  }

  void _visitArguments(Arguments node, Reference target, int signatureOffset) {
    final w.FunctionType signature = translator.signatureFor(target);
    final ParameterInfo paramInfo = translator.paramInfoFor(target);
    for (int i = 0; i < node.positional.length; i++) {
      wrap(node.positional[i], signature.inputs[signatureOffset + i]);
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
      wrap(namedArg.value, namedLocal.type);
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

  @override
  w.ValueType visitStringConcatenation(
      StringConcatenation node, w.ValueType expectedType) {
    // TODO: Call toString and concatenate
    for (Expression expression in node.expressions) {
      wrap(expression, translator.nullableObjectType);
      b.drop();
    }
    ClassInfo info = translator.classInfo[translator.coreTypes.stringClass]!;
    b.i32_const(info.classId);
    b.global_get(info.rtt);
    b.struct_new_with_rtt(info.struct);
    return w.RefType.def(info.struct, nullable: false);
  }

  @override
  w.ValueType visitThrow(Throw node, w.ValueType expectedType) {
    wrap(node.expression, translator.nullableObjectType);
    // TODO: Throw exception
    b.unreachable();
    return expectedType;
  }

  @override
  w.ValueType visitConstantExpression(
      ConstantExpression node, w.ValueType expectedType) {
    translator.constants
        .instantiateConstant(function, node.constant, expectedType);
    return expectedType;
  }

  @override
  w.ValueType visitNullLiteral(NullLiteral node, w.ValueType expectedType) {
    translator.constants
        .instantiateConstant(function, NullConstant(), expectedType);
    return expectedType;
  }

  @override
  w.ValueType visitStringLiteral(StringLiteral node, w.ValueType expectedType) {
    translator.constants.instantiateConstant(
        function, StringConstant(node.value), expectedType);
    return expectedType;
  }

  @override
  w.ValueType visitBoolLiteral(BoolLiteral node, w.ValueType expectedType) {
    b.i32_const(node.value ? 1 : 0);
    return w.NumType.i32;
  }

  @override
  w.ValueType visitIntLiteral(IntLiteral node, w.ValueType expectedType) {
    b.i64_const(node.value);
    return w.NumType.i64;
  }

  @override
  w.ValueType visitDoubleLiteral(DoubleLiteral node, w.ValueType expectedType) {
    b.f64_const(node.value);
    return w.NumType.f64;
  }

  @override
  w.ValueType visitListLiteral(ListLiteral node, w.ValueType expectedType) {
    ClassInfo info = translator.classInfo[translator.growableListClass]!;
    w.RefType refType = info.struct.fields.last.type.unpacked as w.RefType;
    w.ArrayType arrayType =
        (refType.heapType as w.DefHeapType).def as w.ArrayType;
    w.ValueType elementType = arrayType.elementType.type.unpacked;
    int length = node.expressions.length;

    b.i32_const(info.classId);
    b.i64_const(length);
    b.i32_const(length);
    b.rtt_canon(arrayType);
    b.array_new_default_with_rtt(arrayType);
    if (length > 0) {
      w.Local arrayLocal = function.addLocal(typeForLocal(refType));
      b.local_set(arrayLocal);
      for (int i = 0; i < length; i++) {
        b.local_get(arrayLocal);
        b.i32_const(i);
        wrap(node.expressions[i], elementType);
        b.array_set(arrayType);
      }
      b.local_get(arrayLocal);
      if (arrayLocal.type.nullable) {
        b.ref_as_non_null();
      }
    }
    b.global_get(info.rtt);
    b.struct_new_with_rtt(info.struct);

    return w.RefType.def(info.struct, nullable: false);
  }

  @override
  w.ValueType visitMapLiteral(MapLiteral node, w.ValueType expectedType) {
    w.BaseFunction mapFactory =
        translator.functions.getFunction(translator.mapFactory.reference);
    w.ValueType factoryReturnType = mapFactory.type.outputs.single;
    b.call(mapFactory);
    if (node.entries.isEmpty) {
      return factoryReturnType;
    }
    w.BaseFunction mapPut =
        translator.functions.getFunction(translator.mapPut.reference);
    w.ValueType putReceiverType = mapPut.type.inputs[0];
    w.ValueType putKeyType = mapPut.type.inputs[1];
    w.ValueType putValueType = mapPut.type.inputs[2];
    w.Local mapLocal = function.addLocal(typeForLocal(putReceiverType));
    translator.convertType(function, factoryReturnType, mapLocal.type);
    b.local_set(mapLocal);
    for (MapLiteralEntry entry in node.entries) {
      b.local_get(mapLocal);
      translator.convertType(function, mapLocal.type, putReceiverType);
      wrap(entry.key, putKeyType);
      wrap(entry.value, putValueType);
      b.call(mapPut);
    }
    b.local_get(mapLocal);
    return mapLocal.type;
  }

  @override
  w.ValueType visitIsExpression(IsExpression node, w.ValueType expectedType) {
    wrap(node.operand, translator.nullableObjectType);
    DartType type = node.type;
    if (type is! InterfaceType) {
      // TODO: Check
      b.drop();
      b.i32_const(1);
      return w.NumType.i32;
    }
    if (type.typeArguments.any((t) => t is! DynamicType)) {
      throw "Type test with type arguments not supported";
    }
    List<Class> concrete = translator.subtypes
        .getSubtypesOf(type.classNode)
        .where((c) => !c.isAbstract)
        .toList();
    if (concrete.isEmpty) {
      b.drop();
      b.i32_const(0);
    } else if (concrete.length == 1) {
      ClassInfo info = translator.classInfo[concrete.single]!;
      b.struct_get(object.struct, 0);
      b.i32_const(info.classId);
      b.i32_eq();
    } else {
      w.Local idLocal = function.addLocal(w.NumType.i32);
      b.struct_get(object.struct, 0);
      b.local_set(idLocal);
      w.Label done = b.block([], [w.NumType.i32]);
      b.i32_const(1);
      for (Class cls in concrete) {
        ClassInfo info = translator.classInfo[cls]!;
        b.i32_const(info.classId);
        b.local_get(idLocal);
        b.i32_eq();
        b.br_if(done);
      }
      b.drop();
      b.i32_const(0);
      b.end();
    }
    return w.NumType.i32;
  }

  @override
  w.ValueType visitAsExpression(AsExpression node, w.ValueType expectedType) {
    // TODO: Check
    return wrap(node.operand, expectedType);
  }
}

class StubBodyTraversal extends RecursiveVisitor {
  final CodeGenerator codeGen;

  StubBodyTraversal(this.codeGen);

  Translator get translator => codeGen.translator;

  @override
  void visitRedirectingInitializer(RedirectingInitializer node) {
    super.visitRedirectingInitializer(node);
    _call(node.targetReference);
  }

  @override
  void visitSuperInitializer(SuperInitializer node) {
    super.visitSuperInitializer(node);
    if ((node.parent as Constructor).enclosingClass.superclass?.superclass ==
        null) {
      return;
    }
    _call(node.targetReference);
  }

  @override
  void visitConstructorInvocation(ConstructorInvocation node) {
    super.visitConstructorInvocation(node);
    _call(node.targetReference);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    super.visitStaticInvocation(node);
    _call(node.targetReference);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    super.visitSuperMethodInvocation(node);
    _call(node.interfaceTargetReference!);
  }

  @override
  void visitInstanceInvocation(InstanceInvocation node) {
    super.visitInstanceInvocation(node);
    Member? singleTarget = translator.singleTarget(node);
    if (singleTarget != null) {
      _call(singleTarget.reference);
    } else {
      _virtualCall(node.interfaceTarget, getter: false, setter: false);
    }
  }

  @override
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
