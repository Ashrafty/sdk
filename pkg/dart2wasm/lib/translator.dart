// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:dart2wasm/class_info.dart';
import 'package:dart2wasm/closures.dart';
import 'package:dart2wasm/code_generator.dart';
import 'package:dart2wasm/constants.dart';
import 'package:dart2wasm/dispatch_table.dart';
import 'package:dart2wasm/functions.dart';
import 'package:dart2wasm/globals.dart';
import 'package:dart2wasm/param_info.dart';

import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart'
    show ClassHierarchy, ClassHierarchySubtypes, ClosedWorldClassHierarchy;
import 'package:kernel/core_types.dart';
import 'package:kernel/src/printer.dart';
import 'package:kernel/type_environment.dart';
import 'package:vm/metadata/direct_call.dart';
import 'package:vm/transformations/type_flow/table_selector_assigner.dart';

import 'package:wasm_builder/wasm_builder.dart' as w;

class TranslatorOptions {
  bool exportAll = false;
  bool inlining = false;
  bool localNullability = false;
  bool parameterNullability = true;
  bool polymorphicSpecialization = false;
  bool printKernel = false;
  bool printWasm = false;
  bool stubBodies = false;
  List<int>? watchPoints = null;
}

typedef CodeGenCallback = void Function(w.Instructions);

class Translator {
  final TranslatorOptions options;

  Component component;
  List<Library> libraries;
  CoreTypes coreTypes;
  TypeEnvironment typeEnvironment;
  TableSelectorAssigner tableSelectorAssigner;
  ClosedWorldClassHierarchy hierarchy;
  late ClassHierarchySubtypes subtypes;

  late final w.RefType nonNullableObjectType;
  late final w.RefType nullableObjectType;

  late final Class wasmTypesBaseClass;
  late final Class wasmArrayBaseClass;
  late final Class wasmDataRefClass;
  late final Class boxedBoolClass;
  late final Class boxedIntClass;
  late final Class boxedDoubleClass;
  late final Class functionClass;
  late final Class fixedLengthListClass;
  late final Class growableListClass;
  late final Procedure mapFactory;
  late final Procedure mapPut;
  late final Map<Class, w.StorageType> builtinTypes;
  late final Map<w.ValueType, Class> boxedClasses;

  late final DispatchTable dispatchTable;
  late final Globals globals;
  late final Constants constants;
  late final FunctionCollector functions;

  List<ClassInfo> classes = [];
  Map<Class, ClassInfo> classInfo = {};
  Map<w.HeapType, ClassInfo> classForHeapType = {};
  Map<Field, int> fieldIndex = {};
  Map<Reference, ParameterInfo> staticParamInfo = {};
  late Procedure mainFunction;
  late w.Module m;
  late w.ValueType voidMarker;
  late w.StructType dummyContext;

  Map<DartType, w.ArrayType> arrayTypeCache = {};
  Map<int, w.StructType> functionTypeCache = {};
  Map<w.StructType, int> functionTypeParameterCount = {};
  Map<int, w.DefinedGlobal> functionTypeRtt = {};
  Map<w.DefinedFunction, w.DefinedGlobal> functionRefCache = {};
  Map<Procedure, w.DefinedFunction> tearOffFunctionCache = {};

  Translator(this.component, this.coreTypes, this.typeEnvironment,
      this.tableSelectorAssigner, this.options)
      : libraries = component.libraries,
        hierarchy =
            ClassHierarchy(component, coreTypes) as ClosedWorldClassHierarchy {
    subtypes = hierarchy.computeSubtypesInformation();
    dispatchTable = DispatchTable(this);
    functions = FunctionCollector(this);

    Library coreLibrary =
        component.libraries.firstWhere((l) => l.name == "dart.core");
    Class lookupCore(String name) {
      return coreLibrary.classes.firstWhere((c) => c.name == name);
    }

    Library internalLibrary =
        component.libraries.firstWhere((l) => l.name == "dart._internal");
    Class lookupInternal(String name) {
      return internalLibrary.classes.firstWhere((c) => c.name == name);
    }

    wasmTypesBaseClass = lookupInternal("_WasmBase");
    wasmArrayBaseClass = lookupInternal("_WasmArray");
    wasmDataRefClass = lookupInternal("WasmDataRef");
    boxedBoolClass = lookupCore("_BoxedBool");
    boxedIntClass = lookupCore("_BoxedInt");
    boxedDoubleClass = lookupCore("_BoxedDouble");
    functionClass = lookupCore("_Function");
    fixedLengthListClass = lookupCore("_List");
    growableListClass = lookupCore("_GrowableList");
    mapFactory = lookupCore("Map").procedures.firstWhere(
        (p) => p.kind == ProcedureKind.Factory && p.name.text == "");
    mapPut = component.libraries
        .firstWhere((l) => l.name == "dart.collection")
        .classes
        .firstWhere((c) => c.name == "_CompactLinkedCustomHashMap")
        .superclass! // _HashBase
        .superclass! // _LinkedHashMapMixin<K, V>
        .procedures
        .firstWhere((p) => p.name.text == "[]=");
    builtinTypes = {
      coreTypes.boolClass: w.NumType.i32,
      coreTypes.intClass: w.NumType.i64,
      coreTypes.doubleClass: w.NumType.f64,
      wasmDataRefClass: w.RefType.data(),
      boxedBoolClass: w.NumType.i32,
      boxedIntClass: w.NumType.i64,
      boxedDoubleClass: w.NumType.f64,
      lookupInternal("WasmI8"): w.PackedType.i8,
      lookupInternal("WasmI16"): w.PackedType.i16,
      lookupInternal("WasmI32"): w.NumType.i32,
      lookupInternal("WasmI64"): w.NumType.i64,
      lookupInternal("WasmF32"): w.NumType.f32,
      lookupInternal("WasmF64"): w.NumType.f64,
    };
    boxedClasses = {
      w.NumType.i32: boxedBoolClass,
      w.NumType.i64: boxedIntClass,
      w.NumType.f64: boxedDoubleClass,
    };
  }

  w.Module translate() {
    m = w.Module(watchPoints: options.watchPoints);
    voidMarker = w.RefType.def(w.StructType("void"), nullable: true);
    dummyContext = m.addStructType("<context>");

    ClassInfoCollector(this).collect();
    globals = Globals(this);
    constants = Constants(this);

    dispatchTable.build();
    functions.collectImports();

    mainFunction =
        libraries.first.procedures.firstWhere((p) => p.name.text == "main");
    var mainReturns =
        functions.getFunction(mainFunction.reference).type.outputs;
    if (mainReturns.any((t) => t is w.RefType)) {
      print(
          "Warning: main returns a reference type. JS embedding may complain.");
    }

    var codeGen = CodeGenerator(this);
    while (functions.pending.isNotEmpty) {
      Reference reference = functions.pending.removeLast();
      Member member = reference.asMember;
      var function =
          functions.getExistingFunction(reference) as w.DefinedFunction;
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
      if (member == mainFunction || options.exportAll) {
        m.exportFunction(exportName, function);
      }
      codeGen.generate(reference, function, function.locals);
      if (options.printWasm) print(function.body.trace);

      for (Lambda lambda in codeGen.closures.lambdas.values) {
        codeGen.generateLambda(lambda);
        if (options.printWasm) {
          print("#${lambda.function.index}: $exportName (closure)");
          print(lambda.function.body.trace);
        }
      }
    }

    if (options.printWasm) {
      for (ConstantInfo info in constants.constantInfo.values) {
        print("#${info.function.index}: ${info.constant}");
        print(info.function.body.trace);
      }
    }

    dispatchTable.output();

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

  bool isWasmType(DartType type) {
    return type is InterfaceType &&
        (type.classNode.superclass == wasmTypesBaseClass ||
            type.classNode.superclass?.superclass == wasmTypesBaseClass);
  }

  w.StorageType translateStorageType(DartType type) {
    assert(type is! VoidType);
    if (type is InterfaceType) {
      w.StorageType? builtin = builtinTypes[type.classNode];
      if (builtin != null) {
        if (!type.isPotentiallyNullable) return builtin;
        if (isWasmType(type)) throw "Wasm numeric types can't be nullable";
        Class? boxedClass = boxedClasses[builtin];
        if (boxedClass != null) {
          type = InterfaceType(boxedClass, type.nullability);
        }
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
      return nullableObjectType;
    }
    if (type is NullType) {
      return nullableObjectType;
    }
    if (type is VoidType) {
      return voidMarker;
    }
    if (type is TypeParameterType) {
      return translateStorageType(type.bound);
    }
    if (type is FutureOrType) {
      return nullableObjectType;
    }
    if (type is FunctionType) {
      if (type.requiredParameterCount != type.positionalParameters.length ||
          type.namedParameters.isNotEmpty) {
        throw "Function types with optional parameters not supported: $type";
      }
      return w.RefType.def(functionStructType(type.requiredParameterCount),
          nullable:
              !options.parameterNullability || type.isPotentiallyNullable);
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

  w.StructType functionStructType(int parameterCount) {
    return functionTypeCache.putIfAbsent(parameterCount, () {
      ClassInfo info = classInfo[functionClass]!;
      w.StructType struct =
          m.addStructType("Function$parameterCount", info.struct.fields);
      struct.fields.add(w.FieldType(
          w.RefType.def(functionType(parameterCount), nullable: false),
          mutable: false));
      functionTypeRtt[parameterCount] =
          ClassInfoCollector.makeRtt(m, struct, info);
      functionTypeParameterCount[struct] = parameterCount;
      return struct;
    });
  }

  w.FunctionType functionType(int parameterCount) {
    return m.addFunctionType([
      w.RefType.data(),
      ...List<w.ValueType>.filled(parameterCount, nullableObjectType)
    ], [
      nullableObjectType
    ]);
  }

  int parameterCountForFunctionStruct(w.HeapType heapType) {
    return functionTypeParameterCount[(heapType as w.DefHeapType).def]!;
  }

  w.DefinedGlobal makeFunctionRef(w.DefinedFunction f) {
    return functionRefCache.putIfAbsent(f, () {
      w.DefinedGlobal global = m.addGlobal(
          w.GlobalType(w.RefType.def(f.type, nullable: false), mutable: false));
      global.initializer.ref_func(f);
      global.initializer.end();
      return global;
    });
  }

  w.DefinedFunction getTearOffFunction(Procedure member) {
    return tearOffFunctionCache.putIfAbsent(member, () {
      assert(member.kind == ProcedureKind.Method);
      FunctionNode functionNode = member.function;
      int parameterCount = functionNode.requiredParameterCount;
      if (functionNode.positionalParameters.length != parameterCount ||
          functionNode.namedParameters.isNotEmpty) {
        throw "Tear-off with optional parameters not supported";
      }
      w.FunctionType memberSignature = signatureFor(member.reference);
      w.FunctionType closureSignature = functionType(parameterCount);
      int signatureOffset = member.isInstanceMember ? 1 : 0;
      assert(memberSignature.inputs.length == signatureOffset + parameterCount);
      assert(closureSignature.inputs.length == 1 + parameterCount);
      w.DefinedFunction function = m.addFunction(closureSignature);
      w.BaseFunction target = functions.getFunction(member.reference);
      w.Instructions b = function.body;
      for (int i = 0; i < memberSignature.inputs.length; i++) {
        w.Local paramLocal = function.locals[(1 - signatureOffset) + i];
        b.local_get(paramLocal);
        convertType(function, paramLocal.type, memberSignature.inputs[i]);
      }
      b.call(target);
      convertType(function, outputOrVoid(target.type.outputs),
          outputOrVoid(closureSignature.outputs));
      b.end();
      return function;
    });
  }

  w.ValueType ensureBoxed(w.ValueType type) {
    // Box receiver if it's primitive
    if (type is w.RefType) return type;
    return w.RefType.def(classInfo[boxedClasses[type]!]!.struct,
        nullable: false);
  }

  w.ValueType typeForLocal(w.ValueType type) {
    return options.localNullability ? type : type.withNullability(true);
  }

  w.ValueType outputOrVoid(List<w.ValueType> outputs) {
    return outputs.isEmpty ? voidMarker : outputs.single;
  }

  bool needsConversion(w.ValueType from, w.ValueType to) {
    return (from == voidMarker) ^ (to == voidMarker) || !from.isSubtypeOf(to);
  }

  void convertType(
      w.DefinedFunction function, w.ValueType from, w.ValueType to) {
    w.Instructions b = function.body;
    if (from == voidMarker || to == voidMarker) {
      if (from != voidMarker) {
        b.drop();
        return;
      }
      if (to != voidMarker) {
        // This can happen when a void method has its return type overridden to
        // return a value, in which case the selector signature will have a
        // non-void return type to encompass all possible return values.
        w.RefType toRef = to as w.RefType;
        assert(toRef.nullable);
        b.ref_null(toRef.heapType);
        return;
      }
    }
    if (!from.isSubtypeOf(to)) {
      if (from is! w.RefType && to is w.RefType) {
        // Boxing
        ClassInfo info = classInfo[boxedClasses[from]!]!;
        assert(w.HeapType.def(info.struct).isSubtypeOf(to.heapType));
        w.Local temp = function.addLocal(from);
        b.local_set(temp);
        b.i32_const(info.classId);
        b.local_get(temp);
        b.global_get(info.rtt);
        b.struct_new_with_rtt(info.struct);
      } else if (from is w.RefType && to is! w.RefType) {
        // Unboxing
        ClassInfo info = classInfo[boxedClasses[to]!]!;
        if (!from.heapType.isSubtypeOf(w.HeapType.def(info.struct))) {
          // Cast to box type
          b.global_get(info.rtt);
          b.ref_cast();
        }
        b.struct_get(info.struct, 1);
      } else if (from.withNullability(false).isSubtypeOf(to)) {
        // Null check
        b.ref_as_non_null();
      } else {
        // Downcast
        var heapType = (to as w.RefType).heapType;
        ClassInfo? info = classForHeapType[heapType];
        w.Global global = info != null
            ? info.rtt
            : functionTypeRtt[parameterCountForFunctionStruct(heapType)]!;
        if (from.nullable && !to.nullable) {
          b.ref_as_non_null();
        }
        b.global_get(global);
        b.ref_cast();
      }
    }
  }

  w.FunctionType signatureFor(Reference target) {
    Member member = target.asMember;
    if (member.isInstanceMember) {
      return dispatchTable.selectorForTarget(target).signature;
    } else {
      return functions.getFunction(target).type;
    }
  }

  ParameterInfo paramInfoFor(Reference target) {
    Member member = target.asMember;
    if (member.isInstanceMember) {
      return dispatchTable.selectorForTarget(target).paramInfo;
    } else {
      return staticParamInfo.putIfAbsent(
          target, () => ParameterInfo.fromMember(target));
    }
  }

  Member? singleTarget(TreeNode node) {
    DirectCallMetadataRepository metadata =
        component.metadata[DirectCallMetadataRepository.repositoryTag]
            as DirectCallMetadataRepository;
    return metadata.mapping[node]?.target;
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
