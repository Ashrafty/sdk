// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// This function can be used to skip implicit or explicit checked down casts in
// the parts of the core library implementation where we know by construction the
// type of a value.
//
// Important: this is unsafe and must be used with care.
T unsafeCast<T>(Object? v) native "Internal_unsafeCast";
