// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "dart:_internal" show patch;

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
