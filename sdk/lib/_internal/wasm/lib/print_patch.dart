// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "internal_patch.dart";

@patch
void printToConsole(String line) {
  for (int i = 0; i < line.length; i++) {
    _printChar(line.codeUnitAt(i).toDouble());
  }
  _printChar(10);
}

void _printChar(double char) native "dart2wasm.printChar";
