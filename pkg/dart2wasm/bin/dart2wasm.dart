// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
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

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/reference_from_index.dart';
import 'package:kernel/target/changed_structure_notifier.dart';
import 'package:kernel/target/targets.dart';
import 'package:kernel/transformations/mixin_full_resolution.dart'
    as transformMixins show transformLibraries;
import 'package:kernel/type_environment.dart';

import 'package:vm/kernel_front_end.dart';
import 'package:vm/target/vm.dart';
import 'package:vm/transformations/type_flow/table_selector_assigner.dart';

import 'package:dart2wasm/translator.dart';

class WasmTarget extends Target {
  @override
  String get name => 'wasm';

  TargetFlags get flags => TargetFlags(enableNullSafety: true);

  @override
  void performModularTransformationsOnLibraries(
      Component component,
      CoreTypes coreTypes,
      ClassHierarchy hierarchy,
      List<Library> libraries,
      Map<String, String> environmentDefines,
      DiagnosticReporter diagnosticReporter,
      ReferenceFromIndex referenceFromIndex,
      {void logger(String msg)?,
      ChangedStructureNotifier? changedStructureNotifier}) {
    transformMixins.transformLibraries(
        this, coreTypes, hierarchy, libraries, referenceFromIndex);
    logger?.call("Transformed mixin applications");
  }

  @override
  ConstantsBackend constantsBackend(CoreTypes coreTypes) =>
      new ConstantsBackend();

  Expression instantiateInvocation(CoreTypes coreTypes, Expression receiver,
      String name, Arguments arguments, int offset, bool isSuper) {
    throw "Unsupported: instantiateInvocation";
  }

  Expression instantiateNoSuchMethodError(CoreTypes coreTypes,
      Expression receiver, String name, Arguments arguments, int offset,
      {bool isMethod: false,
      bool isGetter: false,
      bool isSetter: false,
      bool isField: false,
      bool isLocalVariable: false,
      bool isDynamic: false,
      bool isSuper: false,
      bool isStatic: false,
      bool isConstructor: false,
      bool isTopLevel: false}) {
    throw "Unsupported: instantiateNoSuchMethodError";
  }

  @override
  int get enabledLateLowerings => LateLowering.all;

  @override
  bool get supportsExplicitGetterCalls => true;

  @override
  bool get supportsLateLoweringSentinel => false;

  @override
  bool get useStaticFieldLowering => true;

  @override
  bool enableNative(Uri uri) => true;

  @override
  bool get supportsNewMethodInvocationEncoding => true;
}

main(List<String> args) async {
  final Map<String, void Function(TranslatorOptions, bool)> boolOptionMap = {
    "inlining": (o, value) => o.inlining = value,
    "local-nullability": (o, value) => o.localNullability = value,
    "parameter-nullability": (o, value) => o.parameterNullability = value,
    "polymorphic-specialization": (o, value) =>
        o.polymorphicSpecialization = value,
    "print-kernel": (o, value) => o.printKernel = value,
    "print-wasm": (o, value) => o.printWasm = value,
  };
  final Map<String, void Function(TranslatorOptions, int)> intOptionMap = {
    "watch": (o, value) => (o.watchPoints ??= []).add(value),
  };

  TranslatorOptions options = TranslatorOptions();
  List<String> nonOptions = [];
  void Function(TranslatorOptions, int)? intOptionFun = null;
  for (String arg in args) {
    if (intOptionFun != null) {
      intOptionFun(options, int.parse(arg));
      intOptionFun = null;
    } else if (arg.startsWith("--no-")) {
      var optionFun = boolOptionMap[arg.substring(5)];
      if (optionFun == null) throw "Unknown option $arg";
      optionFun(options, false);
    } else if (arg.startsWith("--")) {
      var optionFun = boolOptionMap[arg.substring(2)];
      if (optionFun != null) {
        optionFun(options, true);
      } else {
        intOptionFun = intOptionMap[arg.substring(2)];
        if (intOptionFun == null) throw "Unknown option $arg";
      }
    } else {
      nonOptions.add(arg);
    }
  }
  if (intOptionFun != null) {
    throw "Missing argument to ${args.last}";
  }

  String input = nonOptions[0];
  String output = nonOptions[1];
  Uri mainUri = resolveInputUri(input);

  TargetFlags targetFlags = TargetFlags(enableNullSafety: true);
  Target target = WasmTarget();

  CompilerOptions compilerOptions = CompilerOptions()
    ..target = target
    ..compileSdk = true
    ..sdkRoot = Uri.file(Directory("sdk").absolute.path)
    ..environmentDefines = {}
    ..verbose = false;

  CompilerResult compilerResult =
      await kernelForProgram(mainUri, compilerOptions);
  Component component = compilerResult.component;

  Procedure printMember = component.libraries
      .firstWhere((l) => l.name == "dart.core")
      .procedures
      .firstWhere((p) => p.name?.name == "print");
  printMember.isExternal = true;
  printMember.function!.body = null;

  if (false)
    await runGlobalTransformations(
        target, component, true, false, false, ErrorDetector(),
        minimalKernel: true);
  final tableSelectorAssigner = new TableSelectorAssigner(component);

  print(component.libraries
      .map((l) => "${l.name}: ${l.classes.length} ${l.members.length}")
      .toList());

  var translator = Translator(
      component,
      compilerResult.coreTypes,
      TypeEnvironment(compilerResult.coreTypes, compilerResult.classHierarchy),
      tableSelectorAssigner,
      options);
  File(output).writeAsBytesSync(translator.translate().encode());
}
