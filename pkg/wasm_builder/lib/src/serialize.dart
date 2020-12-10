// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

abstract class Serializer {
  void writeByte(int byte);
  void writeBytes(List<int> bytes);
  void writeSigned(int value);
  void writeUnsigned(int value);
  void writeF32(double value);
  void writeF64(double value);
  void writeName(String name);
  void write(Serializable object);
  void writeList(List<Serializable> objects);
}

abstract class Serializable {
  void serialize(Serializer s);
}

mixin SerializerMixin implements Serializer {
  Uint8List _data = Uint8List(100);
  int _index = 0;

  void _ensure(int size) {
    if (_data.length < _index + size) {
      int newLength = _data.length * 2;
      while (newLength < _index + size) newLength *= 2;
      _data = Uint8List(newLength)..setRange(0, _data.length, _data);
    }
  }

  void writeByte(int byte) {
    assert(byte == byte & 0xFF);
    _ensure(1);
    _data[_index++] = byte;
  }

  void writeBytes(List<int> bytes) {
    _ensure(bytes.length);
    _data.setRange(_index, _index += bytes.length, bytes);
  }

  void writeSigned(int value) {
    while (value < -0x40 || value >= 0x40) {
      writeByte((value & 0x7F) | 0x80);
      value >>= 7;
    }
    writeByte(value & 0x7F);
  }

  void writeUnsigned(int value) {
    assert(value >= 0);
    while (value >= 0x80) {
      writeByte((value & 0x7F) | 0x80);
      value >>= 7;
    }
    writeByte(value);
  }

  void writeF32(double value) {
    List<int> bytes = Float32List.fromList([value]).buffer.asUint8List();
    assert(bytes.length == 4);
    if (Endian.host == Endian.big) bytes = bytes.reversed.toList();
    writeBytes(bytes);
  }

  void writeF64(double value) {
    List<int> bytes = Float64List.fromList([value]).buffer.asUint8List();
    assert(bytes.length == 8);
    if (Endian.host == Endian.big) bytes = bytes.reversed.toList();
    writeBytes(bytes);
  }

  void writeName(String name) {
    List<int> bytes = utf8.encode(name);
    writeUnsigned(bytes.length);
    writeBytes(bytes);
  }

  void write(Serializable object) {
    object.serialize(this);
  }

  void writeList(List<Serializable> objects) {
    writeUnsigned(objects.length);
    for (int i = 0; i < objects.length; i++) write(objects[i]);
  }

  Uint8List get data => Uint8List.sublistView(_data, 0, _index);
}
