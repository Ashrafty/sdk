// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import '../lib/src/module.dart';
import '../lib/wasm_builder.dart';

main(List<String> args) {
  Module m = Module();
  var ftype = m.addFunctionType([NumType.f64, NumType.f64], [NumType.f64]);
  var bodytype = m.addFunctionType([], [NumType.f64]);
  var idtype = m.addFunctionType([NumType.f64], [NumType.f64]);
  var printtype = m.addFunctionType([NumType.f64], []);

  var printNum = m.importFunction('console', 'log', printtype);
  var fun = m.addFunction(ftype);
  m.exportFunction("sequence", fun);

  //var sumVar = fun.addLocal(NumType.f64);
  Instructions b = fun.body;
  Label e = b.expression(bodytype);
  b.f64_const(0);
  //b.local_set(sumVar);

  Label exit = b.block(idtype);
  Label loop = b.loop(idtype);
  b.local_get(fun.locals[0]);
  b.local_get(fun.locals[1]);
  b.f64_gt();
  b.br_if(exit);

  b.local_get(fun.locals[0]);
  b.call(printNum);

  //b.local_get(sumVar);
  b.local_get(fun.locals[0]);
  b.f64_add();
  //b.local_set(sumVar);

  b.local_get(fun.locals[0]);
  b.f64_const(1);
  b.f64_add();
  b.local_set(fun.locals[0]);

  b.br(loop);
  b.end(loop);
  b.end(exit);
  //b.local_get(sumVar);
  b.end(e);

  File(args[0]).writeAsBytesSync(m.encode());
}
