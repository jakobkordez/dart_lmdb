import 'dart:ffi';

import 'package:dart_lmdb/src/generated_bindings.dart';
import 'package:ffi/ffi.dart';

class LMDBVal {
  static final _finalizer = Finalizer<Pointer>(calloc.free);

  final Pointer<MDB_val> _ptr;
  final Pointer<Void>? _bytesPtr;

  Pointer<MDB_val> get ptr => _ptr;

  LMDBVal._(this._ptr, this._bytesPtr) {
    // print('creating ${_ptr.address}');
    _finalizer.attach(this, _ptr, detach: this);
    if (_bytesPtr != null) _finalizer.attach(this, _bytesPtr, detach: this);
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

  String toStringUtf8() {
    return _ptr.ref.mv_data.cast<Utf8>().toDartString(length: _ptr.ref.mv_size);
  }

  List<int> toBytes() {
    return _ptr.ref.mv_data.cast<Uint8>().asTypedList(_ptr.ref.mv_size);
  }
}
