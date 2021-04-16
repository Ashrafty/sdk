// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "core_patch.dart";

@pragma("wasm:entry-point")
abstract class _ListBase<E> extends ListBase<E> {
  int _length;
  WasmObjectArray<Object?> _data;

  _ListBase(int length, int capacity)
      : _length = length,
        _data = WasmObjectArray<Object?>(capacity);

  _ListBase._withData(this._length, this._data);

  E operator [](int index) {
    return unsafeCast(_data.read(index));
  }

  void operator []=(int index, E value) {
    _data.write(index, value);
  }

  int get length => _length;

  // List interface.
  void setRange(int start, int end, Iterable<E> iterable, [int skipCount = 0]) {
    if (start < 0 || start > this.length) {
      throw new RangeError.range(start, 0, this.length);
    }
    if (end < start || end > this.length) {
      throw new RangeError.range(end, start, this.length);
    }
    int length = end - start;
    if (length == 0) return;
    if (identical(this, iterable)) {
      Lists.copy(this, skipCount, this, start, length);
    } else if (iterable is List<E>) {
      Lists.copy(iterable, skipCount, this, start, length);
    } else {
      Iterator<E> it = iterable.iterator;
      while (skipCount > 0) {
        if (!it.moveNext()) return;
        skipCount--;
      }
      for (int i = start; i < end; i++) {
        if (!it.moveNext()) return;
        this[i] = it.current;
      }
    }
  }

  void setAll(int index, Iterable<E> iterable) {
    if (index < 0 || index > this.length) {
      throw new RangeError.range(index, 0, this.length, "index");
    }
    List<E> iterableAsList;
    if (identical(this, iterable)) {
      iterableAsList = this;
    } else if (iterable is List<E>) {
      iterableAsList = iterable;
    } else {
      for (var value in iterable) {
        this[index++] = value;
      }
      return;
    }
    int length = iterableAsList.length;
    if (index + length > this.length) {
      throw new RangeError.range(index + length, 0, this.length);
    }
    Lists.copy(iterableAsList, 0, this, index, length);
  }

  List<E> sublist(int start, [int? end]) {
    final int listLength = this.length;
    final int actualEnd = RangeError.checkValidRange(start, end, listLength);
    int length = actualEnd - start;
    if (length == 0) return <E>[];
    return _GrowableList<E>(length)..setRange(0, length, this);
  }

  // Iterable interface.

  @pragma("vm:prefer-inline")
  void forEach(f(E element)) {
    final length = this.length;
    for (int i = 0; i < length; i++) {
      f(this[i]);
    }
  }

  @pragma("vm:prefer-inline")
  Iterator<E> get iterator {
    return new _FixedSizeArrayIterator<E>(this);
  }

  E get first {
    if (length > 0) return this[0];
    throw IterableElementError.noElement();
  }

  E get last {
    if (length > 0) return this[length - 1];
    throw IterableElementError.noElement();
  }

  E get single {
    if (length == 1) return this[0];
    if (length == 0) throw IterableElementError.noElement();
    throw IterableElementError.tooMany();
  }

  List<E> toList({bool growable: true}) {
    return List.from(this, growable: growable);
  }
}

@pragma("wasm:entry-point")
class _List<E> extends _ListBase<E> with FixedLengthListMixin<E> {
  _List._(int length) : super(length, length);

  factory _List(int length) => _List._(length);

  // Specialization of List.empty constructor for growable == false.
  // Used by pkg/vm/lib/transformations/list_factory_specializer.dart.
  @pragma("vm:prefer-inline")
  factory _List.empty() => _List<E>(0);

  // Specialization of List.filled constructor for growable == false.
  // Used by pkg/vm/lib/transformations/list_factory_specializer.dart.
  factory _List.filled(int length, E fill) {
    final result = _List<E>(length);
    if (fill != null) {
      for (int i = 0; i < result.length; i++) {
        result[i] = fill;
      }
    }
    return result;
  }

  // Specialization of List.generate constructor for growable == false.
  // Used by pkg/vm/lib/transformations/list_factory_specializer.dart.
  @pragma("vm:prefer-inline")
  factory _List.generate(int length, E generator(int index)) {
    final result = _List<E>(length);
    for (int i = 0; i < result.length; ++i) {
      result[i] = generator(i);
    }
    return result;
  }

  // Specialization of List.of constructor for growable == false.
  factory _List.of(Iterable<E> elements) {
    if (elements is _GrowableList) {
      return _List._ofGrowableList(unsafeCast(elements));
    }
    if (elements is _List) {
      return _List._ofList(unsafeCast(elements));
    }
    if (elements is _ImmutableList) {
      return _List._ofImmutableList(unsafeCast(elements));
    }
    if (elements is EfficientLengthIterable) {
      return _List._ofEfficientLengthIterable(unsafeCast(elements));
    }
    return _List._ofOther(elements);
  }

  factory _List._ofGrowableList(_GrowableList<E> elements) {
    final int length = elements.length;
    final list = _List<E>(length);
    for (int i = 0; i < length; i++) {
      list[i] = elements[i];
    }
    return list;
  }

  factory _List._ofList(_List<E> elements) {
    final int length = elements.length;
    final list = _List<E>(length);
    for (int i = 0; i < length; i++) {
      list[i] = elements[i];
    }
    return list;
  }

  factory _List._ofImmutableList(_ImmutableList<E> elements) {
    final int length = elements.length;
    final list = _List<E>(length);
    for (int i = 0; i < length; i++) {
      list[i] = elements[i];
    }
    return list;
  }

  factory _List._ofEfficientLengthIterable(
      EfficientLengthIterable<E> elements) {
    final int length = elements.length;
    final list = _List<E>(length);
    if (length > 0) {
      int i = 0;
      for (var element in elements) {
        list[i++] = element;
      }
      if (i != length) throw ConcurrentModificationError(elements);
    }
    return list;
  }

  factory _List._ofOther(Iterable<E> elements) {
    // The static type of `makeListFixedLength` is `List<E>`, not `_List<E>`,
    // but we know that is what it does.  `makeListFixedLength` is too generally
    // typed since it is available on the web platform which has different
    // system List types.
    return unsafeCast(makeListFixedLength(_GrowableList<E>._ofOther(elements)));
  }
}

// This is essentially the same class as _List, but it does not
// permit any modification of array elements from Dart code. We use
// this class for arrays constructed from Dart array literals.
// TODO(hausner): We should consider the trade-offs between two
// classes (and inline cache misses) versus a field in the native
// implementation (checks when modifying). We should keep watching
// the inline cache misses.
@pragma("vm:entry-point")
class _ImmutableList<E> extends UnmodifiableListBase<E> {
  factory _ImmutableList._uninstantiable() {
    throw new UnsupportedError(
        "ImmutableArray can only be allocated by the VM");
  }

  factory _ImmutableList._from(List from, int offset, int length)
      native "ImmutableList_from";

  @pragma("vm:recognized", "graph-intrinsic")
  E operator [](int index) native "List_getIndexed";

  @pragma("vm:recognized", "graph-intrinsic")
  @pragma("vm:prefer-inline")
  int get length native "List_getLength";

  List<E> sublist(int start, [int? end]) {
    final int actualEnd = RangeError.checkValidRange(start, end, this.length);
    int length = actualEnd - start;
    if (length == 0) return <E>[];
    final list = new _GrowableList<E>(length);
    for (int i = 0; i < length; i++) {
      list[i] = this[start + i];
    }
    return list;
  }

  // Collection interface.

  @pragma("vm:prefer-inline")
  void forEach(f(E element)) {
    final length = this.length;
    for (int i = 0; i < length; i++) {
      f(this[i]);
    }
  }

  @pragma("vm:prefer-inline")
  Iterator<E> get iterator {
    return new _FixedSizeArrayIterator<E>(this);
  }

  E get first {
    if (length > 0) return this[0];
    throw IterableElementError.noElement();
  }

  E get last {
    if (length > 0) return this[length - 1];
    throw IterableElementError.noElement();
  }

  E get single {
    if (length == 1) return this[0];
    if (length == 0) throw IterableElementError.noElement();
    throw IterableElementError.tooMany();
  }

  List<E> toList({bool growable: true}) {
    return List.from(this, growable: growable);
  }
}

// Iterator for arrays with fixed size.
class _FixedSizeArrayIterator<E> implements Iterator<E> {
  final List<E> _array;
  final int _length; // Cache array length for faster access.
  int _index;
  E? _current;

  _FixedSizeArrayIterator(List<E> array)
      : _array = array,
        _length = array.length,
        _index = 0 {
    assert(array is _List<E> || array is _ImmutableList<E>);
  }

  E get current => _current as E;

  @pragma("vm:prefer-inline")
  bool moveNext() {
    if (_index >= _length) {
      _current = null;
      return false;
    }
    _current = _array[_index];
    _index++;
    return true;
  }
}
