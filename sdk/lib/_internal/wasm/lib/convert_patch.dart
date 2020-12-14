// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "dart:_internal" show patch;

@patch
class _Utf8Decoder {
  // The VM decoder handles BOM explicitly instead of via the state machine.
  @patch
  _Utf8Decoder(this.allowMalformed) : _state = initial;
}
