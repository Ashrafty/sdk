// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math';

import 'package:dart2wasm/code_generator.dart';
import 'package:kernel/ast.dart';
import 'package:kernel/text/text_serializer.dart';
import 'package:kernel/visitor.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/intrinsics.dart';
import 'package:dart2wasm/translator.dart';

/// Code generation pre-pass with the following responsibilities:
///
/// - Compare the Wasm type of the value produced by an operation to the Wasm
///   type expected by the consumer of the value to automatically inject boxing,
///   unboxing, null checks and downcasts.
///
/// - Inject drop instructions for value-producing expressions in void context.
///
/// - Mark assignments which occur in non-void context so the code generator
///   knows to leave the value on the stack.
///
/// - Note the expected type of some expressions that need to know it
///   (conditional expressions and null literals/constants).
///
/// - Identify intrinsified calls and inject intrinsic code (via the
///   Intrinsifier).
class BodyAnalyzer extends Visitor<w.ValueType>
    with VisitorThrowingMixin<w.ValueType> {
  CodeGenerator codeGen;
  Translator translator;
  late Intrinsifier intrinsifier;
  w.ValueType voidMarker;

  Set<Expression> preserved = {};
  Map<Expression, CodeGenCallback> inject = {};
  Map<Expression, w.ValueType> expressionType = {};
  bool specializeThis = false;

  w.ValueType expectedType;

  BodyAnalyzer(this.codeGen)
      : translator = codeGen.translator,
        voidMarker = codeGen.translator.voidMarker,
        expectedType = codeGen.translator.voidMarker {
    intrinsifier = Intrinsifier(this);
  }

  void analyzeMember(Member member) {
    if (member is Constructor) {
      Class cls = member.enclosingClass!;
      for (Field field in cls.fields) {
        if (field.isInstanceMember && field.initializer != null) {
          wrapExpression(field.initializer!,
              translateType(field.type).withNullability(true));
        }
      }
      visitList(member.initializers, this);
    }
    member.function!.body!.accept(this);
  }

  w.ValueType translateType(DartType type) {
    return translator.translateType(type);
  }

  w.ValueType typeOfExp(Expression exp) {
    return translateType(exp.getStaticType(codeGen.typeContext));
  }

  w.ValueType wrapExpression(Expression exp, w.ValueType expectedType) {
    this.expectedType = expectedType;
    w.ValueType resultType = exp.accept(this);
    if (resultType == voidMarker || expectedType == voidMarker) {
      assert(resultType != voidMarker || expectedType == voidMarker);
      if (resultType != voidMarker) {
        inject[exp] = (c) {
          exp.accept(c);
          c.b.drop();
        };
      }
      return voidMarker;
    }
    if (!resultType.isSubtypeOf(expectedType)) {
      if (resultType is! w.RefType && expectedType is w.RefType) {
        // Boxing
        var type = exp.getStaticType(codeGen.typeContext) as InterfaceType;
        ClassInfo info = translator.classInfo[type.classNode]!;
        assert(w.HeapType.def(info.struct).isSubtypeOf(expectedType.heapType));
        inject[exp] = (c) {
          c.b.i32_const(info.classId);
          exp.accept(c);
          c.b.global_get(info.rtt);
          c.b.struct_new_with_rtt(info.struct);
        };
      } else if (resultType is w.RefType && expectedType is! w.RefType) {
        // Unboxing
        var type = exp.getStaticType(codeGen.typeContext) as InterfaceType;
        ClassInfo info = translator.classInfo[type.classNode]!;
        assert(w.HeapType.def(info.struct).isSubtypeOf(resultType.heapType));
        inject[exp] = (c) {
          exp.accept(c);
          c.b.struct_get(info.struct, 1);
        };
      } else if (resultType.withNullability(false).isSubtypeOf(expectedType)) {
        // Null check
        inject[exp] = (c) {
          exp.accept(c);
          c.b.ref_as_non_null();
        };
      } else {
        // Downcast
        var heapType = (expectedType as w.RefType).heapType;
        w.Global global = translator.classForHeapType[heapType]!.rtt;
        bool checkNull = resultType.nullable && !expectedType.nullable;
        inject[exp] = (c) {
          exp.accept(c);
          if (checkNull) c.b.ref_as_non_null();
          c.b.global_get(global);
          c.b.ref_cast();
        };
      }
      return expectedType;
    }
    return resultType;
  }

  visitFieldInitializer(FieldInitializer node) {
    return wrapExpression(
        node.value, translateType(node.field.type).withNullability(true));
  }

  visitSuperInitializer(SuperInitializer node) {
    w.BaseFunction? function = translator.functions[node.target];
    if (function != null) {
      return _visitArguments(node.arguments, function.type, 1);
    }
    assert(node.arguments.positional.isEmpty && node.arguments.named.isEmpty);
    return voidMarker;
  }

  visitExpressionStatement(ExpressionStatement node) {
    return wrapExpression(node.expression, voidMarker);
  }

  visitBlock(Block node) {
    visitList(node.statements, this);
    return voidMarker;
  }

  visitEmptyStatement(EmptyStatement node) => voidMarker;

  visitWhileStatement(WhileStatement node) {
    wrapExpression(node.condition, w.NumType.i32);
    node.body.accept(this);
    return voidMarker;
  }

  visitDoStatement(DoStatement node) {
    node.body.accept(this);
    wrapExpression(node.condition, w.NumType.i32);
    return voidMarker;
  }

  visitForStatement(ForStatement node) {
    visitList(node.variables, this);
    if (node.condition != null) {
      wrapExpression(node.condition!, w.NumType.i32);
    }
    for (Expression update in node.updates) {
      wrapExpression(update, voidMarker);
    }
    node.body.accept(this);
    return voidMarker;
  }

  visitIfStatement(IfStatement node) {
    wrapExpression(node.condition, w.NumType.i32);
    node.then.accept(this);
    node.otherwise?.accept(this);
    return voidMarker;
  }

  visitReturnStatement(ReturnStatement node) {
    if (node.expression != null) {
      wrapExpression(node.expression!, _returnType(codeGen.function.type));
    }
    return voidMarker;
  }

  visitVariableDeclaration(VariableDeclaration node) {
    Expression? initializer = node.initializer;
    if (initializer != null) {
      wrapExpression(
          initializer, translateType(node.type).withNullability(true));
    }
    return voidMarker;
  }

  w.ValueType defaultExpression(Expression node) {
    throw "Unsupported expression in body analyzer: $node";
  }

  w.ValueType visitVariableGet(VariableGet node) {
    DartType? promotedDartType = node.promotedType;
    if (promotedDartType != null) {
      w.ValueType promotedType = translateType(promotedDartType);
      if (promotedType is! w.RefType) {
        // Primitive types are assigned to an accompanying promoted local at
        // promotion.
        return promotedType;
      }
    }
    return translateType(node.variable.type).withNullability(true);
  }

  w.ValueType visitVariableSet(VariableSet node) {
    w.ValueType expectedType = this.expectedType;
    w.ValueType valueType = wrapExpression(
        node.value, translateType(node.variable.type).withNullability(true));
    if (expectedType != voidMarker) {
      preserved.add(node);
      return valueType;
    }
    return voidMarker;
  }

  w.ValueType visitInstanceGet(InstanceGet node) {
    // TODO: Use devirtualization to determine whether this is a direct field
    // access.
    Member target = node.interfaceTarget;
    w.ValueType receiverType;
    w.ValueType resultType;
    if (target is Field) {
      // Direct field access
      w.StructType struct = translator.classInfo[target.enclosingClass]!.struct;
      receiverType = w.RefType.def(struct, nullable: true);
      resultType = struct.fields[translator.fieldIndex[target]!].type.unpacked;
    } else {
      // Instance call of getter
      int selectorId =
          translator.tableSelectorAssigner.getterSelectorId(target);
      w.FunctionType signature =
          translator.dispatchTable.selectorInfo[selectorId]!.signature;
      receiverType = signature.inputs[0];
      resultType = signature.outputs.single;
    }
    wrapExpression(node.receiver, receiverType);
    return resultType;
  }

  w.ValueType visitInstanceSet(InstanceSet node) {
    w.ValueType expectedType = this.expectedType;
    // TODO: Use devirtualization to determine whether this is a direct field
    // access.
    Member target = node.interfaceTarget;
    w.ValueType receiverType;
    w.ValueType valueType;
    if (target is Field) {
      // Direct field access
      w.StructType struct = translator.classInfo[target.enclosingClass]!.struct;
      receiverType = w.RefType.def(struct, nullable: true);
      valueType = struct.fields[translator.fieldIndex[target]!].type.unpacked;
    } else {
      // Instance call of setter
      int selectorId =
          translator.tableSelectorAssigner.methodOrSetterSelectorId(target);
      w.FunctionType signature =
          translator.dispatchTable.selectorInfo[selectorId]!.signature;
      receiverType = signature.inputs[0];
      valueType = signature.inputs[1];
    }
    wrapExpression(node.receiver, receiverType);
    wrapExpression(node.value, valueType);
    if (expectedType != voidMarker) {
      preserved.add(node);
      return valueType;
    }
    return voidMarker;
  }

  w.ValueType _returnType(w.FunctionType signature) {
    return signature.outputs.isEmpty ? voidMarker : signature.outputs.single;
  }

  w.ValueType _visitArguments(
      Arguments arguments, w.FunctionType signature, int signatureOffset) {
    assert(arguments.positional.length ==
        signature.inputs.length - signatureOffset);
    for (int i = 0; i < arguments.positional.length; i++) {
      wrapExpression(
          arguments.positional[i], signature.inputs[signatureOffset + i]);
    }
    return _returnType(signature);
  }

  w.ValueType _visitThis(w.ValueType expectedType) {
    w.ValueType thisParameterType = codeGen.function.type.inputs[0];
    if (expectedType == voidMarker ||
        thisParameterType.isSubtypeOf(expectedType)) {
      return thisParameterType.withNullability(true);
    }
    specializeThis = true;
    return translator.classInfo[codeGen.member.enclosingClass]!.repr
        .withNullability(true);
  }

  w.ValueType visitInstanceInvocation(InstanceInvocation node) {
    if (node.interfaceTarget.kind == ProcedureKind.Operator) {
      w.ValueType? intrinsicResult = intrinsifier.getOperatorIntrinsic(node);
      if (intrinsicResult != null) return intrinsicResult;
    }
    w.FunctionType signature =
        translator.dispatchTable.signatureForTarget(node.interfaceTarget);
    wrapExpression(node.receiver, signature.inputs[0]);
    return _visitArguments(node.arguments, signature, 1);
  }

  w.ValueType visitEqualsNull(EqualsNull node) {
    wrapExpression(node.expression, w.RefType.any());
    return w.NumType.i32;
  }

  w.ValueType visitEqualsCall(EqualsCall node) {
    w.ValueType? intrinsicResult = intrinsifier.getEqualsIntrinsic(node);
    if (intrinsicResult != null) return intrinsicResult;
    w.ValueType object =
        translateType(translator.coreTypes.objectNullableRawType);
    wrapExpression(node.left, object);
    wrapExpression(node.right, object);
    return w.NumType.i32;
  }

  w.ValueType visitSuperMethodInvocation(SuperMethodInvocation node) {
    w.FunctionType signature =
        translator.dispatchTable.signatureForTarget(node.interfaceTarget!);
    _visitThis(signature.inputs[0]);
    return _visitArguments(node.arguments, signature, 1);
  }

  w.ValueType visitStaticInvocation(StaticInvocation node) {
    w.ValueType? intrinsicResult = intrinsifier.getStaticIntrinsic(node);
    if (intrinsicResult != null) return intrinsicResult;
    w.FunctionType signature = translator.functions[node.target]!.type;
    return _visitArguments(node.arguments, signature, 0);
  }

  w.ValueType visitConstructorInvocation(ConstructorInvocation node) {
    w.FunctionType signature = translator.functions[node.target]!.type;
    _visitArguments(node.arguments, signature, 1);
    if (expectedType != voidMarker) {
      preserved.add(node);
      ClassInfo info = translator.classInfo[node.target.enclosingClass]!;
      return w.RefType.def(info.struct, nullable: true);
    }
    return voidMarker;
  }

  w.ValueType visitNot(Not node) {
    wrapExpression(node.operand, w.NumType.i32);
    return w.NumType.i32;
  }

  w.ValueType visitNullCheck(NullCheck node) {
    // TODO: Actual check, throwing an exception.
    return wrapExpression(node.operand, expectedType);
  }

  w.ValueType visitLogicalExpression(LogicalExpression node) {
    wrapExpression(node.left, w.NumType.i32);
    wrapExpression(node.right, w.NumType.i32);
    return w.NumType.i32;
  }

  w.ValueType visitConditionalExpression(ConditionalExpression node) {
    w.ValueType expectedType = this.expectedType;
    expressionType[node] = expectedType;
    wrapExpression(node.condition, w.NumType.i32);
    wrapExpression(node.then, expectedType);
    wrapExpression(node.otherwise, expectedType);
    return expectedType;
  }

  w.ValueType visitIsExpression(IsExpression node) {
    wrapExpression(node.operand, typeOfExp(node.operand));
    return w.NumType.i32;
  }

  w.ValueType visitAsExpression(AsExpression node) {
    // TODO: Actual check, throwing an exception.
    return wrapExpression(node.operand, expectedType);
  }

  w.ValueType visitThisExpression(ThisExpression node) {
    return _visitThis(expectedType);
  }

  w.ValueType visitConstantExpression(ConstantExpression node) {
    if (node.constant is NullConstant) {
      return expressionType[node] = expectedType.withNullability(true);
    }
    return typeOfExp(node);
  }

  w.ValueType visitBoolLiteral(BoolLiteral node) {
    return w.NumType.i32;
  }

  w.ValueType visitIntLiteral(IntLiteral node) {
    return w.NumType.i64;
  }

  w.ValueType visitDoubleLiteral(DoubleLiteral node) {
    return w.NumType.f64;
  }

  w.ValueType visitNullLiteral(NullLiteral node) {
    return expressionType[node] = expectedType.withNullability(true);
  }

  w.ValueType visitLet(Let node) {
    w.ValueType expectedType = this.expectedType;
    wrapExpression(node.variable.initializer!,
        translateType(node.variable.type).withNullability(true));
    return wrapExpression(node.body, expectedType);
  }

  w.ValueType visitBlockExpression(BlockExpression node) {
    w.ValueType expectedType = this.expectedType;
    node.body.accept(this);
    return wrapExpression(node.value, expectedType);
  }
}
