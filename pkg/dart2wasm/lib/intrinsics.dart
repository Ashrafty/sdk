// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/translator.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:kernel/ast.dart';

typedef Intrinsic = void Function(CodeGenerator codeGen);

class Intrinsics {
  final Translator translator;
  final DartType intType;
  final DartType doubleType;

  late final Map<DartType, Map<String, Map<DartType, Intrinsic>>>
      binaryOperatorMap;
  late final Map<DartType, Map<String, Intrinsic>> unaryOperatorMap;
  late final Map<DartType, Map<DartType, Map<bool, Intrinsic>>> equalsMap;

  // Meaning of the `isNot` field of `EqualsCall`
  static const bool isEquals = false;
  static const bool isNotEquals = true;

  Intrinsics(this.translator)
      : intType = translator.coreTypes.intRawType(Nullability.nonNullable),
        doubleType =
            translator.coreTypes.doubleRawType(Nullability.nonNullable) {
    binaryOperatorMap = {
      intType: {
        '+': {intType: (c) => c.b.i64_add()},
        '-': {intType: (c) => c.b.i64_sub()},
        '*': {intType: (c) => c.b.i64_mul()},
        '~/': {intType: (c) => c.b.i64_div_s()},
        '%': {intType: (c) => c.b.i64_rem_s()},
        '&': {intType: (c) => c.b.i64_and()},
        '|': {intType: (c) => c.b.i64_or()},
        '^': {intType: (c) => c.b.i64_xor()},
        '<': {intType: (c) => c.b.i64_lt_s()},
        '<=': {intType: (c) => c.b.i64_le_s()},
        '>': {intType: (c) => c.b.i64_gt_s()},
        '>=': {intType: (c) => c.b.i64_ge_s()},
      },
      doubleType: {
        '+': {doubleType: (c) => c.b.f64_add()},
        '-': {doubleType: (c) => c.b.f64_sub()},
        '*': {doubleType: (c) => c.b.f64_mul()},
        '/': {doubleType: (c) => c.b.f64_div()},
        '<': {doubleType: (c) => c.b.f64_lt()},
        '<=': {doubleType: (c) => c.b.f64_le()},
        '>': {doubleType: (c) => c.b.f64_gt()},
        '>=': {doubleType: (c) => c.b.f64_ge()},
      }
    };

    unaryOperatorMap = {
      intType: {
        'unary-': (c) {
          c.b.i64_const(-1);
          c.b.i64_mul();
        },
        '~': (c) {
          c.b.i64_const(-1);
          c.b.i64_xor();
        },
      },
      doubleType: {
        'unary-': (c) {
          c.b.f64_neg();
        },
      },
    };

    equalsMap = {
      intType: {
        intType: {
          isEquals: (c) => c.b.i64_eq(),
          isNotEquals: (c) => c.b.i64_ne(),
        }
      },
      doubleType: {
        doubleType: {
          isEquals: (c) => c.b.f64_eq(),
          isNotEquals: (c) => c.b.f64_ne(),
        }
      },
    };
  }

  Intrinsic? getOperatorIntrinsic(
      InstanceInvocation invocation, CodeGenerator codeGen) {
    DartType receiverType =
        invocation.receiver.getStaticType(codeGen.typeContext);
    String name = invocation.name.name;
    if (invocation.arguments.positional.length == 1) {
      // Binary operator
      DartType argType =
          invocation.arguments.positional[0].getStaticType(codeGen.typeContext);
      return binaryOperatorMap[receiverType]?[name]?[argType];
    } else {
      assert(invocation.arguments.positional.length == 0);
      // Unary operator
      return unaryOperatorMap[receiverType]?[name];
    }
  }

  Intrinsic? getEqualsIntrinsic(EqualsCall node, CodeGenerator codeGen) {
    DartType leftType = node.left.getStaticType(codeGen.typeContext);
    DartType rightType = node.right.getStaticType(codeGen.typeContext);
    return equalsMap[leftType]?[rightType]?[node.isNot];
  }
}
