// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/translator.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:kernel/ast.dart';

typedef Intrinsic = void Function(CodeGenerator codeGen);

class Intrinsics {
  Translator translator;

  late Map<DartType, Map<String, Map<DartType, Intrinsic>>> operatorMap;

  Intrinsics(this.translator) {
    DartType i = translator.coreTypes.intRawType(Nullability.nonNullable);
    operatorMap = {
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
      }
    };
  }

  Intrinsic? getOperatorIntrinsic(
      MethodInvocation invocation, CodeGenerator codeGen) {
    DartType receiverType =
        invocation.receiver.getStaticType(codeGen.typeContext);
    String name = invocation.name.name;
    DartType argType =
        invocation.arguments.positional[0].getStaticType(codeGen.typeContext);
    return operatorMap[receiverType]?[name]?[argType];
  }
}
