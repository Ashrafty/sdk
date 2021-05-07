// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "core_patch.dart";

@patch
@pragma("wasm:entry-point")
class Map<K, V> {
  @patch
  factory Map.unmodifiable(Map other) {
    return new UnmodifiableMapView<K, V>(new Map<K, V>.from(other));
  }

  @patch
  @pragma("wasm:entry-point")
  factory Map() => new LinkedHashMap<K, V>();
}
