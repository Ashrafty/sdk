// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/translator.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:kernel/ast.dart';

typedef Intrinsic = void Function(CodeGenerator codeGen);

class Intrinsics {
  Translator translator;

  late Map<DartType, Map<String, Map<DartType, Intrinsic>>> binaryOperatorMap;
  late Map<DartType, Map<String, Intrinsic>> unaryOperatorMap;

  Intrinsics(this.translator) {
    DartType i = translator.coreTypes.intRawType(Nullability.nonNullable);
    DartType d = translator.coreTypes.doubleRawType(Nullability.nonNullable);
    binaryOperatorMap = {
      i: {
        '+': {i: (c) => c.b.i64_add()},
        '-': {i: (c) => c.b.i64_sub()},
        '*': {i: (c) => c.b.i64_mul()},
        '~/': {i: (c) => c.b.i64_div_s()},
        '%': {i: (c) => c.b.i64_rem_s()},
        '&': {i: (c) => c.b.i64_and()},
        '|': {i: (c) => c.b.i64_or()},
        '^': {i: (c) => c.b.i64_xor()},
        '==': {i: (c) => c.b.i64_eq()},
        '<': {i: (c) => c.b.i64_lt_s()},
        '<=': {i: (c) => c.b.i64_le_s()},
        '>': {i: (c) => c.b.i64_gt_s()},
        '>=': {i: (c) => c.b.i64_ge_s()},
      },
      d: {
        '+': {d: (c) => c.b.f64_add()},
        '-': {d: (c) => c.b.f64_sub()},
        '*': {d: (c) => c.b.f64_mul()},
        '/': {d: (c) => c.b.f64_div()},
        '==': {d: (c) => c.b.f64_eq()},
        '<': {d: (c) => c.b.f64_lt()},
        '<=': {d: (c) => c.b.f64_le()},
        '>': {d: (c) => c.b.f64_gt()},
        '>=': {d: (c) => c.b.f64_ge()},
      }
    };

    unaryOperatorMap = {
      i: {
        'unary-': (c) {
          c.b.i64_const(-1);
          c.b.i64_mul();
        }
      }
    };
  }

  Intrinsic? getOperatorIntrinsic(
      MethodInvocation invocation, CodeGenerator codeGen) {
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
}
