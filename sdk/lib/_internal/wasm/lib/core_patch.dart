// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "dart:_internal" show patch;

import "dart:_internal"
    show
        allocateOneByteString,
        allocateTwoByteString,
        CodeUnits,
        copyRangeFromUint8ListToOneByteString,
        EfficientLengthIterable,
        FixedLengthListMixin,
        IterableElementError,
        ListIterator,
        Lists,
        POWERS_OF_TEN,
        SubListIterable,
        UnmodifiableListBase,
        has63BitSmis,
        makeFixedListUnmodifiable,
        makeListFixedLength,
        patch,
        unsafeCast,
        WasmObjectArray,
        writeIntoOneByteString,
        writeIntoTwoByteString;

import "dart:collection"
    show
        HashMap,
        IterableBase,
        LinkedHashMap,
        LinkedList,
        LinkedListEntry,
        ListBase,
        MapBase,
        Maps,
        UnmodifiableMapBase,
        UnmodifiableMapView;

import "dart:typed_data"
    show Endian, Uint8List, Int64List, Uint16List, Uint32List;

@patch
@pragma("wasm:entry-point")
class bool {
  // A boxed bool contains an unboxed bool.
  bool value = false;
}

@patch
@pragma("wasm:entry-point")
class int {
  // A boxed int contains an unboxed int.
  int value = 0;
}

@patch
@pragma("wasm:entry-point")
class double {
  // A boxed double contains an unboxed double.
  double value = 0.0;
}
