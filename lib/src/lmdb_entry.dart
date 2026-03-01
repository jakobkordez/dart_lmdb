import 'dart:ffi';

import 'lmdb_val.dart';

/// Represents an entry returned by cursor operations
class LMDBEntry {
  /// Key data
  final LMDBVal key;

  /// Data value
  final LMDBVal data;

  /// Creates a cursor entry with raw binary key and data
  LMDBEntry({required this.key, required this.data});

  @override
  String toString() =>
      'LMDBEntry(key: ${key.ptr.ref.mv_size} bytes, data: ${data.ptr.ref.mv_size} bytes)';

  // /// Returns a string representation with UTF-8 decoded contents
  // /// Throws FormatException if the data is not valid UTF-8
  // String toStringDecoded() =>
  //     'CursorEntry(key: $keyAsString, data: $dataAsString)';
}
