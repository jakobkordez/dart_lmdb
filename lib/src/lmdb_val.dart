import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_lmdb/src/generated_bindings.dart';
import 'package:ffi/ffi.dart';

class LMDBVal implements Comparable<LMDBVal> {
  static final _finalizer = Finalizer<Pointer>(calloc.free);

  final Pointer<MDB_val> _ptr;
  final Pointer<Void>? _bytesPtr;

  Pointer<MDB_val> get ptr => _ptr;

  LMDBVal._(this._ptr, this._bytesPtr) {
    // print('creating ${_ptr.address}');
    _finalizer.attach(this, _ptr, detach: this);
    if (_bytesPtr != null) _finalizer.attach(this, _bytesPtr, detach: this);
  }

  void dispose() {
    _finalizer.detach(this);
    calloc.free(_ptr);
    if (_bytesPtr != null) {
      calloc.free(_bytesPtr);
    }
  }

  LMDBVal.empty() : this._(calloc<MDB_val>(), null);

  factory LMDBVal.fromUtf8(String value) {
    final ptr = calloc<MDB_val>();
    final data = value.toNativeUtf8();
    ptr.ref.mv_size = data.length;
    ptr.ref.mv_data = data.cast();
    return LMDBVal._(ptr, data.cast());
  }

  factory LMDBVal.fromBytes(List<int> bytes) {
    final ptr = calloc<MDB_val>();
    final data = calloc<Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    ptr.ref.mv_size = bytes.length;
    ptr.ref.mv_data = data.cast();
    return LMDBVal._(ptr, data.cast());
  }

  LMDBVal copy() {
    final ptr = calloc<MDB_val>();
    ptr.ref.mv_size = _ptr.ref.mv_size;
    ptr.ref.mv_data = _ptr.ref.mv_data.cast();
    return LMDBVal._(ptr, null);
  }

  String toUtf8String() {
    return _ptr.ref.mv_data.cast<Utf8>().toDartString(length: _ptr.ref.mv_size);
  }

  Uint8List asBytes({bool copy = true}) {
    final r = _ptr.ref.mv_data.cast<Uint8>().asTypedList(_ptr.ref.mv_size);
    if (!copy) return r;
    return Uint8List.fromList(r);
  }

  @override
  int compareTo(LMDBVal other) {
    final a = asBytes(copy: false);
    final b = other.asBytes(copy: false);
    final n = min(a.length, b.length);
    for (var i = 0; i < n; i++) {
      final diff = a[i] - b[i];
      if (diff != 0) return diff;
    }
    return a.length - b.length;
  }
}
