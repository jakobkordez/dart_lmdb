import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_lmdb/src/lmdb_val.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'generated_bindings.dart';
import 'lmdb_entry.dart';
import 'lmdb_exception.dart';
import 'database_stats.dart';
import 'lmdb_config.dart';
import 'lmdb_cursor.dart';
import 'lmdb_flags.dart';
import 'lmdb_native.dart';

/// Native library bindings
final LMDBBindings _lib = LMDBNative.instance.lib;

/// A high-level Dart interface for LMDB (Lightning Memory-Mapped Database).
///
/// LMDB provides a Dart-friendly API for interacting with LMDB, featuring:
/// * Automatic transaction management
/// * UTF-8 string support
/// * Named databases
/// * Comprehensive statistics and analysis
///
/// Basic usage:
/// ```dart
/// final db = LMDB();
///
/// // Initialize the database
/// db.init('/path/to/db');
///
/// // Store some data
/// db.putUtf8Auto('key', 'value');
///
/// // Retrieve data
/// final value = db.getUtf8Auto('key');
/// print(value); // Prints: value
///
/// // Clean up
/// db.close();
/// ```
///
/// Advanced usage with explicit transactions:
/// ```dart
/// final db = LMDB();
/// db.init('/path/to/db');
///
/// final txn = db.txnStart();
/// try {
///   db.putUtf8(txn, 'key1', 'value1');
///   db.putUtf8(txn, 'key2', 'value2');
///   db.txnCommit(txn);
/// } catch (e) {
///   db.txnAbort(txn);
///   rethrow;
/// }
/// ```
class LMDB {
  /// The native LMDB environment pointer
  Pointer<MDB_env>? _env;

  /// Constants for internal usage
  static const String _dbNamesKey = '__db_names__';
  static const String _defaultMode = "0664";
  static const int _defaultMaxDbs = 1;

  /// Error messages
  static const String _errDbNotInitialized = 'Database not initialized';

  /// Cache for database handles
  final Map<String?, int> _dbiCache = {};

  /// Checks if the database has been initialized.
  bool get isInitialized => _env != null;

  /// Safe accessor for the environment pointer
  ///
  /// Throws [StateError] if the database is closed or not initialized
  Pointer<MDB_env> get env {
    if (_env == null) {
      throw StateError('Database not initialized');
    }
    return _env!;
  }

  /// Creates a new LMDB instance and loads the native library.
  ///
  /// Note: Call [init] before performing any database operations.
  LMDB();

  /// Helper for FFI memory management with specific pointer types
  ///
  /// [action] The action to perform with the allocated pointer
  /// [pointer] The pointer to be freed after use
  /// [T] The return type of the action
  /// [P] The specific pointer type being used
  T _withAllocated<T, P extends NativeType>(
    T Function(Pointer<P> ptr) action,
    Pointer<P> pointer,
  ) {
    try {
      return action(pointer);
    } finally {
      calloc.free(pointer);
    }
  }

  /// Initializes a new LMDB environment at the specified path with optional
  /// configuration and flags.
  ///
  /// The [dbPath] parameter specifies where the database should be created or
  /// opened.
  /// If the directory doesn't exist, it will be created automatically.
  ///
  /// The optional [config] parameter allows fine-tuning of the database
  /// environment:
  /// ```dart
  /// db.init('/path/to/db',
  ///   config: LMDBInitConfig(
  ///     mapSize: 10 * 1024 * 1024,  // 10 MB mapped to memory
  ///     maxDbs: 5,                  // Support up to 5 named databases
  ///     mode: "0644",               // File permissions
  ///   )
  /// );
  /// ```
  ///
  /// The optional [flags] parameter enables specific LMDB features:
  /// ```dart
  /// db.init('/path/to/db',
  ///   flags: LMDBFlagSet()
  ///   ..add(MDB_NOSUBDIR) // Use path as filename
  ///   ..add(MDB_NOSYNC) // Don't sync to disk immediately
  /// );
  /// ````
  ///
  /// Common flag combinations are available as presets:
  /// ```dart
  /// db.init('/path/to/db', flags: LMDBFlagSet.readOnly);
  /// db.init('/path/to/db', flags: LMDBFlagSet.highPerformance);
  /// ````
  ///
  /// If no [config] is provided, default values will be used:
  /// - mapSize: Minimum allowed size (typically 10MB)
  /// - maxDbs: 1 (single unnamed database)
  /// - mode: "0664" (rw-rw-r--)
  ///
  /// Throws [StateError] if:
  /// - Database is already initialized (call [close] first)
  /// - Database is closed (create a new instance)
  ///
  /// Throws [LMDBException] if:
  /// - Environment creation fails (insufficient permissions, invalid path)
  /// - Map size setting fails (invalid size)
  /// - Environment opening fails (file system issues, incompatible flags)
  ///
  /// Example usage:
  /// ```dart
  /// final db = LMDB();
  ///
  /// // Basic initialization
  /// db.init('/path/to/db');
  ///
  /// // With custom configuration
  /// db.init('/path/to/db',
  ///   config: LMDBInitConfig(mapSize: 1024 * 1024 * 1024), // 1GB
  ///   flags: LMDBFlagSet()..add(MDB_NOSUBDIR)
  /// );
  ///
  /// // Don't forget to close when done
  /// db.close();
  /// ```
  void init(String dbPath, {LMDBInitConfig? config, LMDBFlagSet? flags}) {
    if (_env != null) {
      throw StateError('Database already initialized');
    }

    final effectiveFlags = flags ?? LMDBFlagSet.defaultFlags;
    final effectiveConfig =
        config ??
        LMDBInitConfig(
          mapSize: LMDBConfig.minMapSize,
          maxDbs: _defaultMaxDbs,
          mode: _defaultMode,
        );

    // Determine if we're in NOSUBDIR mode
    if (effectiveFlags.contains(MDB_NOSUBDIR)) {
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

    return _withAllocated<void, Pointer<MDB_env>>((envPtr) {
      final result = _lib.mdb_env_create(envPtr);
      if (result != 0) {
        throw LMDBException('Failed to create environment', result);
      }

      _env = envPtr.value;

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

        final pathPtr = dbPath.toNativeUtf8();
        try {
          final openResult = _lib.mdb_env_open(
            env,
            pathPtr.cast(),
            effectiveFlags.value,
            effectiveConfig.modeAsInt,
          );

          if (openResult != 0) {
            throw LMDBException('Failed to open environment', openResult);
          }
        } finally {
          calloc.free(pathPtr);
        }
      } catch (e) {
        _lib.mdb_env_close(_env!);
        _env = null;
        rethrow;
      }
    }, calloc<Pointer<MDB_env>>());
  }

  /// Closes the database and releases all resources.
  ///
  /// After calling close, the database must be re-initialized
  /// before it can be used again.
  void close() {
    if (_env != null) {
      _lib.mdb_env_close(_env!);
      _env = null;
      _dbiCache.clear();
    }
  }

  /// Analyzes current database usage and returns a formatted report.
  ///
  /// Example:
  /// ```dart
  /// final analysis = db.analyzeUsage();
  /// print(analysis);
  /// // Prints detailed statistics about database structure
  /// ```
  String analyzeUsage() {
    final stats = getStats();
    return LMDBConfig.analyzeUsage(stats);
  }

  /// Starts a new LMDB transaction.
  ///
  /// A transaction represents a coherent set of changes to the database.
  /// All database operations must be performed within a transaction.
  ///
  /// Parameters:
  /// * [parent] - Optional parent transaction for nested transactions
  /// * [flags] - Optional flags to modify transaction behavior
  ///
  /// Common flags:
  /// * MDB_RDONLY - Read-only transaction (better performance, multiple readers allowed)
  /// * MDB_NOSYNC - Don't sync on commit (better performance but less safe)
  ///
  /// Example usage patterns:
  /// ```dart
  /// // 1. Basic read-write transaction
  /// final txn = db.txnStart();
  /// try {
  ///   db.putUtf8(txn, 'key', 'value');
  ///   db.txnCommit(txn);
  /// } catch (e) {
  ///   db.txnAbort(txn);
  ///   rethrow;
  /// }
  ///
  /// // 2. Read-only transaction
  /// final readTxn = db.txnStart(
  ///   flags: LMDBFlagSet()..add(MDB_RDONLY)
  /// );
  /// try {
  ///   final value = db.getUtf8(readTxn, 'key');
  ///   db.txnCommit(readTxn);
  /// } catch (e) {
  ///   db.txnAbort(readTxn);
  ///   rethrow;
  /// }
  ///
  /// // 3. Nested transaction
  /// final parentTxn = db.txnStart();
  /// try {
  ///   db.putUtf8(parentTxn, 'key1', 'value1');
  ///
  ///   // Start a child transaction
  ///   final childTxn = db.txnStart(parent: parentTxn);
  ///   try {
  ///     db.putUtf8(childTxn, 'key2', 'value2');
  ///     db.txnCommit(childTxn);
  ///   } catch (e) {
  ///     db.txnAbort(childTxn);
  ///     rethrow;
  ///   }
  ///
  ///   db.txnCommit(parentTxn);
  /// } catch (e) {
  ///   db.txnAbort(parentTxn);
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Important notes:
  /// * Always pair txnStart with either txnCommit or txnAbort
  /// * Use try-catch blocks to ensure proper transaction handling
  /// * Read-only transactions can run concurrently
  /// * Only one write transaction can be active at a time
  /// * Child transactions can only be created from write transactions
  /// * Child transactions must be committed/aborted before parent transactions
  ///
  /// Performance tips:
  /// * Use read-only transactions when possible
  /// * Keep transactions as short as possible
  /// * Consider using MDB_NOSYNC for better write performance
  /// * Use the Auto methods for simple operations
  ///
  /// Throws [StateError] if database is not initialized
  /// Throws [LMDBException] if transaction cannot be started
  Pointer<MDB_txn> txnStart({Pointer<MDB_txn>? parent, LMDBFlagSet? flags}) {
    final currentEnv = env;
    final txnPtr = calloc<Pointer<MDB_txn>>();

    try {
      final result = _lib.mdb_txn_begin(
        currentEnv,
        parent ?? nullptr,
        flags?.value ?? LMDBFlagSet.defaultFlags.value,
        txnPtr,
      );

      if (result != 0) {
        throw LMDBException('Failed to start transaction', result);
      }

      return txnPtr.value;
    } finally {
      calloc.free(txnPtr);
    }
  }

  /// Commits a transaction and makes all its changes permanent.
  ///
  /// After a successful commit:
  /// * All changes made in the transaction become permanent
  /// * The transaction handle becomes invalid
  /// * Child transactions (if any) become invalid
  ///
  /// Parameters:
  /// * [txn] - Transaction to commit
  ///
  /// Example with error handling:
  /// ```dart
  /// final txn = db.txnStart();
  /// try {
  ///   // Perform multiple operations in one transaction
  ///   db.putUtf8(txn, 'user:1', '{"name": "John"}');
  ///   db.putUtf8(txn, 'user:2', '{"name": "Jane"}');
  ///
  ///   // Make all changes permanent
  ///   db.txnCommit(txn);
  /// } catch (e) {
  ///   // On any error, abort the transaction
  ///   db.txnAbort(txn);
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Important notes:
  /// * The transaction handle must not be used after commit
  /// * Always use try-catch with txnAbort in the catch block
  /// * Commit is atomic - either all changes succeed or none do
  ///
  /// Throws [StateError] if database is not initialized
  /// Throws [LMDBException] if commit fails
  void txnCommit(Pointer<MDB_txn> txn) {
    if (!isInitialized) throw StateError(_errDbNotInitialized);

    final result = _lib.mdb_txn_commit(txn);
    if (result != 0) {
      throw LMDBException('Failed to commit transaction', result);
    }
  }

  /// Aborts a transaction and rolls back all its changes.
  ///
  /// After abort:
  /// * All changes made in the transaction are discarded
  /// * The transaction handle becomes invalid
  /// * Child transactions (if any) become invalid
  ///
  /// Parameters:
  /// * [txn] - Transaction to abort
  ///
  /// Example usage patterns:
  /// ```dart
  /// // 1. In catch block (most common)
  /// final txn = db.txnStart();
  /// try {
  ///   db.putUtf8(txn, 'key', 'value');
  ///   db.txnCommit(txn);
  /// } catch (e) {
  ///   db.txnAbort(txn);
  ///   rethrow;
  /// }
  ///
  /// // 2. Explicit rollback
  /// final txn = db.txnStart();
  /// db.putUtf8(txn, 'key', 'value');
  /// if (shouldRollback) {
  ///   db.txnAbort(txn);
  ///   return;
  /// }
  /// db.txnCommit(txn);
  ///
  /// // 3. In finally block for nested transactions
  /// final parentTxn = db.txnStart();
  /// try {
  ///   final childTxn = db.txnStart(parent: parentTxn);
  ///   try {
  ///     // ... operations
  ///     db.txnCommit(childTxn);
  ///   } finally {
  ///     db.txnAbort(childTxn);
  ///   }
  ///   db.txnCommit(parentTxn);
  /// } catch (e) {
  ///   db.txnAbort(parentTxn);
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Important notes:
  /// * The transaction handle must not be used after abort
  /// * Abort is safe to call multiple times (subsequent calls have no effect)
  /// * Abort should always be called in catch blocks
  /// * Child transactions must be aborted before parent transactions
  void txnAbort(Pointer<MDB_txn> txn) {
    if (!isInitialized) throw StateError(_errDbNotInitialized);
    _lib.mdb_txn_abort(txn);
  }

  /// Helper for automatic transaction management
  ///
  /// [action] The action to perform within the transaction
  /// [flags] Optional flags for the transaction
  T _withTransaction<T>(
    T Function(Pointer<MDB_txn> txn) action, {
    LMDBFlagSet? flags,
  }) {
    final txn = txnStart(flags: flags);
    try {
      final result = action(txn);
      if (flags?.contains(MDB_RDONLY) ?? false) {
        txnAbort(txn);
      } else {
        txnCommit(txn);
      }
      return result;
    } catch (e) {
      txnAbort(txn);
      rethrow;
    }
  }

  /// Stores a raw byte value in the database.
  ///
  /// Parameters:
  /// * [txn] - Active transaction
  /// * [key] - String key under which to store the value
  /// * [value] - Raw bytes to store
  /// * [dbName] - Optional named database. If not provided, the default database will be used.
  /// * [flags] - Optional operation flags
  ///
  /// Example:
  /// ```dart
  /// final txn = db.txnStart();
  /// try {
  ///   db.put(txn, 'key', [1, 2, 3, 4]);
  ///   db.txnCommit(txn);
  /// } catch (e) {
  ///   db.txnAbort(txn);
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Throws [StateError] if database is not initialized
  /// Throws [LMDBException] if operation fails
  void put(
    Pointer<MDB_txn> txn,
    LMDBVal key,
    LMDBVal value, {
    String? dbName,
    LMDBFlagSet? flags,
  }) {
    if (!isInitialized) throw StateError(_errDbNotInitialized);

    final dbi = _getDatabase(txn, name: dbName, flags: flags);

    final result = _lib.mdb_put(
      txn,
      dbi,
      key.ptr,
      value.ptr,
      flags?.value ?? 0,
    );

    if (result != 0) {
      throw LMDBException('Failed to put data', result);
    }
  }

  /// Retrieves a raw byte value from the database.
  ///
  /// Parameters:
  /// * [txn] - Active transaction
  /// * [key] - Key to retrieve
  /// * [dbName] - Optional named database. If not provided, the default database will be used.
  /// * [flags] - Optional operation flags
  ///
  /// Returns the value as byte list, or null if not found.
  ///
  /// Example:
  /// ```dart
  /// final txn = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
  /// try {
  ///   final bytes = db.get(txn, 'key');
  ///   if (bytes != null) {
  ///     print('Value: $bytes');
  ///   }
  ///   db.txnCommit(txn);
  /// } catch (e) {
  ///   db.txnAbort(txn);
  ///   rethrow;
  /// }
  /// ```
  LMDBVal? get(
    Pointer<MDB_txn> txn,
    LMDBVal key, {
    String? dbName,
    LMDBFlagSet? flags,
  }) {
    if (!isInitialized) throw StateError(_errDbNotInitialized);

    final dbi = _getDatabase(txn, name: dbName, flags: flags);

    final data = LMDBVal.empty();

    final result = _lib.mdb_get(txn, dbi, key.ptr, data.ptr);

    if (result == 0) {
      return data;
    } else if (result == MDB_NOTFOUND) {
      return null;
    } else {
      throw LMDBException('Failed to get data', result);
    }
  }

  /// Deletes a value from the database.
  ///
  /// Parameters:
  /// * [txn] - Active transaction
  /// * [key] - Key to delete
  /// * [dbName] - Optional named database. If not provided, the default database will be used.
  /// * [flags] - Optional operation flags
  ///
  /// Example:
  /// ```dart
  /// final txn = db.txnStart();
  /// try {
  ///   db.delete(txn, 'key');
  ///   db.txnCommit(txn);
  /// } catch (e) {
  ///   db.txnAbort(txn);
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Note: Does not throw if key doesn't exist
  void delete(
    Pointer<MDB_txn> txn,
    LMDBVal key, {
    String? dbName,
    LMDBFlagSet? flags,
  }) {
    if (!isInitialized) throw StateError(_errDbNotInitialized);

    final dbi = _getDatabase(txn, name: dbName, flags: flags);

    final result = _lib.mdb_del(txn, dbi, key.ptr, nullptr);

    if (result != 0 && result != MDB_NOTFOUND) {
      throw LMDBException('Failed to delete data', result);
    }
  }

  /// Convenience methods with automatic transaction management

  /// Stores a raw byte value with automatic transaction management.
  ///
  /// This is a convenience method that handles transaction creation,
  /// commit, and error handling automatically.
  ///
  /// Parameters:
  /// * [key] - Key under which to store the value
  /// * [value] - Raw bytes to store
  /// * [dbName] - Optional named database
  /// * [flags] - Optional operation flags
  ///
  /// Example:
  /// ```dart
  /// // Simple storage without manual transaction handling
  /// db.putAuto('key', [1, 2, 3, 4]);
  /// ```
  ///
  /// Throws [StateError] if database is closed
  /// Throws [LMDBException] if operation fails
  void putAuto(
    LMDBVal key,
    LMDBVal value, {
    String? dbName,
    LMDBFlagSet? flags,
  }) {
    return _withTransaction(
      (txn) => put(txn, key, value, dbName: dbName, flags: flags),
    );
  }

  /// Retrieves a raw byte value with automatic transaction management.
  ///
  /// Uses an automatic read-only transaction.
  ///
  /// Parameters:
  /// * [key] - Key to retrieve
  /// * [dbName] - Optional named database
  ///
  /// Returns the value as byte list, or null if not found.
  ///
  /// Example:
  /// ```dart
  /// final bytes = db.getAuto('key');
  /// if (bytes != null) {
  ///   print('Retrieved ${bytes.length} bytes');
  /// }
  /// ```
  ///
  /// Throws [StateError] if database is closed
  /// Throws [LMDBException] if operation fails
  LMDBVal? getAuto(LMDBVal key, {String? dbName}) {
    return _withTransaction(
      (txn) => get(txn, key, dbName: dbName),
      flags: LMDBFlagSet.readOnly,
    );
  }

  /// Deletes a value with automatic transaction management.
  ///
  /// Parameters:
  /// * [key] - Key to delete
  /// * [dbName] - Optional named database
  ///
  /// Example:
  /// ```dart
  /// db.deleteAuto('key');
  /// ```
  /// Throws [StateError] if database is closed
  /// Throws [LMDBException] if operation fails
  void deleteAuto(LMDBVal key, {String? dbName}) {
    return _withTransaction((txn) => delete(txn, key, dbName: dbName));
  }

  /// Gets database statistics with automatic transaction management.
  ///
  /// Parameters:
  /// * [dbName] - Optional named database
  /// * [flags] - Optional operation flags
  ///
  /// Returns detailed statistics about the database structure.
  ///
  /// Example:
  /// ```dart
  /// final stats = db.statsAuto();
  /// print('Total entries: ${stats.entries}');
  /// print('Tree depth: ${stats.depth}');
  /// ```
  ///
  /// Throws [StateError] if database is closed
  /// Throws [LMDBException] if operation fails
  DatabaseStats statsAuto({String? dbName, LMDBFlagSet? flags}) {
    return _withTransaction(
      (txn) => stats(txn, dbName: dbName, flags: flags),
      flags: LMDBFlagSet.readOnly,
    );
  }

  /// Gets statistics for a specific database using an explicit transaction.
  ///
  /// Parameters:
  /// * [txn] - Active transaction
  /// * [dbName] - Optional named database
  /// * [flags] - Optional operation flags
  ///
  /// Returns detailed database statistics.
  ///
  /// Example:
  /// ```dart
  /// final txn = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
  /// try {
  ///   final stats = db.stats(txn);
  ///   print('Entries: ${stats.entries}');
  ///   print('Tree depth: ${stats.depth}');
  ///   db.txnCommit(txn);
  /// } catch (e) {
  ///   db.txnAbort(txn);
  ///   rethrow;
  /// }
  /// ```
  ///
  /// Throws [StateError] if database is closed
  /// Throws [LMDBException] if operation fails
  DatabaseStats stats(
    Pointer<MDB_txn> txn, {
    String? dbName,
    LMDBFlagSet? flags,
  }) {
    if (!isInitialized) throw StateError(_errDbNotInitialized);

    final dbi = _getDatabase(txn, name: dbName, flags: flags);
    final statPtr = calloc<MDB_stat>();

    try {
      final result = _lib.mdb_stat(txn, dbi, statPtr);

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
    } finally {
      calloc.free(statPtr);
    }
  }

  /// Opens a database with the specified name
  ///
  /// [txn] Transaction to use
  /// [name] Optional database name
  /// [flags] Optional flags for database operations
  ///
  /// Returns database handle (dbi)
  ///
  /// Throws [StateError] if database is closed
  /// Throws [LMDBException] if operation fails
  int _openDatabase(Pointer<MDB_txn> txn, {String? name, LMDBFlagSet? flags}) {
    if (!isInitialized) throw StateError(_errDbNotInitialized);

    final dbiPtr = calloc<MDB_dbi>();
    try {
      final namePtr = name?.toNativeUtf8();
      try {
        final effectiveFlags =
            (flags ?? LMDBFlagSet.defaultFlags).value | MDB_CREATE;

        final result = _lib.mdb_dbi_open(
          txn,
          namePtr?.cast() ?? nullptr,
          effectiveFlags,
          dbiPtr,
        );

        if (result != 0) {
          throw LMDBException('Failed to open database', result);
        }

        final dbi = dbiPtr.value;
        if (name != null) {
          _dbiCache[name] = dbi;
          _registerDbName(txn, name);
        }
        return dbi;
      } finally {
        if (namePtr != null) {
          calloc.free(namePtr);
        }
      }
    } finally {
      calloc.free(dbiPtr);
    }
  }

  /// Registers a database name in the internal registry
  void _registerDbName(Pointer<MDB_txn> txn, String name) {
    final names = _getDbNames(txn);
    if (!names.contains(name)) {
      names.add(name);
      _saveDbNames(txn, names);
    }
  }

  /// Retrieves the list of registered database names
  List<String> _getDbNames(Pointer<MDB_txn> txn) {
    final value = get(txn, LMDBVal.fromUtf8(_dbNamesKey));
    if (value == null) return [];
    return value.toUtf8String().split(',').where((s) => s.isNotEmpty).toList();
  }

  /// Saves the list of database names
  void _saveDbNames(Pointer<MDB_txn> txn, List<String> names) {
    final namesString = names.join(',');
    put(txn, LMDBVal.fromUtf8(_dbNamesKey), LMDBVal.fromUtf8(namesString));
  }

  /// Gets a database handle, using cached value if available
  ///
  /// [txn] Transaction to use
  /// [name] Optional database name
  /// [flags] Optional flags for database operations
  ///
  /// Returns database handle (dbi)
  int _getDatabase(Pointer<MDB_txn> txn, {String? name, LMDBFlagSet? flags}) {
    if (_dbiCache.containsKey(name)) {
      return _dbiCache[name]!;
    }

    return _openDatabase(txn, name: name, flags: flags);
  }

  /// Lists all named databases in the environment.
  ///
  /// Returns a list of database names that have been created.
  /// The default unnamed database is not included in this list.
  ///
  /// Example:
  /// ```dart
  /// final databases = db.listDatabases();
  /// for (final dbName in databases) {
  ///   print('Found database: $dbName');
  /// }
  /// ```
  List<String> listDatabases() {
    final txn = txnStart(flags: LMDBFlagSet.readOnly);
    try {
      final names = _getDbNames(txn);
      txnAbort(txn); // read-only transactions should be aborted, not committed
      return names;
    } catch (e) {
      txnAbort(txn);
      rethrow;
    }
  }

  /// Gets the version string of the LMDB library.
  ///
  /// Returns the version in format "LMDB x.y.z".
  ///
  /// Example:
  /// ```dart
  /// final version = db.getVersion();
  /// print('Using LMDB version: $version');
  /// ```
  String getVersion() {
    final major = calloc<Int>();
    final minor = calloc<Int>();
    final patch = calloc<Int>();

    try {
      final verPtr = _lib.mdb_version(major, minor, patch);
      return verPtr.cast<Utf8>().toDartString();
    } finally {
      calloc.free(major);
      calloc.free(minor);
      calloc.free(patch);
    }
  }

  /// Gets a human-readable error string for an LMDB error code.
  ///
  /// Parameters:
  /// * [err] - LMDB error code
  ///
  /// Returns a descriptive error message.
  ///
  /// Example:
  /// ```dart
  /// try {
  ///   // ... some operation
  /// } catch (e) {
  ///   if (e is LMDBException) {
  ///     print('Error: ${db.getErrorString(e.errorCode)}');
  ///   }
  /// }
  /// ```
  String getErrorString(int err) {
    final ptr = _lib.mdb_strerror(err);
    return ptr.cast<Utf8>().toDartString();
  }

  /// Synchronizes the environment to disk.
  ///
  /// Parameters:
  /// * [force] - If true, forces a synchronous flush
  ///
  /// Use this to ensure all changes are written to disk.
  ///
  /// Example:
  /// ```dart
  /// // Normal async sync
  /// db.sync(false);
  ///
  /// // Force immediate sync
  /// db.sync(true);
  /// ```
  void sync(bool force) {
    final currentEnv = env;
    final result = _lib.mdb_env_sync(currentEnv, force ? 1 : 0);
    if (result != 0) {
      throw LMDBException('Failed to sync environment', result);
    }
  }

  /// Gets statistics for the database specified by its handle
  DatabaseStats _getStats(Pointer<MDB_txn> txn, int dbi) {
    final statPtr = calloc<MDB_stat>();
    try {
      final result = _lib.mdb_stat(txn, dbi, statPtr);

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
    } finally {
      calloc.free(statPtr);
    }
  }

  /// Gets statistics for a database.
  ///
  /// If [dbName] is null, returns statistics for the default database.
  /// If [dbName] is provided, returns statistics for the named database.
  ///
  /// Throws [LMDBException] if:
  /// - The database cannot be opened
  /// - Statistics cannot be retrieved
  ///
  /// Example:
  /// ```dart
  /// // Get stats for default database
  /// final defaultStats = db.getStats();
  ///
  /// // Get stats for named database
  /// final userStats = db.getStats(dbName: 'users');
  /// ```
  DatabaseStats getStats({String? dbName}) {
    final currentEnv = env;
    late final Pointer<MDB_txn> txn;
    try {
      // start transaction (read-only)
      final txnPtr = calloc<Pointer<MDB_txn>>();
      try {
        final result = _lib.mdb_txn_begin(
          currentEnv,
          nullptr,
          MDB_RDONLY,
          txnPtr,
        );

        if (result != 0) {
          throw LMDBException('Failed to start transaction', result);
        }
        txn = txnPtr.value;
      } finally {
        calloc.free(txnPtr);
      }

      // open db read-only
      final dbiPtr = calloc<MDB_dbi>();
      final namePtr = dbName?.toNativeUtf8();
      late final int dbi;
      try {
        final result = _lib.mdb_dbi_open(
          txn,
          namePtr?.cast() ?? nullptr,
          0,
          dbiPtr,
        );

        if (result != 0) {
          throw LMDBException('Failed to open database', result);
        }
        dbi = dbiPtr.value;
      } finally {
        if (namePtr != null) calloc.free(namePtr);
        calloc.free(dbiPtr);
      }

      return _getStats(txn, dbi);
    } finally {
      _lib.mdb_txn_abort(txn);
    }
  }

  /// Gets environment-wide statistics
  ///
  /// Returns statistics for the entire LMDB environment
  ///
  /// Throws [StateError] if database is closed
  /// Throws [LMDBException] if operation fails
  DatabaseStats getEnvironmentStats() {
    if (!isInitialized) throw StateError(_errDbNotInitialized);

    final statPtr = calloc<MDB_stat>();
    try {
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
    } finally {
      calloc.free(statPtr);
    }
  }

  /// Gets statistics for all databases in the environment.
  ///
  /// Returns a map with statistics for:
  /// * 'environment' - Overall environment stats
  /// * 'default' - Default database stats
  /// * Named databases - Stats for each named database
  ///
  /// Example:
  /// ```dart
  /// final allStats = db.getAllDatabaseStats();
  /// print('Environment entries: ${allStats['environment']?.entries}');
  /// print('Default DB entries: ${allStats['default']?.entries}');
  ///
  /// // Stats for named databases
  /// allStats.forEach((name, stats) {
  ///   if (name != 'environment' && name != 'default') {
  ///     print('DB $name entries: ${stats.entries}');
  ///   }
  /// });
  /// ```
  ///
  /// Throws [StateError] if database is closed
  /// Throws [LMDBException] if operation fails
  Map<String, DatabaseStats> getAllDatabaseStats() {
    final statistics = <String, DatabaseStats>{};

    return _withTransaction((txn) {
      // Get environment stats
      statistics['environment'] = getEnvironmentStats();

      // Get stats for default DB
      statistics['default'] = stats(txn);

      // Get stats for all named DBs
      final names = _getDbNames(txn);
      for (final name in names) {
        statistics[name] = stats(txn, dbName: name);
      }

      return statistics;
    }, flags: LMDBFlagSet.readOnly);
  }

  /// Opens a new cursor for the specified database
  ///
  /// Parameters:
  /// * [txn] - Active transaction
  /// * [dbName] - Optional named database
  ///
  /// Returns a cursor that must be closed with [cursorClose]
  ///
  /// Example:
  /// ```dart
  /// final txn = db.txnStart();
  /// try {
  ///   final cursor = db.cursorOpen(txn);
  ///   try {
  ///     // Use cursor...
  ///   } finally {
  ///     db.cursorClose(cursor);
  ///   }
  ///   db.txnCommit(txn);
  /// } catch (e) {
  ///   db.txnAbort(txn);
  ///   rethrow;
  /// }
  /// ```
  ///
  Pointer<MDB_cursor> cursorOpen(
    Pointer<MDB_txn> txn, {
    String? dbName,
    LMDBFlagSet? flags,
  }) {
    if (!isInitialized) throw StateError(_errDbNotInitialized);

    final dbi = _getDatabase(txn, name: dbName, flags: flags);
    final cursorPtr = calloc<Pointer<MDB_cursor>>();

    try {
      final result = _lib.mdb_cursor_open(txn, dbi, cursorPtr);
      if (result != 0) {
        throw LMDBException('Failed to open cursor', result);
      }
      return cursorPtr.value;
    } finally {
      calloc.free(cursorPtr);
    }
  }

  /// Closes a cursor
  ///
  /// The cursor must not be used after closing.
  void cursorClose(Pointer<MDB_cursor> cursor) {
    _lib.mdb_cursor_close(cursor);
  }

  /// Positions cursor and retrieves data
  ///
  /// Parameters:
  /// * [cursor] - Active cursor
  /// * [key] - Optional key for positioning operations
  /// * [operation] - Cursor operation to perform
  ///
  /// Returns the entry at cursor position, or null if no data was found
  ///
  /// Example:
  /// ```dart
  /// // Get first entry
  /// final firstEntry = db.cursorGet(cursor, null, CursorOp.first);
  ///
  /// // Find specific entry
  /// final entry = db.cursorGet(
  ///   cursor,
  ///   utf8.encode('searchKey'),
  ///   CursorOp.setRange
  /// );
  ///
  /// // Iterate through entries
  /// var entry = db.cursorGet(cursor, null, CursorOp.first);
  /// while (entry != null) {
  ///   print('Found: ${entry.toString()}');
  ///   entry = db.cursorGet(cursor, null, CursorOp.next);
  /// }
  /// ```
  LMDBEntry? cursorGet(
    Pointer<MDB_cursor> cursor,
    LMDBVal? key,
    CursorOp operation,
  ) {
    final keyVal = LMDBVal.empty();
    final dataVal = LMDBVal.empty();

    if (key != null) {
      keyVal.ptr.ref.mv_size = key.ptr.ref.mv_size;
      keyVal.ptr.ref.mv_data = key.ptr.ref.mv_data;
    }

    final result = _lib.mdb_cursor_get(
      cursor,
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

  bool cursorRefGet(
    Pointer<MDB_cursor> cursor,
    LMDBVal key,
    LMDBVal data,
    CursorOp operation,
  ) {
    final result = _lib.mdb_cursor_get(
      cursor,
      key.ptr,
      data.ptr,
      operation.value,
    );

    if (result == 0) return true;
    if (result == MDB_NOTFOUND) return false;
    throw LMDBException('Cursor operation failed', result);
  }

  int compareVals(
    Pointer<MDB_txn> txn,
    LMDBVal a,
    LMDBVal b, {
    String? dbName,
    LMDBFlagSet? flags,
  }) {
    final dbi = _getDatabase(txn, name: dbName, flags: flags);

    return _lib.mdb_cmp(txn, dbi, a.ptr, b.ptr);
  }

  /// Collects all keys from the specified database in a single tight loop.
  ///
  /// This is much faster than calling [cursorGet] per-entry because it:
  /// - Reuses a single pair of MDB_val structs for the entire iteration
  /// - Copies only key bytes (value data is not read into Dart)
  /// - Avoids per-entry async overhead (the cursor loop is fully synchronous)
  ///
  /// Returns an ordered list of all keys as [Uint8List].
  ///
  /// Example:
  /// ```dart
  /// final txn = db.txnStart(flags: LMDBFlagSet.readOnly);
  /// try {
  ///   final keys = db.getAllKeys(txn, dbName: 'users');
  ///   print('Found ${keys.length} keys');
  ///   db.txnCommit(txn);
  /// } catch (e) {
  ///   db.txnAbort(txn);
  ///   rethrow;
  /// }
  /// ```
  List<Uint8List> getAllKeys(
    Pointer<MDB_txn> txn, {
    String? dbName,
    LMDBFlagSet? flags,
  }) {
    if (!isInitialized) throw StateError(_errDbNotInitialized);

    // DBI resolution may need async (cache miss), but is typically instant.
    final dbi = _getDatabase(txn, name: dbName, flags: flags);

    // --- Everything below is synchronous FFI ---

    final cursorPtr = calloc<Pointer<MDB_cursor>>();
    try {
      final rc = _lib.mdb_cursor_open(txn, dbi, cursorPtr);
      if (rc != 0) throw LMDBException('Failed to open cursor', rc);
      final cursor = cursorPtr.value;

      try {
        final keyVal = LMDBVal.empty();
        final dataVal = LMDBVal.empty();
        final keys = <Uint8List>[];

        var result = _lib.mdb_cursor_get(
          cursor,
          keyVal.ptr,
          dataVal.ptr,
          CursorOp.first.value,
        );

        while (result == 0) {
          keys.add(keyVal.asBytes());
          result = _lib.mdb_cursor_get(
            cursor,
            keyVal.ptr,
            dataVal.ptr,
            CursorOp.next.value,
          );
        }

        if (result != MDB_NOTFOUND) {
          throw LMDBException('Cursor iteration failed', result);
        }

        return keys;
      } finally {
        _lib.mdb_cursor_close(cursor);
      }
    } finally {
      calloc.free(cursorPtr);
    }
  }

  /// Stores data at current cursor position
  ///
  /// Parameters:
  /// * [cursor] - Active cursor
  /// * [key] - Key to store
  /// * [value] - Value to store
  /// * [flags] - Optional operation flags
  ///
  /// Example:
  /// ```dart
  /// db.cursorPut(
  ///   cursor,
  ///   utf8.encode('key'),
  ///   utf8.encode('value'),
  ///   0
  /// );
  /// ```
  void cursorPut(
    Pointer<MDB_cursor> cursor,
    LMDBVal key,
    LMDBVal value, {
    LMDBFlagSet? flags,
  }) {
    final result = _lib.mdb_cursor_put(
      cursor,
      key.ptr,
      value.ptr,
      flags?.value ?? 0,
    );

    if (result != 0) {
      throw LMDBException('Failed to put cursor data', result);
    }
  }

  /// Deletes the entry at current cursor position
  ///
  /// Parameters:
  /// * [cursor] - Active cursor
  /// * [flags] - Optional operation flags
  ///
  /// Example:
  /// ```dart
  /// // Position cursor and delete entry
  /// final entry = db.cursorGet(cursor, null, CursorOp.first);
  /// if (entry != null) {
  ///   db.cursorDelete(cursor);
  /// }
  /// ```
  void cursorDelete(Pointer<MDB_cursor> cursor, {LMDBFlagSet? flags}) {
    final result = _lib.mdb_cursor_del(cursor, flags?.value ?? 0);
    if (result != 0) {
      throw LMDBException('Failed to delete at cursor', result);
    }
  }

  /// Cleans up resources and closes the database.
  ///
  /// This is equivalent to calling [close] and should be called
  /// when the database is no longer needed.
  ///
  /// Example:
  /// ```dart
  /// final db = LMDB();
  /// try {
  ///   db.init('/path/to/db');
  ///   // ... use database
  /// } finally {
  ///   db.dispose();
  /// }
  /// ```
  void dispose() {
    if (isInitialized) {
      close();
    }
  }
}
