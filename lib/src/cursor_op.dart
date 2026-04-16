import 'generated_bindings.dart';
import 'lmdb_flags.dart';

/// Public cursor operation modes for LMDB
enum CursorOp {
  /// Position at first key/data item
  first(MDB_cursor_op.MDB_FIRST),

  /// Position at first data item of current key (only for [LMDBDbiFlag.dupSort] databases)
  firstDup(MDB_cursor_op.MDB_FIRST_DUP),

  /// Position at key/data pair (only for [LMDBDbiFlag.dupSort] databases)
  getBoth(MDB_cursor_op.MDB_GET_BOTH),

  /// Position at key, nearest data (only for [LMDBDbiFlag.dupSort] databases)
  getBothRange(MDB_cursor_op.MDB_GET_BOTH_RANGE),

  /// Return key/data at current cursor position
  getCurrent(MDB_cursor_op.MDB_GET_CURRENT),

  /// Return up to a page of duplicate data items from the current cursor position;
  /// moves the cursor to prepare for [nextMultiple] (only for [LMDBDbiFlag.dupFixed] databases).
  getMultiple(MDB_cursor_op.MDB_GET_MULTIPLE),

  /// Position at last key/data item
  last(MDB_cursor_op.MDB_LAST),

  /// Position at last data item of current key (only for [LMDBDbiFlag.dupSort] databases)
  lastDup(MDB_cursor_op.MDB_LAST_DUP),

  /// Position at next data item
  next(MDB_cursor_op.MDB_NEXT),

  /// Position at next data item of current key (only for [LMDBDbiFlag.dupSort] databases)
  nextDup(MDB_cursor_op.MDB_NEXT_DUP),

  /// Return up to a page of duplicate data items from the next cursor position;
  /// moves the cursor to prepare for [getMultiple] (only for [LMDBDbiFlag.dupFixed] databases).
  nextMultiple(MDB_cursor_op.MDB_NEXT_MULTIPLE),

  /// Position at first data item of next key
  nextNoDup(MDB_cursor_op.MDB_NEXT_NODUP),

  /// Position at previous data item
  prev(MDB_cursor_op.MDB_PREV),

  /// Position at previous data item of current key (only for [LMDBDbiFlag.dupSort] databases)
  prevDup(MDB_cursor_op.MDB_PREV_DUP),

  /// Position at last data item of previous key
  prevNoDup(MDB_cursor_op.MDB_PREV_NODUP),

  /// Position at specified key
  set(MDB_cursor_op.MDB_SET),

  /// Position at specified key, return key + data
  setKey(MDB_cursor_op.MDB_SET_KEY),

  /// Position at first key greater than or equal to specified key
  setRange(MDB_cursor_op.MDB_SET_RANGE),

  /// Position at previous page and return up to a page of duplicate data items
  /// Only for [LMDBDbiFlag.dupFixed] databases
  prevMultiple(MDB_cursor_op.MDB_PREV_MULTIPLE);

  /// Internal value used by LMDB
  final MDB_cursor_op value;
  const CursorOp(this.value);
}
