// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import "dart:typed_data" show Uint8List;

/// The returned string is a [_OneByteString] with uninitialized content.
@pragma("vm:recognized", "asm-intrinsic")
String allocateOneByteString(int length)
    native "Internal_allocateOneByteString";

/// The [string] must be a [_OneByteString]. The [index] must be valid.
@pragma("vm:recognized", "asm-intrinsic")
void writeIntoOneByteString(String string, int index, int codePoint)
    native "Internal_writeIntoOneByteString";

/// It is assumed that [from] is a native [Uint8List] class and [to] is a
/// [_OneByteString]. The [fromStart] and [toStart] indices together with the
/// [length] must specify ranges within the bounds of the list / string.
@pragma("vm:recognized", "other")
@pragma("vm:prefer-inline")
void copyRangeFromUint8ListToOneByteString(
    Uint8List from, String to, int fromStart, int toStart, int length) {
  for (int i = 0; i < length; i++) {
    writeIntoOneByteString(to, toStart + i, from[fromStart + i]);
  }
}

/// The returned string is a [_TwoByteString] with uninitialized content.
@pragma("vm:recognized", "asm-intrinsic")
String allocateTwoByteString(int length)
    native "Internal_allocateTwoByteString";

/// The [string] must be a [_TwoByteString]. The [index] must be valid.
@pragma("vm:recognized", "asm-intrinsic")
void writeIntoTwoByteString(String string, int index, int codePoint)
    native "Internal_writeIntoTwoByteString";

const bool has63BitSmis = false;

// Utility class now only used by the VM.
class Lists {
  @pragma("vm:prefer-inline")
  static void copy(List src, int srcStart, List dst, int dstStart, int count) {
    if (srcStart < dstStart) {
      for (int i = srcStart + count - 1, j = dstStart + count - 1;
          i >= srcStart;
          i--, j--) {
        dst[j] = src[i];
      }
    } else {
      for (int i = srcStart, j = dstStart; i < srcStart + count; i++, j++) {
        dst[j] = src[i];
      }
    }
  }
}

// This function can be used to skip implicit or explicit checked down casts in
// the parts of the core library implementation where we know by construction the
// type of a value.
//
// Important: this is unsafe and must be used with care.
T unsafeCast<T>(Object? v) native "Internal_unsafeCast";
