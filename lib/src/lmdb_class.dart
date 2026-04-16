import 'dart:ffi';
import 'dart:io';

import 'package:dart_lmdb/src/lmdb_val.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'generated_bindings.dart';
import 'lmdb_entry.dart';
import 'lmdb_exception.dart';
import 'database_stats.dart';
import 'lmdb_config.dart';
import 'cursor_op.dart';
import 'lmdb_flags.dart';
import 'lmdb_native.dart';

final LMDBBindings _lib = LMDBNative.instance.lib;

/// High-level Dart API for [LMDB](https://symas.com/lmdb/) (Lightning Memory-Mapped Database).
///
/// Features:
/// * Optional automatic transaction wrapping ([withTransaction], [put], [get], …)
/// * [LMDBVal] byte keys and values
/// * Named sub-databases via [LMDBTransaction.getDatabase]
/// * Environment and per-database statistics ([stats], [getEnvironmentStats])
///
/// Basic usage with auto-managed transactions:
/// ```dart
/// final db = LMDB();
/// db.init('/path/to/db');
///
/// final key = LMDBVal.fromUtf8('key');
/// final value = LMDBVal.fromUtf8('value');
/// db.put(key, value);
///
/// final found = db.get(key);
/// // … use found …
///
/// key.dispose();
/// value.dispose();
/// found?.dispose();
///
/// db.close();
/// ```
///
/// Explicit transaction:
/// ```dart
/// final db = LMDB();
/// db.init('/path/to/db');
///
/// final txn = db.txnStart();
/// try {
///   txn.put(LMDBVal.fromUtf8('k1'), LMDBVal.fromUtf8('v1'));
///   txn.put(LMDBVal.fromUtf8('k2'), LMDBVal.fromUtf8('v2'));
///   txn.commit();
/// } catch (e) {
///   txn.abort();
///   rethrow;
/// }
/// ```
class LMDB {
  /// Native `MDB_env*` handle; null before [init] or after [close].
  Pointer<MDB_env>? _env;

  Pointer<MDB_env> _ensureInitialized() {
    if (_env == null) throw StateError('Database not initialized');
    return _env!;
  }

  static const String _defaultMode = "0664";
  static const int _defaultMaxDbs = 1;

  /// Open DBI handles keyed by optional sub-database name (shared with transactions).
  final Map<String?, int> _dbiCache = {};

  /// Creates an instance; call [init] before use.
  LMDB();

  /// Opens or creates an LMDB environment at [dbPath].
  ///
  /// The parent directory is created when missing. With [LMDBEnvFlag.noSubdir] in [flags],
  /// [dbPath] is a file path and the parent directory is created instead.
  ///
  /// [config] sets map size, max readers, max sub-databases, and Unix file mode.
  /// ```dart
  /// db.init(
  ///   '/path/to/db',
  ///   config: LMDBInitConfig(
  ///     mapSize: 10 * 1024 * 1024,
  ///     maxDbs: 5,
  ///     mode: '0644',
  ///   ),
  /// );
  /// ```
  ///
  /// [flags] are passed to `mdb_env_open` (e.g. [LMDBEnvFlag.noSubdir], [LMDBEnvFlag.noSync]):
  /// ```dart
  /// db.init(
  ///   '/path/to/db',
  ///   flags: {
  ///     LMDBEnvFlag.noSubdir,
  ///     LMDBEnvFlag.noSync,
  ///   },
  /// );
  /// ```
  ///
  /// Presets such as [LMDBFlagSet.readOnly] and [LMDBFlagSet.highPerformance] are available.
  ///
  /// Defaults when [config] is omitted: [LMDBConfig.minMapSize], `maxDbs: 1`, mode `0664`.
  ///
  /// Throws [StateError] if the environment is already open ([close] it first).
  ///
  /// Throws [LMDBException] if the native environment cannot be created, sized, or opened.
  ///
  /// ```dart
  /// final db = LMDB();
  /// db.init('/path/to/db');
  /// db.init(
  ///   '/path/to/file.mdb',
  ///   config: LMDBInitConfig(mapSize: 1024 * 1024 * 1024),
  ///   flags: {LMDBEnvFlag.noSubdir},
  /// );
  /// db.close();
  /// ```
  void init(String dbPath, {LMDBInitConfig? config, LMDBEnvFlagSet? flags}) {
    if (_env != null) throw StateError('Database already initialized');

    final effectiveFlags = flags ?? {};
    final effectiveConfig =
        config ??
        LMDBInitConfig(
          mapSize: LMDBConfig.minMapSize,
          maxDbs: _defaultMaxDbs,
          mode: _defaultMode,
        );

    // Determine if we're in NOSUBDIR mode
    if (effectiveFlags.contains(LMDBEnvFlag.noSubdir)) {
      // For NOSUBDIR mode, ensure parent directory exists
      final parentDir = Directory(path.dirname(dbPath));
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }
    } else {
      // Normal mode: create directory if it doesn't exist
      final dir = Directory(dbPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
    }

    return using((arena) {
      final envPtr = arena<Pointer<MDB_env>>();

      final result = _lib.mdb_env_create(envPtr);
      if (result != 0) {
        throw LMDBException('Failed to create environment', result);
      }

      _env = envPtr.value;
      final env = _env!;

      try {
        final setSizeResult = _lib.mdb_env_set_mapsize(
          env,
          effectiveConfig.mapSize,
        );

        if (setSizeResult != 0) {
          throw LMDBException('Failed to set map size', setSizeResult);
        }

        if (effectiveConfig.maxDbs > 1) {
          final setDbsResult = _lib.mdb_env_set_maxdbs(
            env,
            effectiveConfig.maxDbs,
          );

          if (setDbsResult != 0) {
            throw LMDBException('Failed to set max DBs', setDbsResult);
          }
        }

        final setMaxReadersResult = _lib.mdb_env_set_maxreaders(
          env,
          effectiveConfig.maxReaders,
        );

        if (setMaxReadersResult != 0) {
          throw LMDBException('Failed to set max readers', setMaxReadersResult);
        }

        final pathPtr = dbPath.toNativeUtf8(allocator: arena);
        final openResult = _lib.mdb_env_open(
          env,
          pathPtr.cast(),
          effectiveFlags.value,
          effectiveConfig.modeAsInt,
        );

        if (openResult != 0) {
          throw LMDBException('Failed to open environment', openResult);
        }
      } catch (e) {
        _lib.mdb_env_close(_env!);
        _env = null;
        rethrow;
      }
    });
  }

  /// Closes the environment and clears cached DBI handles.
  ///
  /// Call [init] again on this instance, or use a new [LMDB], before further use.
  void close() {
    if (_env != null) {
      _lib.mdb_env_close(_env!);
      _env = null;
      _dbiCache.clear();
    }
  }

  /// Begins a transaction; all reads and writes go through [LMDBTransaction] or [withTransaction].
  ///
  /// - [parent]: optional nested transaction (child must finish before the parent).
  /// - [flags]: e.g. [LMDBEnvFlag.readOnly] for readers, [LMDBEnvFlag.noSync] to reduce durability on commit.
  ///
  /// Pair every call with [LMDBTransaction.commit] or [LMDBTransaction.abort]. Only one
  /// write transaction may run at a time per environment; many read transactions can overlap.
  ///
  /// ```dart
  /// final txn = db.txnStart();
  /// try {
  ///   txn.put(LMDBVal.fromUtf8('key'), LMDBVal.fromUtf8('value'));
  ///   txn.commit();
  /// } catch (e) {
  ///   txn.abort();
  ///   rethrow;
  /// }
  ///
  /// final readTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
  /// try {
  ///   final v = readTxn.get(LMDBVal.fromUtf8('key'));
  ///   readTxn.commit();
  /// } catch (e) {
  ///   readTxn.abort();
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Throws [StateError] if the environment is not initialized.
  ///
  /// Throws [LMDBException] if `mdb_txn_begin` fails.
  LMDBTransaction txnStart({LMDBTransaction? parent, LMDBEnvFlagSet? flags}) {
    final env = _ensureInitialized();

    return using((arena) {
      final txnPtr = arena<Pointer<MDB_txn>>();

      final result = _lib.mdb_txn_begin(
        env,
        parent?._ptr ?? nullptr,
        flags?.value ?? 0,
        txnPtr,
      );

      if (result != 0) {
        throw LMDBException('Failed to start transaction', result);
      }

      return LMDBTransaction._(this, txnPtr.value);
    });
  }

  /// Runs [action] inside a new transaction from [txnStart].
  ///
  /// On success: [LMDBTransaction.commit] for read-write, or [LMDBTransaction.abort] when
  /// [flags] contains [LMDBEnvFlag.readOnly] (read-only “commit” is still an abort at the LMDB level).
  /// On error: [LMDBTransaction.abort] then rethrows.
  T withTransaction<T>(
    T Function(LMDBTransaction txn) action, {
    LMDBEnvFlagSet? flags,
  }) {
    final txn = txnStart(flags: flags);
    try {
      final result = action(txn);
      if (flags?.contains(LMDBEnvFlag.readOnly) ?? false) {
        txn.abort();
      } else {
        txn.commit();
      }
      return result;
    } catch (e) {
      txn.abort();
      rethrow;
    }
  }

  /// Stores [value] under [key] in one write transaction ([withTransaction]).
  ///
  /// [dbName] selects a sub-database; [dbFlags] are passed to [LMDBTransaction.getDatabase];
  /// [flags] go to [LMDBDatabase.put].
  ///
  /// ```dart
  /// db.put(LMDBVal.fromUtf8('k'), LMDBVal.fromBytes([1, 2, 3, 4]));
  /// ```
  ///
  /// Throws [StateError] if the environment is not open.
  ///
  /// Throws [LMDBException] if the put fails.
  void put(
    LMDBVal key,
    LMDBVal value, {
    String? dbName,
    LMDBDbiFlagSet? dbFlags,
    LMDBWriteFlagSet? flags,
  }) => withTransaction(
    (txn) =>
        txn.put(key, value, dbName: dbName, dbFlags: dbFlags, flags: flags),
  );

  /// Reads [key] in a read-only transaction; returns `null` if missing ([MDB_NOTFOUND]).
  ///
  /// ```dart
  /// final v = db.get(LMDBVal.fromUtf8('key'));
  /// ```
  ///
  /// Throws [StateError] if the environment is not open.
  ///
  /// Throws [LMDBException] on other LMDB errors.
  LMDBVal? get(LMDBVal key, {String? dbName, LMDBDbiFlagSet? dbFlags}) =>
      withTransaction(
        (txn) => txn.get(key, dbName: dbName, dbFlags: dbFlags),
        flags: LMDBFlagSet.readOnly,
      );

  /// Removes [key] in one write transaction.
  ///
  /// ```dart
  /// db.delete(LMDBVal.fromUtf8('key'));
  /// ```
  ///
  /// Throws [StateError] if the environment is not open.
  ///
  /// Throws [LMDBException] if the delete fails.
  void delete(LMDBVal key, {String? dbName, LMDBDbiFlagSet? dbFlags}) =>
      withTransaction(
        (txn) => txn.delete(key, dbName: dbName, dbFlags: dbFlags),
      );

  /// Returns [DatabaseStats] for the default or named database in a read-only transaction.
  ///
  /// ```dart
  /// final s = db.stats();
  /// print('${s.entries} entries, depth ${s.depth}');
  /// ```
  ///
  /// Throws [StateError] if the environment is not open.
  ///
  /// Throws [LMDBException] if `mdb_stat` fails.
  DatabaseStats stats({String? dbName, LMDBDbiFlagSet? dbFlags}) =>
      withTransaction(
        (txn) => txn.stats(dbName: dbName, dbFlags: dbFlags),
        flags: LMDBFlagSet.readOnly,
      );

  /// LMDB library version string (e.g. `LMDB x.y.z`).
  static String getVersion() {
    final verPtr = _lib.mdb_version(nullptr, nullptr, nullptr);
    return verPtr.cast<Utf8>().toDartString();
  }

  /// Human-readable message for an LMDB result code (`mdb_strerror`).
  static String getErrorString(int err) {
    final ptr = _lib.mdb_strerror(err);
    return ptr.cast<Utf8>().toDartString();
  }

  /// Flushes the environment to disk (`mdb_env_sync`).
  ///
  /// [force] maps to LMDB’s synchronous flag.
  void sync(bool force) {
    final env = _ensureInitialized();
    final result = _lib.mdb_env_sync(env, force ? 1 : 0);
    if (result != 0) {
      throw LMDBException('Failed to sync environment', result);
    }
  }

  /// Aggregated stats for the whole environment (`mdb_env_stat`), not a single sub-database.
  ///
  /// Throws [StateError] if the environment is not open.
  ///
  /// Throws [LMDBException] if `mdb_env_stat` fails.
  DatabaseStats getEnvironmentStats() {
    final env = _ensureInitialized();

    return using((arena) {
      final statPtr = arena<MDB_stat>();

      final result = _lib.mdb_env_stat(env, statPtr);

      if (result != 0) {
        throw LMDBException('Failed to get environment statistics', result);
      }

      return DatabaseStats(
        pageSize: statPtr.ref.ms_psize,
        depth: statPtr.ref.ms_depth,
        branchPages: statPtr.ref.ms_branch_pages,
        leafPages: statPtr.ref.ms_leaf_pages,
        overflowPages: statPtr.ref.ms_overflow_pages,
        entries: statPtr.ref.ms_entries,
      );
    });
  }

  /// Copies the environment to [path] (`mdb_env_copy`); useful for hot backups.
  ///
  /// A new lockfile may appear at the destination when that environment is opened later.
  void copy(String path) => using((arena) {
    final env = _ensureInitialized();
    final pathPtr = path.toNativeUtf8(allocator: arena);
    final result = _lib.mdb_env_copy(env, pathPtr.cast());
    if (result != 0) throw LMDBException('Failed to copy environment', result);
  });

  /// Same as [close]; use in `finally` blocks when implementing lifecycle helpers.
  void dispose() => close();
}

/// One LMDB transaction; obtain via [LMDB.txnStart] or [LMDB.withTransaction].
class LMDBTransaction {
  final LMDB _db;
  final Pointer<MDB_txn> _ptr;

  /// Cached DBI handles for this transaction (merged into the environment on [commit]).
  final Map<String?, int> _dbiCache = {};

  LMDBTransaction._(this._db, this._ptr);

  /// Opaque transaction id (`mdb_txn_id`).
  int getId() => _lib.mdb_txn_id(_ptr);

  /// Opens or returns the [LMDBDatabase] for [name] (`mdb_dbi_open`)
  ///
  /// if [flags] is not provided, [LMDBDbiFlag.create] is used.
  LMDBDatabase getDatabase({String? name, LMDBDbiFlagSet? flags}) {
    final dbi = _dbiCache[name] ??=
        _db._dbiCache[name] ??
        using((arena) {
          final dbiPtr = arena<MDB_dbi>();
          final namePtr = name?.toNativeUtf8(allocator: arena);

          final effectiveFlags = (flags ?? const {LMDBDbiFlag.create}).value;

          final result = _lib.mdb_dbi_open(
            _ptr,
            namePtr?.cast() ?? nullptr,
            effectiveFlags,
            dbiPtr,
          );

          if (result != 0) {
            throw LMDBException('Failed to open database', result);
          }

          final dbi = dbiPtr.value;
          return _dbiCache[name] = dbi;
        });

    return LMDBDatabase._(_db, _ptr, dbi);
  }

  /// [LMDBDatabase.put] on the sub-database from [getDatabase].
  ///
  /// ```dart
  /// final txn = db.txnStart();
  /// try {
  ///   txn.put(LMDBVal.fromUtf8('k'), LMDBVal.fromBytes([1, 2, 3]));
  ///   txn.commit();
  /// } catch (e) {
  ///   txn.abort();
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Throws [LMDBException] if `mdb_put` fails.
  void put(
    LMDBVal key,
    LMDBVal value, {
    LMDBWriteFlagSet? flags,
    String? dbName,
    LMDBDbiFlagSet? dbFlags,
  }) {
    return getDatabase(
      name: dbName,
      flags: dbFlags,
    ).put(key, value, flags: flags);
  }

  /// [get] on the selected database; returns `null` if the key is absent.
  ///
  /// ```dart
  /// final txn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
  /// try {
  ///   final v = txn.get(LMDBVal.fromUtf8('key'));
  ///   txn.commit();
  /// } catch (e) {
  ///   txn.abort();
  ///   rethrow;
  /// }
  /// ```
  LMDBVal? get(LMDBVal key, {String? dbName, LMDBDbiFlagSet? dbFlags}) {
    return getDatabase(name: dbName, flags: dbFlags).get(key);
  }

  /// [LMDBDatabase.delete] on the selected database; [data] is for duplicate-key DBs.
  ///
  /// Missing keys are ignored ([MDB_NOTFOUND] does not throw).
  void delete(
    LMDBVal key, {
    LMDBVal? data,
    String? dbName,
    LMDBDbiFlagSet? dbFlags,
  }) {
    return getDatabase(name: dbName, flags: dbFlags).delete(key, data: data);
  }

  /// [DatabaseStats] for this transaction’s selected database.
  ///
  /// ```dart
  /// final txn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
  /// try {
  ///   final s = txn.stats();
  ///   txn.commit();
  /// } catch (e) {
  ///   txn.abort();
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Throws [LMDBException] if `mdb_stat` fails.
  DatabaseStats stats({String? dbName, LMDBDbiFlagSet? dbFlags}) {
    return getDatabase(name: dbName, flags: dbFlags).stats();
  }

  /// New [LMDBCursor] for this database; call [LMDBCursor.close] when done.
  ///
  /// ```dart
  /// final txn = db.txnStart();
  /// try {
  ///   final cur = txn.cursorOpen();
  ///   try {
  ///     // …
  ///   } finally {
  ///     cur.close();
  ///   }
  ///   txn.commit();
  /// } catch (e) {
  ///   txn.abort();
  ///   rethrow;
  /// }
  /// ```
  LMDBCursor cursorOpen({String? dbName, LMDBDbiFlagSet? dbFlags}) {
    return getDatabase(name: dbName, flags: dbFlags).cursorOpen();
  }

  /// Ends the transaction successfully (`mdb_txn_commit`); the pointer must not be reused.
  ///
  /// Open DBI handles from this transaction are copied into the environment cache.
  ///
  /// ```dart
  /// final txn = db.txnStart();
  /// try {
  ///   txn.put(LMDBVal.fromUtf8('a'), LMDBVal.fromUtf8('1'));
  ///   txn.commit();
  /// } catch (e) {
  ///   txn.abort();
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Throws [LMDBException] if `mdb_txn_commit` fails.
  void commit() {
    if (_dbiCache.isNotEmpty) {
      _db._dbiCache.addAll(_dbiCache);
      _dbiCache.clear();
    }
    final result = _lib.mdb_txn_commit(_ptr);
    if (result != 0) {
      throw LMDBException('Failed to commit transaction', result);
    }
  }

  /// Discards the transaction (`mdb_txn_abort`); safe to call after errors.
  void abort() => _lib.mdb_txn_abort(_ptr);

  /// Releases a read-only transaction’s reader slot but keeps the handle for [renew].
  void reset() => _lib.mdb_txn_reset(_ptr);

  /// Re-attaches a reader after [reset] so the same handle can run more reads.
  void renew() => _lib.mdb_txn_renew(_ptr);
}

/// A single sub-database (DBI) opened on a [LMDBTransaction].
class LMDBDatabase {
  final LMDB _db;
  final Pointer<MDB_txn> _txn;
  final int _dbi;

  LMDBDatabase._(this._db, this._txn, this._dbi);

  /// Inserts or replaces a key/value pair (`mdb_put`).
  ///
  /// ```dart
  /// database.put(LMDBVal.fromUtf8('k'), LMDBVal.fromUtf8('v'));
  /// ```
  ///
  /// Throws [LMDBException] on failure.
  void put(LMDBVal key, LMDBVal value, {LMDBWriteFlagSet? flags}) {
    final result = _lib.mdb_put(
      _txn,
      _dbi,
      key.ptr,
      value.ptr,
      flags?.value ?? 0,
    );

    if (result != 0) {
      throw LMDBException('Failed to put data', result);
    }
  }

  /// Reads [key] (`mdb_get`); returns `null` if missing.
  LMDBVal? get(LMDBVal key) {
    final data = LMDBVal.empty();

    final result = _lib.mdb_get(_txn, _dbi, key.ptr, data.ptr);

    if (result == 0) {
      return data;
    } else if (result == MDB_NOTFOUND) {
      return null;
    } else {
      throw LMDBException('Failed to get data', result);
    }
  }

  /// Deletes [key], optionally a specific [data] for [LMDBDbiFlag.dupSort] databases.
  ///
  /// [MDB_NOTFOUND] is not treated as an error.
  void delete(LMDBVal key, {LMDBVal? data}) {
    final result = _lib.mdb_del(_txn, _dbi, key.ptr, data?.ptr ?? nullptr);

    if (result != 0 && result != MDB_NOTFOUND) {
      throw LMDBException('Failed to delete data', result);
    }
  }

  /// B-tree statistics for this DBI (`mdb_stat`).
  ///
  /// Throws [LMDBException] if `mdb_stat` fails.
  DatabaseStats stats() {
    return using((arena) {
      final statPtr = arena<MDB_stat>();

      final result = _lib.mdb_stat(_txn, _dbi, statPtr);

      if (result != 0) {
        throw LMDBException('Failed to get statistics', result);
      }

      return DatabaseStats(
        pageSize: statPtr.ref.ms_psize,
        depth: statPtr.ref.ms_depth,
        branchPages: statPtr.ref.ms_branch_pages,
        leafPages: statPtr.ref.ms_leaf_pages,
        overflowPages: statPtr.ref.ms_overflow_pages,
        entries: statPtr.ref.ms_entries,
      );
    });
  }

  /// Opens a cursor (`mdb_cursor_open`); dispose with [LMDBCursor.close].
  LMDBCursor cursorOpen() => using((arena) {
    final cursorPtr = arena<Pointer<MDB_cursor>>();

    final result = _lib.mdb_cursor_open(_txn, _dbi, cursorPtr);
    if (result != 0) {
      throw LMDBException('Failed to open cursor', result);
    }
    return LMDBCursor._(cursorPtr.value);
  });

  /// Key ordering for this DBI (`mdb_cmp`).
  int compareVals(LMDBVal a, LMDBVal b) {
    return _lib.mdb_cmp(_txn, _dbi, a.ptr, b.ptr);
  }

  /// Duplicate-value ordering (`mdb_dcmp`); requires [LMDBDbiFlag.dupSort].
  int compareDataVals(LMDBVal a, LMDBVal b) {
    return _lib.mdb_dcmp(_txn, _dbi, a.ptr, b.ptr);
  }

  /// Closes this DBI (`mdb_dbi_close`); rarely needed because handles are cached.
  void close() {
    final env = _db._ensureInitialized();
    _lib.mdb_dbi_close(env, _dbi);
  }

  /// Truncates this database or removes it from the environment (`mdb_drop`).
  ///
  /// When [delete] is true the DBI is also closed; see [close] for lifetime caveats.
  void drop({bool delete = false}) {
    final result = _lib.mdb_drop(_txn, _dbi, delete ? 1 : 0);
    if (result != 0) {
      throw LMDBException('Failed to drop database', result);
    }
  }
}

/// Iterator-style access to keys and values (`MDB_cursor`).
class LMDBCursor {
  final Pointer<MDB_cursor> _ptr;

  LMDBCursor._(this._ptr);

  /// `mdb_cursor_get` allocating new [LMDBVal]s; returns `null` on [MDB_NOTFOUND].
  ///
  /// ```dart
  /// var e = cursor.getAuto(null, CursorOp.first);
  /// while (e != null) {
  ///   // use e.key / e.data
  ///   e = cursor.getAuto(null, CursorOp.next);
  /// }
  /// ```
  LMDBEntry? getAuto(LMDBVal? key, CursorOp operation) {
    final keyVal = LMDBVal.empty();
    final dataVal = LMDBVal.empty();

    if (key != null) {
      keyVal.ptr.ref.mv_size = key.ptr.ref.mv_size;
      keyVal.ptr.ref.mv_data = key.ptr.ref.mv_data;
    }

    final result = _lib.mdb_cursor_get(
      _ptr,
      keyVal.ptr,
      dataVal.ptr,
      operation.value,
    );

    if (result == MDB_NOTFOUND) return null;
    if (result != 0) {
      throw LMDBException('Cursor operation failed', result);
    }

    return LMDBEntry(key: keyVal, data: dataVal);
  }

  /// In-place `mdb_cursor_get`: writes into [key] and [data], returns whether a row was found.
  bool get(LMDBVal key, LMDBVal data, CursorOp operation) {
    final result = _lib.mdb_cursor_get(
      _ptr,
      key.ptr,
      data.ptr,
      operation.value,
    );

    if (result == 0) return true;
    if (result == MDB_NOTFOUND) return false;
    throw LMDBException('Cursor operation failed', result);
  }

  /// Inserts or updates at the cursor (`mdb_cursor_put`).
  void put(LMDBVal key, LMDBVal value, {LMDBWriteFlagSet? flags}) {
    final result = _lib.mdb_cursor_put(
      _ptr,
      key.ptr,
      value.ptr,
      flags?.value ?? 0,
    );

    if (result != 0) {
      throw LMDBException('Failed to put cursor data', result);
    }
  }

  /// Deletes the current position (`mdb_cursor_del`).
  void delete({LMDBWriteFlagSet? flags}) {
    final result = _lib.mdb_cursor_del(_ptr, flags?.value ?? 0);
    if (result != 0) {
      throw LMDBException('Failed to delete at cursor', result);
    }
  }

  /// Number of data items sharing the current key (`mdb_cursor_count`); [LMDBDbiFlag.dupSort] only.
  int count() => using((arena) {
    final countPtr = arena<Size>();
    final result = _lib.mdb_cursor_count(_ptr, countPtr);
    if (result != 0) {
      throw LMDBException('Failed to get cursor count', result);
    }
    return countPtr.value;
  });

  /// Frees the cursor (`mdb_cursor_close`).
  void close() {
    _lib.mdb_cursor_close(_ptr);
  }
}
