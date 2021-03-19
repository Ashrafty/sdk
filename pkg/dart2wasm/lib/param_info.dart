// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/translator.dart';

import 'package:kernel/ast.dart';

class ParameterInfo {
  final Member member;
  late final List<Constant?> positional;
  late final Map<String, Constant> named;

  // Do not access these until the info is complete.
  late final names = named.keys.toList()..sort();
  late final Map<String, int> nameIndex = {
    for (int i = 0; i < names.length; i++) names[i]: positional.length + i
  };

  int get paramCount => positional.length + named.length;

  static Constant defaultValue(VariableDeclaration param) {
    Expression? initializer = param.initializer;
    if (initializer is ConstantExpression) {
      return initializer.constant;
    } else if (initializer == null) {
      return NullConstant();
    } else {
      throw "Non-constant default value";
    }
  }

  ParameterInfo.fromMember(Reference target) : member = target.asMember {
    FunctionNode? function = member.function;
    if (function != null) {
      positional = List.generate(function.positionalParameters.length, (i) {
        if (i < function.requiredParameterCount) return null;
        return defaultValue(function.positionalParameters[i]);
      });
      named = {
        for (VariableDeclaration param in function.namedParameters)
          param.name!: defaultValue(param)
      };
    } else {
      positional = [if (target.isSetter) null];
      named = {};
    }
  }

  void merge(ParameterInfo other) {
    for (int i = 0; i < other.positional.length; i++) {
      if (i >= positional.length) {
        positional.add(other.positional[i]);
      } else {
        if (positional[i] == null) {
          positional[i] = other.positional[i];
        } else if (other.positional[i] != null) {
          if (positional[i] != other.positional[i]) {
            print("Mismatching default value for parameter $i: "
                "${member}: ${positional[i]} vs "
                "${other.member}: ${other.positional[i]}");
          }
        }
      }
    }
    for (String name in other.named.keys) {
      Constant? value = named[name];
      Constant otherValue = other.named[name]!;
      if (value == null) {
        named[name] = otherValue;
      } else {
        if (value != otherValue) {
          print("Mismatching default value for parameter '$name': "
              "${member}: ${value} vs "
              "${other.member}: ${otherValue}");
        }
      }
    }
  }
}
