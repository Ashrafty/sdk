// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/visitor.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class Lambda {
  FunctionNode functionNode;
  w.DefinedFunction function;

  Lambda(this.functionNode, this.function);
}

class Context {
  final TreeNode owner;
  final Context? parent;
  final List<VariableDeclaration> variables = [];
  bool containsThis = false;
  late final w.StructType struct;

  late w.Local currentLocal;

  bool get isEmpty => variables.isEmpty && !containsThis;

  int get parentFieldIndex {
    assert(parent != null);
    return 0;
  }

  int get thisFieldIndex {
    assert(containsThis);
    return 0;
  }

  Context(this.owner, this.parent);
}

class Capture {
  final VariableDeclaration variable;
  late final Context context;
  late final int fieldIndex;
  bool written = false;

  Capture(this.variable);

  w.ValueType get type => context.struct.fields[fieldIndex].type.unpacked;
}

class Closures {
  final CodeGenerator codeGen;
  Map<VariableDeclaration, Capture> captures = {};
  bool isThisCaptured = false;
  Map<FunctionNode, Lambda> lambdas = {};
  Map<TreeNode, Context> contexts = {};
  Set<FunctionDeclaration> closurizedFunctions = {};

  Closures(this.codeGen);

  Translator get translator => codeGen.translator;

  void findCaptures(TreeNode node) {
    node.accept(FindCaptures(this));
  }

  void buildContexts(TreeNode node) {
    if (captures.isNotEmpty || isThisCaptured) {
      node.accept(BuildContexts(this));

      // Make struct definitions
      for (Context context in contexts.values) {
        if (!context.isEmpty) {
          context.struct = translator.m.addStructType("<context>");
        }
      }

      // Build object layouts
      for (Context context in contexts.values) {
        if (!context.isEmpty) {
          // TODO: Non-nullable, immutable parent/this when supported
          w.StructType struct = context.struct;
          if (context.parent != null) {
            assert(!context.containsThis);
            struct.fields.add(w.FieldType(
                w.RefType.def(context.parent!.struct, nullable: true)));
          }
          if (context.containsThis) {
            struct.fields.add(
                w.FieldType(codeGen.thisLocal!.type.withNullability(true)));
          }
          for (VariableDeclaration variable in context.variables) {
            int index = struct.fields.length;
            struct.fields.add(w.FieldType(
                translator.translateType(variable.type).withNullability(true)));
            captures[variable]!.fieldIndex = index;
          }
        }
      }
    }
  }
}

class FindCaptures extends RecursiveVisitor {
  final Closures closures;
  final Map<VariableDeclaration, int> variableDepth = {};
  int depth = 0;

  FindCaptures(this.closures);

  Translator get translator => closures.translator;

  @override
  void visitAssertStatement(AssertStatement node) {}

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    if (depth > 0) {
      variableDepth[node] = depth;
    }
    super.visitVariableDeclaration(node);
  }

  void _visitVariableUse(VariableDeclaration variable) {
    int declDepth = variableDepth[variable] ?? 0;
    assert(declDepth <= depth);
    if (declDepth < depth) {
      closures.captures[variable] = Capture(variable);
    } else if (variable.parent is FunctionDeclaration) {
      closures.closurizedFunctions.add(variable.parent as FunctionDeclaration);
    }
  }

  @override
  void visitVariableGet(VariableGet node) {
    _visitVariableUse(node.variable);
    super.visitVariableGet(node);
  }

  @override
  void visitVariableSet(VariableSet node) {
    _visitVariableUse(node.variable);
    super.visitVariableSet(node);
  }

  void _visitThis() {
    if (depth > 0) {
      closures.isThisCaptured = true;
    }
  }

  @override
  void visitThisExpression(ThisExpression node) {
    _visitThis();
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    _visitThis();
  }

  void _visitLambda(FunctionNode node) {
    if (node.positionalParameters.length != node.requiredParameterCount ||
        node.namedParameters.isNotEmpty) {
      throw "Optional parameters not supported for "
          "function expressions and local functions";
    }
    int parameterCount = node.requiredParameterCount;
    w.FunctionType type = translator.functionType(parameterCount);
    w.DefinedFunction function = translator.m.addFunction(type);
    closures.lambdas[node] = Lambda(node, function);

    depth++;
    node.visitChildren(this);
    depth--;
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    _visitLambda(node.function);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // Variable is in outer scope
    node.variable.accept(this);
    _visitLambda(node.function);
  }
}

class BuildContexts extends RecursiveVisitor {
  final Closures closures;
  Context? currentContext;

  BuildContexts(this.closures);

  @override
  void visitAssertStatement(AssertStatement node) {}

  void _newContext(TreeNode node) {
    bool outerMost = currentContext == null;
    Context? oldContext = currentContext;
    Context? parent = currentContext;
    while (parent != null && parent.isEmpty) parent = parent.parent;
    currentContext = Context(node, parent);
    if (closures.isThisCaptured && outerMost) {
      currentContext!.containsThis = true;
    }
    closures.contexts[node] = currentContext!;
    node.visitChildren(this);
    currentContext = oldContext;
  }

  @override
  void visitFunctionNode(FunctionNode node) {
    _newContext(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _newContext(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    _newContext(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    _newContext(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    Capture? capture = closures.captures[node];
    if (capture != null) {
      currentContext!.variables.add(node);
      capture.context = currentContext!;
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitVariableSet(VariableSet node) {
    closures.captures[node.variable]?.written = true;
    super.visitVariableSet(node);
  }
}
