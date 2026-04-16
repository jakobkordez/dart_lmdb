/// A high-level Dart interface for LMDB (Lightning Memory-Mapped Database).
///
/// LMDB is a fast key-value store that provides:
/// * Memory-mapped file storage for optimal performance
/// * ACID transactions (depending on given flags) with full CRUD operations
/// * Multiple named databases within a single environment
/// * Concurrent readers with a single writer
/// * Zero-copy lookup for read operations
///
/// This Dart wrapper adds the following features:
/// * [LMDB.withTransaction] and convenience [LMDB.put] / [LMDB.get] helpers
/// * [LMDBVal] byte keys and values (including UTF-8 helpers)
/// * Named sub-databases via the `dbName` parameter and [LMDBTransaction.getDatabase]
/// * [DatabaseStats], [LMDBCursor], and environment utilities
/// * Safe memory management through FFI
///
/// The API is **synchronous**; there are no `async` database methods.
///
/// # Basic usage
///
/// Create [LMDBVal] instances for keys and values, then call [LMDB.put] and [LMDB.get].
/// Dispose [LMDBVal]s when you no longer need them (values returned from [LMDB.get]
/// are owned by you until [LMDBVal.dispose]).
///
/// ```dart
/// final db = LMDB();
/// db.init('/path/to/db');
///
/// final key = LMDBVal.fromUtf8('key');
/// final value = LMDBVal.fromUtf8('value');
/// db.put(key, value);
///
/// final found = db.get(key);
/// try {
///   // use found …
/// } finally {
///   key.dispose();
///   value.dispose();
///   found?.dispose();
/// }
///
/// db.close();
/// ```
///
/// # Named databases
///
/// LMDB supports multiple named databases in one environment. Set [LMDBInitConfig.maxDbs]
/// high enough when calling [LMDB.init], then pass `dbName` to [LMDB.put], [LMDB.get], and
/// related methods. There is no built-in API to list sub-database names; names are
/// application-defined.
///
/// ```dart
/// db.init(
///   '/path/to/db',
///   config: LMDBInitConfig(
///     mapSize: 10 * 1024 * 1024, // 10 MB
///     maxDbs: 5,
///   ),
/// );
///
/// final k = LMDBVal.fromUtf8('key');
/// db.put(LMDBVal.fromUtf8('key'), LMDBVal.fromUtf8('value1'), dbName: 'users');
/// db.put(LMDBVal.fromUtf8('key'), LMDBVal.fromUtf8('value2'), dbName: 'settings');
///
/// print(db.get(k, dbName: 'users')?.toUtf8String()); // value1
/// print(db.get(k, dbName: 'settings')?.toUtf8String()); // value2
/// k.dispose();
/// ```
///
/// # Transaction management
///
/// For batching or explicit control, use [LMDB.txnStart] or [LMDB.withTransaction].
///
/// ```dart
/// final txn = db.txnStart();
/// try {
///   txn.put(LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('value1'), dbName: 'users');
///   txn.put(LMDBVal.fromUtf8('key2'), LMDBVal.fromUtf8('value2'), dbName: 'users');
///   txn.commit();
/// } catch (e) {
///   txn.abort();
///   rethrow;
/// }
/// ```
///
/// Read-only transactions (better concurrency for readers):
///
/// ```dart
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
/// # Performance-oriented environment flags
///
/// ```dart
/// db.init(
///   '/path/to/db',
///   flags: {
///     LMDBEnvFlag.noSync, // less durability, faster writes
///     LMDBEnvFlag.writeMap,
///   },
/// );
///
/// db.init(
///   '/path/to/db',
///   config: LMDBInitConfig.fromEstimate(
///     expectedEntries: 1000000,
///     averageKeySize: 16,
///     averageValueSize: 64,
///   ),
/// );
/// ```
///
/// Presets such as [LMDBFlagSet.readOnly] and [LMDBFlagSet.highPerformance] are available.
///
/// # Map size behavior
///
/// The map size sets the maximum database size:
///
/// 1. **Read-only access:** The environment can be opened with [LMDBEnvFlag.readOnly]; map size
///    requirements differ from read-write opens.
/// 2. **Write access:** Map size must be at least the current on-disk size; growth beyond
///    the map size fails with `MDB_MAP_FULL`. Map size is fixed for a given open.
/// 3. **Adjusting size:** Close the environment and reopen with a larger [LMDBInitConfig.mapSize].
///
/// ```dart
/// final db = LMDB();
/// db.init('/path/to/db', config: LMDBInitConfig(mapSize: 100 * 1024 * 1024));
/// ```
///
/// Choose map size from expected data growth, available memory, and workload.
///
/// # Monitoring and analysis
///
/// ```dart
/// final stats = db.stats(dbName: 'users');
/// print('Entries: ${stats.entries}, depth: ${stats.depth}');
/// print(stats.analyzeUsage());
///
/// final efficiency = stats.analyzeEfficiency();
/// if (!efficiency.isWellBalanced) {
///   print('Tree balance may warrant review');
/// }
///
/// final envStats = db.getEnvironmentStats();
/// print('Environment entries: ${envStats.entries}');
/// ```
///
/// # Common use cases
///
/// 1. **Simple key-value store:** Use [LMDB.put] / [LMDB.get] with [LMDBVal.fromUtf8] or
///    [LMDBVal.fromBytes].
/// 2. **Multiple logical tables:** Use named databases (`dbName`) with `maxDbs` set in config.
/// 3. **Batch writes:** Use one [LMDBTransaction] and multiple [LMDBTransaction.put] calls
///    before [LMDBTransaction.commit].
/// 4. **Concurrent access:** Many read transactions can overlap; at most one write
///    transaction at a time per environment.
///
/// # Best practices
///
/// * Call [LMDB.close] (or [LMDB.dispose]) when the environment is no longer needed.
/// * Pair [LMDB.txnStart] with [LMDBTransaction.commit] or [LMDBTransaction.abort] in
///   `try`/`finally`.
/// * Size the map appropriately before heavy writes.
/// * Prefer read-only transactions ([LMDBEnvFlag.readOnly]) for read-heavy workloads.
/// * Dispose [LMDBVal] instances you allocate; dispose values returned from [LMDB.get].
///
/// # Error handling
///
/// Failures from the native library throw [LMDBException]:
///
/// ```dart
/// try {
///   db.put(LMDBVal.fromUtf8('key'), LMDBVal.fromUtf8('value'));
/// } catch (e) {
///   if (e is LMDBException) {
///     print('LMDB: ${e.errorString} (${e.errorCode})');
///   }
/// }
/// ```
///
/// # Database organization
///
/// ```dart
/// import 'dart:convert';
///
/// void putJson(LMDB env, String dbName, String key, Object obj) {
///   final k = LMDBVal.fromUtf8(key);
///   final v = LMDBVal.fromUtf8(jsonEncode(obj));
///   env.put(k, v, dbName: dbName);
///   k.dispose();
///   v.dispose();
/// }
/// ```
///
/// # Maintenance
///
/// ```dart
/// db.sync(true); // flush to disk
///
/// final stats = db.getEnvironmentStats();
/// if (stats.overflowPages > 0) {
///   print('Warning: overflow pages present');
/// }
///
/// final efficiency = stats.analyzeEfficiency();
/// if (!efficiency.isWellBalanced) {
///   print('Warning: B+ tree balance may be suboptimal');
/// }
/// ```
///
/// # Platform notes
///
/// * **Windows:** Some flags (e.g. [LMDBEnvFlag.writeMap]) may behave differently than on Unix.
/// * **Linux / macOS:** Typical Unix file modes apply via [LMDBInitConfig.mode].
///
/// ```dart
/// import 'dart:io';
///
/// if (Platform.isWindows) {
///   db.init('/path/to/db', flags: {LMDBEnvFlag.noSync});
/// } else {
///   db.init(
///     '/path/to/db',
///     flags: {LMDBEnvFlag.noSync},
///     config: LMDBInitConfig(mapSize: 64 * 1024 * 1024, mode: '644'),
///   );
/// }
/// ```
///
/// # Batching example
///
/// ```dart
/// final txn = db.txnStart();
/// try {
///   for (var i = 0; i < 1000; i++) {
///     txn.put(
///       LMDBVal.fromUtf8('key$i'),
///       LMDBVal.fromUtf8('value$i'),
///       dbName: 'batch_data',
///     );
///   }
///   txn.commit();
/// } catch (e) {
///   txn.abort();
///   rethrow;
/// }
/// ```
///
/// # Memory and [LMDBVal]
///
/// LMDB memory-maps the file; your process address space should accommodate the map size.
/// [LMDBVal] wraps native buffers — dispose them when done to free allocations held by
/// the wrapper. Use [LMDBCursor] for iteration; call [LMDBCursor.close] when finished.
///
/// ```dart
/// db.init(
///   '/path/to/db',
///   config: LMDBInitConfig(
///     mapSize: LMDBConfig.calculateMapSize(
///       expectedEntries: 1000000,
///       averageKeySize: 16,
///       averageValueSize: 64,
///       overheadFactor: 1.5,
///     ),
///   ),
/// );
/// ```
library;

export 'src/database_stats.dart';
export 'src/lmdb_class.dart';
export 'src/lmdb_config.dart';
export 'src/lmdb_constants.dart';
export 'src/cursor_op.dart';
export 'src/lmdb_entry.dart';
export 'src/lmdb_exception.dart';
export 'src/lmdb_flags.dart';
export 'src/lmdb_val.dart';
