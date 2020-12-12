// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:front_end/src/api_unstable/vm.dart'
    show
        CompilerContext,
        CompilerOptions,
        CompilerResult,
        DiagnosticMessage,
        DiagnosticMessageHandler,
        ExperimentalFlag,
        FileSystem,
        FileSystemEntity,
        NnbdMode,
        ProcessedOptions,
        Severity,
        StandardFileSystem,
        getMessageUri,
        kernelForProgram,
        parseExperimentalArguments,
        parseExperimentalFlags,
        printDiagnosticMessage,
        resolveInputUri;

import 'package:kernel/ast.dart' show Component;
import 'package:kernel/core_types.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/vm/constants_native_effects.dart'
    show VmConstantsBackend;

import 'package:vm/kernel_front_end.dart';
import 'package:vm/target/vm.dart';

import 'package:dart2wasm/translator.dart';

class WasmTarget extends VmTarget {
  WasmTarget(TargetFlags flags) : super(flags);
}

main(List<String> args) async {
  String input = args[0];
  Uri mainUri = resolveInputUri(input);

  TargetFlags targetFlags = TargetFlags(enableNullSafety: true);
  Target target = WasmTarget(targetFlags);

  CompilerOptions options = CompilerOptions()
    ..target = target
    ..compileSdk = true
    ..sdkRoot = Uri.file(Directory("sdk").absolute.path)
    ..environmentDefines = {}
    ..verbose = true;

  CompilerResult compilerResult = await kernelForProgram(mainUri, options);
  Component component = compilerResult.component;
  await runGlobalTransformations(
      target, component, true, false, false, false, ErrorDetector());

  print(compilerResult.component.libraries.map((l) => l.name).toList());

  var translator = Translator(component);
  File(args[1]).writeAsBytesSync(translator.translate().encode());
}
