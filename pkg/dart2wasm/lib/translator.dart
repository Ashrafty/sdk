// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/functions.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart'
    show ClassHierarchy, ClassHierarchySubtypes, ClosedWorldClassHierarchy;
import 'package:kernel/core_types.dart';
import 'package:kernel/src/printer.dart';
import 'package:kernel/type_environment.dart';
import 'package:vm/transformations/type_flow/table_selector_assigner.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class TranslatorOptions {
  bool inlining = false;
  bool localNullability = false;
  bool parameterNullability = true;
  bool polymorphicSpecialization = false;
  bool printKernel = false;
  bool printWasm = false;
  List<int>? watchPoints = null;
}

class Translator {
  final TranslatorOptions options;

  Component component;
  List<Library> libraries;
  CoreTypes coreTypes;
  TypeEnvironment typeEnvironment;
  TableSelectorAssigner tableSelectorAssigner;
  ClosedWorldClassHierarchy hierarchy;
  late ClassHierarchySubtypes subtypes;

  late final Class wasmTypesBaseClass;
  late final Class wasmArrayBaseClass;
  late final Map<Class, w.StorageType> builtinWasmTypes;

  late DispatchTable dispatchTable;

  List<ClassInfo> classes = [];
  Map<Class, ClassInfo> classInfo = {};
  Map<w.HeapType, ClassInfo> classForHeapType = {};
  Map<w.NumType, ClassInfo> classForPrimitive = {};
  Map<Field, int> fieldIndex = {};
  Map<Reference, w.BaseFunction> functions = {};
  late Procedure mainFunction;
  late w.Module m;
  late w.ValueType voidMarker;

  Map<DartType, w.ArrayType> arrayTypeCache = {};

  Translator(this.component, this.coreTypes, this.typeEnvironment,
      this.tableSelectorAssigner, this.options)
      : libraries = component.libraries,
        hierarchy =
            ClassHierarchy(component, coreTypes) as ClosedWorldClassHierarchy {
    subtypes = hierarchy.computeSubtypesInformation();
    dispatchTable = DispatchTable(this);

    Library internalLibrary =
        component.libraries.firstWhere((l) => l.name == "dart._internal");
    Class lookup(String name) {
      return internalLibrary.classes.firstWhere((c) => c.name == name);
    }

    wasmTypesBaseClass = lookup("_WasmBase");
    wasmArrayBaseClass = lookup("_WasmArray");
    builtinWasmTypes = {
      coreTypes.boolClass: w.NumType.i32,
      coreTypes.intClass: w.NumType.i64,
      coreTypes.doubleClass: w.NumType.f64,
      lookup("WasmI8"): w.PackedType.i8,
      lookup("WasmI16"): w.PackedType.i16,
      lookup("WasmI32"): w.NumType.i32,
      lookup("WasmI64"): w.NumType.i64,
      lookup("WasmF32"): w.NumType.f32,
      lookup("WasmF64"): w.NumType.f64,
    };
  }

  w.Module translate() {
    m = w.Module(watchPoints: options.watchPoints);
    voidMarker = w.RefType.def(w.StructType("void"), nullable: true);

    ClassInfoCollector(this).collect();

    w.FunctionType printType = m.addFunctionType([w.NumType.i64], []);
    w.ImportedFunction printFun = m.importFunction("console", "log", printType);
    for (Procedure printMember in component.libraries
        .firstWhere((l) => l.name == "dart.core")
        .procedures
        .where((p) => p.name?.name == "print")) {
      functions[printMember.reference] = printFun;
    }

    dispatchTable.build();
    FunctionCollector(this).collect();
    dispatchTable.output();

    //mainFunction =
    //    libraries.first.procedures.firstWhere((p) => p.name.name == "main");
    //w.DefinedFunction mainFun = functions[mainFunction] as w.DefinedFunction;
    //m.exportFunction("main", mainFun);

    var codeGen = CodeGenerator(this);
    for (Reference reference in functions.keys) {
      Member member = reference.asMember;
      w.BaseFunction function = functions[reference]!;
      if (function is w.DefinedFunction) {
        String exportName = reference.isSetter ? "$member=" : "$member";
        if (options.printKernel || options.printWasm) {
          print("#${function.index}: $exportName");
        }
        if (options.printKernel) {
          if (member is Constructor) {
            Class cls = member.enclosingClass;
            for (Field field in cls.fields) {
              if (field.isInstanceMember && field.initializer != null) {
                print("${field.name}: ${field.initializer}");
              }
            }
            for (Initializer initializer in member.initializers) {
              print(initializer);
            }
          }
          Statement? body = member.function?.body;
          if (body != null) {
            print(body);
          }
          if (!options.printWasm) print("");
        }
        m.exportFunction(exportName, function);
        codeGen.generate(reference, function);
        if (options.printWasm) print(function.body.trace);
      }
    }

    return m;
  }

  Class classForType(DartType type) => type.accept(ClassForType(coreTypes));

  Class upperBound(Class a, Class b) {
    if (hierarchy.isSubclassOf(b, a)) return a;
    if (hierarchy.isSubclassOf(a, b)) return b;
    Set<Class> supers(Class cls) =>
        {for (Class? c = cls.superclass; c != null; c = c.superclass) c};
    Set<Class> aSupers = supers(a);
    assert(!aSupers.contains(b));
    Class c;
    for (c = b.superclass!; !aSupers.contains(c); c = c.superclass!);
    return c;
  }

  w.ValueType translateType(DartType type) {
    w.StorageType wasmType = translateStorageType(type);
    if (wasmType is w.ValueType) return wasmType;
    throw "Non-value types only allowed in arrays and fields";
  }

  bool _isWasmType(InterfaceType type) {
    return type.classNode.superclass?.superclass == wasmTypesBaseClass;
  }

  w.StorageType translateStorageType(DartType type) {
    assert(type is! VoidType);
    if (type is InterfaceType) {
      if (!type.isPotentiallyNullable) {
        w.StorageType? builtin = builtinWasmTypes[type.classNode];
        if (builtin != null) return builtin;
      } else if (_isWasmType(type)) {
        throw "Wasm numeric types can't be nullable";
      }
      if (type.classNode.superclass == wasmArrayBaseClass) {
        DartType elementType = type.typeArguments.single;
        return w.RefType.def(arrayType(elementType), nullable: false);
      }
      return w.RefType.def(classInfo[type.classNode]!.repr.struct,
          nullable:
              !options.parameterNullability || type.isPotentiallyNullable);
    }
    if (type is DynamicType) {
      return translateStorageType(coreTypes.objectNullableRawType);
    }
    if (type is VoidType) {
      return voidMarker;
    }
    if (type is TypeParameterType) {
      return translateStorageType(type.bound);
    }
    if (type is FutureOrType) {
      return translateStorageType(coreTypes.objectNullableRawType);
    }
    if (type is FunctionType) {
      // TODO
      return w.RefType.any();
    }
    throw "Unsupported type ${type.runtimeType}";
  }

  w.ArrayType arrayType(DartType type) {
    while (type is TypeParameterType) type = type.bound;
    return arrayTypeCache.putIfAbsent(
        type,
        () => m.addArrayType("Array<${type.toText(defaultAstTextStrategy)}>")
          ..elementType = w.FieldType(translateStorageType(type)));
  }

  w.ValueType typeForLocal(w.ValueType type) {
    return options.localNullability ? type : type.withNullability(true);
  }

  Member? singleTarget(Member interfaceTarget, DartType receiverType,
      {required bool setter}) {
    while (receiverType is TypeParameterType) receiverType = receiverType.bound;
    Class receiverClass = receiverType is InterfaceType
        ? receiverType.classNode
        : coreTypes.objectClass;
    return subtypes.getSingleTargetForInterfaceInvocation(interfaceTarget,
        receiverClass: receiverClass, setter: setter);
  }

  bool shouldInline(Reference target) {
    if (!options.inlining) return false;
    Member member = target.asMember;
    if (member is Field) return true;
    Statement? body = member.function!.body;
    return body != null && NodeCounter().countNodes(body) < 4;
  }
}

class NodeCounter extends Visitor<void> with VisitorVoidMixin {
  int count = 0;

  int countNodes(Node node) {
    count = 0;
    node.accept(this);
    return count;
  }

  void defaultNode(Node node) {
    count++;
    node.visitChildren(this);
  }
}

class ClassForType extends DartTypeVisitor<Class> {
  final CoreTypes coreTypes;

  ClassForType(this.coreTypes);

  Class defaultDartType(DartType node) => throw "Unsupported type $node";

  Class visitDynamicType(DynamicType node) => coreTypes.objectClass;
  Class visitVoidType(VoidType node) => coreTypes.objectClass;
  Class visitInterfaceType(InterfaceType node) => node.classNode;
  Class visitFutureOrType(FutureOrType node) => coreTypes.objectClass;
  Class visitFunctionType(FunctionType node) => coreTypes.objectClass; // TODO
  Class visitTypeParameterType(TypeParameterType node) =>
      node.bound.accept(this);
  Class visitNeverType(NeverType node) => coreTypes.objectClass;
  Class visitNullType(NullType node) => coreTypes.objectClass;
}

extension GetterSetterReference on Reference {
  bool get isImplicitGetter {
    Member member = asMember;
    return member is Field && member.getterReference == this;
  }

  bool get isImplicitSetter {
    Member member = asMember;
    return member is Field && member.setterReference == this;
  }

  bool get isGetter {
    Member member = asMember;
    return member is Procedure && member.isGetter || isImplicitGetter;
  }

  bool get isSetter {
    Member member = asMember;
    return member is Procedure && member.isSetter || isImplicitSetter;
  }
}
