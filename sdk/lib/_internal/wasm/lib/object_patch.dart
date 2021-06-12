// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "core_patch.dart";

int _getHash(Object obj) native "Object_getHash";
void _setHash(Object obj, int hash) native "Object_setHash";

@patch
class Object {
  // The VM has its own implementation of equals.
  @patch
  bool operator ==(Object other) native "Object_equals";

  // Helpers used to implement hashCode. If a hashCode is used, we remember it
  // in a weak table in the VM (32 bit) or in the header of the object (64
  // bit). A new hashCode value is calculated using a random number generator.
  static final _hashCodeRnd = new Random();

  static int _objectHashCode(Object obj) {
    var result = _getHash(obj);
    if (result == 0) {
      // We want the hash to be a Smi value greater than 0.
      do {
        result = _hashCodeRnd.nextInt(0x40000000);
      } while (result == 0);

      _setHash(obj, result);
      return result;
    }
    return result;
  }

  @patch
  int get hashCode => _objectHashCode(this);
  int get _identityHashCode => _objectHashCode(this);

  @patch
  String toString() => _toString(this);
  // A statically dispatched version of Object.toString.
  static String _toString(obj) => "Instance of '${obj.runtimeType}'";

  @patch
  @pragma("vm:entry-point", "call")
  dynamic noSuchMethod(Invocation invocation) {
    // TODO(regis): Remove temp constructor identifier 'withInvocation'.
    throw new NoSuchMethodError.withInvocation(this, invocation);
  }

  @patch
  // Result type is either "dart:core#_Type" or "dart:core#_FunctionType".
  Type get runtimeType native "Object_runtimeType";
}

// Used by DartLibraryCalls::Equals.
@pragma("vm:entry-point", "call")
bool _objectEquals(Object? o1, Object? o2) => o1 == o2;

// Used by DartLibraryCalls::HashCode.
@pragma("vm:entry-point", "call")
int _objectHashCode(Object? obj) => obj.hashCode;

// Used by DartLibraryCalls::ToString.
@pragma("vm:entry-point", "call")
String _objectToString(Object? obj) => obj.toString();

// Used by DartEntry::InvokeNoSuchMethod.
@pragma("vm:entry-point", "call")
dynamic _objectNoSuchMethod(Object? obj, Invocation invocation) =>
    obj.noSuchMethod(invocation);
