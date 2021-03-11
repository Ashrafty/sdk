// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "core_patch.dart";

@pragma("vm:entry-point")
class _GrowableList<T> extends _ListBase<T> {
  void insert(int index, T element) {
    if ((index < 0) || (index > length)) {
      throw new RangeError.range(index, 0, length);
    }
    int oldLength = this.length;
    add(element);
    if (index == oldLength) {
      return;
    }
    Lists.copy(this, index, this, index + 1, oldLength - index);
    this[index] = element;
  }

  T removeAt(int index) {
    var result = this[index];
    int newLength = this.length - 1;
    if (index < newLength) {
      Lists.copy(this, index + 1, this, index, newLength - index);
    }
    this.length = newLength;
    return result;
  }

  bool remove(Object? element) {
    for (int i = 0; i < this.length; i++) {
      if (this[i] == element) {
        removeAt(i);
        return true;
      }
    }
    return false;
  }

  void insertAll(int index, Iterable<T> iterable) {
    if (index < 0 || index > length) {
      throw new RangeError.range(index, 0, length);
    }
    // TODO(floitsch): we can probably detect more cases.
    if (iterable is! List && iterable is! Set && iterable is! SubListIterable) {
      iterable = iterable.toList();
    }
    int insertionLength = iterable.length;
    // There might be errors after the length change, in which case the list
    // will end up being modified but the operation not complete. Unless we
    // always go through a "toList" we can't really avoid that.
    int capacity = _capacity;
    int newLength = length + insertionLength;
    if (newLength > capacity) {
      do {
        capacity = _nextCapacity(capacity);
      } while (newLength > capacity);
      _grow(capacity);
    }
    _setLength(newLength);
    setRange(index + insertionLength, this.length, this, index);
    setAll(index, iterable);
  }

  void removeRange(int start, int end) {
    RangeError.checkValidRange(start, end, this.length);
    Lists.copy(this, end, this, start, this.length - end);
    this.length = this.length - (end - start);
  }

  _GrowableList._(int length, int capacity) : super(length, capacity);

  factory _GrowableList(int length) {
    return _GrowableList<T>._(length, length);
  }

  factory _GrowableList.withCapacity(int capacity) {
    return _GrowableList<T>._(0, capacity);
  }

  // Specialization of List.empty constructor for growable == true.
  // Used by pkg/vm/lib/transformations/list_factory_specializer.dart.
  @pragma("vm:prefer-inline")
  factory _GrowableList.empty() => _GrowableList(0);

  // Specialization of List.filled constructor for growable == true.
  // Used by pkg/vm/lib/transformations/list_factory_specializer.dart.
  factory _GrowableList.filled(int length, T fill) {
    final result = _GrowableList<T>(length);
    if (fill != null) {
      for (int i = 0; i < result.length; i++) {
        result[i] = fill;
      }
    }
    return result;
  }

  // Specialization of List.generate constructor for growable == true.
  // Used by pkg/vm/lib/transformations/list_factory_specializer.dart.
  @pragma("vm:prefer-inline")
  factory _GrowableList.generate(int length, T generator(int index)) {
    final result = _GrowableList<T>(length);
    for (int i = 0; i < result.length; ++i) {
      result[i] = generator(i);
    }
    return result;
  }

  // Specialization of List.of constructor for growable == true.
  factory _GrowableList.of(Iterable<T> elements) {
    if (elements is _GrowableList) {
      return _GrowableList._ofGrowableList(unsafeCast(elements));
    }
    if (elements is _List) {
      return _GrowableList._ofList(unsafeCast(elements));
    }
    if (elements is _ImmutableList) {
      return _GrowableList._ofImmutableList(unsafeCast(elements));
    }
    if (elements is EfficientLengthIterable) {
      return _GrowableList._ofEfficientLengthIterable(unsafeCast(elements));
    }
    return _GrowableList._ofOther(elements);
  }

  factory _GrowableList._ofList(_List<T> elements) {
    final int length = elements.length;
    final list = _GrowableList<T>(length);
    for (int i = 0; i < length; i++) {
      list[i] = elements[i];
    }
    return list;
  }

  factory _GrowableList._ofGrowableList(_GrowableList<T> elements) {
    final int length = elements.length;
    final list = _GrowableList<T>(length);
    for (int i = 0; i < length; i++) {
      list[i] = elements[i];
    }
    return list;
  }

  factory _GrowableList._ofImmutableList(_ImmutableList<T> elements) {
    final int length = elements.length;
    final list = _GrowableList<T>(length);
    for (int i = 0; i < length; i++) {
      list[i] = elements[i];
    }
    return list;
  }

  factory _GrowableList._ofEfficientLengthIterable(
      EfficientLengthIterable<T> elements) {
    final int length = elements.length;
    final list = _GrowableList<T>(length);
    if (length > 0) {
      int i = 0;
      for (var element in elements) {
        list[i++] = element;
      }
      if (i != length) throw ConcurrentModificationError(elements);
    }
    return list;
  }

  factory _GrowableList._ofOther(Iterable<T> elements) {
    final list = _GrowableList<T>(0);
    for (var elements in elements) {
      list.add(elements);
    }
    return list;
  }

  _GrowableList._withData(WasmObjectArray<Object?> data)
      : super._withData(data.length, data);

  int get _capacity => _data.length;

  void set length(int new_length) {
    if (new_length > length) {
      // Verify that element type is nullable.
      null as T;
      if (new_length > _capacity) {
        _grow(new_length);
      }
      _setLength(new_length);
      return;
    }
    final int new_capacity = new_length;
    // We are shrinking. Pick the method which has fewer writes.
    // In the shrink-to-fit path, we write |new_capacity + new_length| words
    // (null init + copy).
    // In the non-shrink-to-fit path, we write |length - new_length| words
    // (null overwrite).
    final bool shouldShrinkToFit =
        (new_capacity + new_length) < (length - new_length);
    if (shouldShrinkToFit) {
      _shrink(new_capacity, new_length);
    } else {
      for (int i = new_length; i < length; i++) {
        _data.write(i, null);
      }
    }
    _setLength(new_length);
  }

  void _setLength(int new_length) {
    _length = new_length;
  }

  @pragma("vm:entry-point", "call")
  @pragma("vm:prefer-inline")
  void add(T value) {
    var len = length;
    if (len == _capacity) {
      _growToNextCapacity();
    }
    _setLength(len + 1);
    this[len] = value;
  }

  void addAll(Iterable<T> iterable) {
    var len = length;
    if (iterable is EfficientLengthIterable) {
      if (identical(iterable, this)) {
        throw new ConcurrentModificationError(this);
      }
      var cap = _capacity;
      // Pregrow if we know iterable.length.
      var iterLen = iterable.length;
      if (iterLen == 0) {
        return;
      }
      var newLen = len + iterLen;
      if (newLen > cap) {
        do {
          cap = _nextCapacity(cap);
        } while (newLen > cap);
        _grow(cap);
      }
    }
    Iterator it = iterable.iterator;
    if (!it.moveNext()) return;
    do {
      while (len < _capacity) {
        int newLen = len + 1;
        this._setLength(newLen);
        this[len] = it.current;
        if (!it.moveNext()) return;
        if (this.length != newLen) throw new ConcurrentModificationError(this);
        len = newLen;
      }
      _growToNextCapacity();
    } while (true);
  }

  @pragma("vm:prefer-inline")
  T removeLast() {
    var len = length - 1;
    var elem = this[len];
    this.length = len;
    return elem;
  }

  T get first {
    if (length > 0) return this[0];
    throw IterableElementError.noElement();
  }

  T get last {
    if (length > 0) return this[length - 1];
    throw IterableElementError.noElement();
  }

  T get single {
    if (length == 1) return this[0];
    if (length == 0) throw IterableElementError.noElement();
    throw IterableElementError.tooMany();
  }

  // Shared array used as backing for new empty growable arrays.
  static final WasmObjectArray<Object?> _emptyData =
      WasmObjectArray<Object?>(0);

  static WasmObjectArray<Object?> _allocateData(int capacity) {
    if (capacity == 0) {
      // Use shared empty list as backing.
      return _emptyData;
    }
    return new WasmObjectArray<Object?>(capacity);
  }

  // Grow from 0 to 3, and then double + 1.
  int _nextCapacity(int old_capacity) => (old_capacity * 2) | 3;

  void _grow(int new_capacity) {
    var newData = WasmObjectArray<Object?>(new_capacity);
    for (int i = 0; i < length; i++) {
      newData.write(i, this[i]);
    }
    _data = newData;
  }

  // This method is marked as never-inline to conserve code size.
  // It is called in rare cases, but used in the add() which is
  // used very often and always inlined.
  @pragma("vm:never-inline")
  void _growToNextCapacity() {
    _grow(_nextCapacity(_capacity));
  }

  void _shrink(int new_capacity, int new_length) {
    var newData = _allocateData(new_capacity);
    // This is a work-around for dartbug.com/30090. See the comment in _grow.
    if (new_length > 0) {
      for (int i = 0; i < new_length; i++) {
        newData.write(i, this[i]);
      }
    }
    _data = newData;
  }

  // Iterable interface.

  @pragma("vm:prefer-inline")
  void forEach(f(T element)) {
    int initialLength = length;
    for (int i = 0; i < length; i++) {
      f(this[i]);
      if (length != initialLength) throw new ConcurrentModificationError(this);
    }
  }

  String join([String separator = ""]) {
    final int length = this.length;
    if (length == 0) return "";
    if (length == 1) return "${this[0]}";
    if (separator.isNotEmpty) return _joinWithSeparator(separator);
    var i = 0;
    var codeUnitCount = 0;
    while (i < length) {
      final element = this[i];
      // While list contains one-byte strings.
      if (element is _OneByteString) {
        codeUnitCount += element.length;
        i++;
        // Loop back while strings are one-byte strings.
        continue;
      }
      // Otherwise, never loop back to the outer loop, and
      // handle the remaining strings below.

      // Loop while elements are strings,
      final int firstNonOneByteStringLimit = i;
      var nextElement = element;
      while (nextElement is String) {
        i++;
        if (i == length) {
          return _StringBase._concatRangeNative(this, 0, length);
        }
        nextElement = this[i];
      }

      // Not all elements are strings, so allocate a new backing array.
      final list = new _List(length);
      for (int copyIndex = 0; copyIndex < i; copyIndex++) {
        list[copyIndex] = this[copyIndex];
      }
      // Is non-zero if list contains a non-onebyte string.
      bool onebyteCanary = i > firstNonOneByteStringLimit;
      while (true) {
        final String elementString = "$nextElement";
        onebyteCanary |= elementString is _OneByteString;
        list[i] = elementString;
        codeUnitCount += elementString.length;
        i++;
        if (i == length) break;
        nextElement = this[i];
      }
      if (onebyteCanary) {
        // All elements returned a one-byte string from toString.
        return _OneByteString._concatAll(list, codeUnitCount);
      }
      return _StringBase._concatRangeNative(list, 0, length);
    }
    // All elements were one-byte strings.
    return _OneByteString._concatAll(this, codeUnitCount);
  }

  String _joinWithSeparator(String separator) {
    StringBuffer buffer = new StringBuffer();
    buffer.write(this[0]);
    for (int i = 1; i < this.length; i++) {
      buffer.write(separator);
      buffer.write(this[i]);
    }
    return buffer.toString();
  }

  T elementAt(int index) {
    return this[index];
  }

  bool get isEmpty {
    return this.length == 0;
  }

  bool get isNotEmpty => !isEmpty;

  void clear() {
    this.length = 0;
  }

  String toString() => ListBase.listToString(this);

  @pragma("vm:prefer-inline")
  Iterator<T> get iterator {
    return new ListIterator<T>(this);
  }

  Set<T> toSet() {
    return new Set<T>.of(this);
  }

  // Factory constructing a mutable List from a parser generated List literal.
  // [elements] contains elements that are already type checked.
  @pragma("vm:entry-point", "call")
  factory _GrowableList._literal(_List elements) {
    return _GrowableList<T>._withData(elements._data);
  }

  // Specialized list literal constructors.
  // Used by pkg/vm/lib/transformations/list_literals_lowering.dart.
  factory _GrowableList._literal1(T e0) {
    WasmObjectArray<Object?> elements = WasmObjectArray<Object?>(1);
    elements.write(0, e0);
    return _GrowableList<T>._withData(elements);
  }

  factory _GrowableList._literal2(T e0, T e1) {
    WasmObjectArray<Object?> elements = WasmObjectArray<Object?>(2);
    elements.write(0, e0);
    elements.write(1, e1);
    return _GrowableList<T>._withData(elements);
  }

  factory _GrowableList._literal3(T e0, T e1, T e2) {
    WasmObjectArray<Object?> elements = WasmObjectArray<Object?>(3);
    elements.write(0, e0);
    elements.write(1, e1);
    elements.write(2, e2);
    return _GrowableList<T>._withData(elements);
  }

  factory _GrowableList._literal4(T e0, T e1, T e2, T e3) {
    WasmObjectArray<Object?> elements = WasmObjectArray<Object?>(4);
    elements.write(0, e0);
    elements.write(1, e1);
    elements.write(2, e2);
    elements.write(3, e3);
    return _GrowableList<T>._withData(elements);
  }

  factory _GrowableList._literal5(T e0, T e1, T e2, T e3, T e4) {
    WasmObjectArray<Object?> elements = WasmObjectArray<Object?>(5);
    elements.write(0, e0);
    elements.write(1, e1);
    elements.write(2, e2);
    elements.write(3, e3);
    elements.write(4, e4);
    return _GrowableList<T>._withData(elements);
  }

  factory _GrowableList._literal6(T e0, T e1, T e2, T e3, T e4, T e5) {
    WasmObjectArray<Object?> elements = WasmObjectArray<Object?>(6);
    elements.write(0, e0);
    elements.write(1, e1);
    elements.write(2, e2);
    elements.write(3, e3);
    elements.write(4, e4);
    elements.write(5, e5);
    return _GrowableList<T>._withData(elements);
  }

  factory _GrowableList._literal7(T e0, T e1, T e2, T e3, T e4, T e5, T e6) {
    WasmObjectArray<Object?> elements = WasmObjectArray<Object?>(7);
    elements.write(0, e0);
    elements.write(1, e1);
    elements.write(2, e2);
    elements.write(3, e3);
    elements.write(4, e4);
    elements.write(5, e5);
    elements.write(6, e6);
    return _GrowableList<T>._withData(elements);
  }

  factory _GrowableList._literal8(
      T e0, T e1, T e2, T e3, T e4, T e5, T e6, T e7) {
    WasmObjectArray<Object?> elements = WasmObjectArray<Object?>(8);
    elements.write(0, e0);
    elements.write(1, e1);
    elements.write(2, e2);
    elements.write(3, e3);
    elements.write(4, e4);
    elements.write(5, e5);
    elements.write(6, e6);
    elements.write(7, e7);
    return _GrowableList<T>._withData(elements);
  }
}
