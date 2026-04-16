import 'generated_bindings.dart';

enum LMDBEnvFlag {
  /// mmap at a fixed address (experimental)
  fixedMap(MDB_FIXEDMAP),

  /// no environment directory
  noSubdir(MDB_NOSUBDIR),

  /// don't fsync after commit
  noSync(MDB_NOSYNC),

  /// read only
  readOnly(MDB_RDONLY),

  /// don't fsync metapage after commit
  noMetaSync(MDB_NOMETASYNC),

  /// use writable mmap
  writeMap(MDB_WRITEMAP),

  /// use asynchronous msync when [writeMap] is used
  mapAsync(MDB_MAPASYNC),

  /// tie reader locktable slots to transaction objects instead of to threads
  noTls(MDB_NOTLS),

  /// don't do any locking, caller must manage their own locks
  noLock(MDB_NOLOCK),

  /// don't do readahead (no effect on Windows)
  noReadAhead(MDB_NORDAHEAD),

  /// don't initialize malloc'd memory before writing to datafile
  noMemInit(MDB_NOMEMINIT),

  /// use the previous snapshot rather than the latest one
  prevSnapshot(MDB_PREVSNAPSHOT);

  final int value;
  const LMDBEnvFlag(this.value);
}

typedef LMDBEnvFlagSet = Set<LMDBEnvFlag>;

extension LMDBEnvFlagSetExtension on LMDBEnvFlagSet {
  int get value => toList().map((e) => e.value).fold(0, (a, b) => a | b);
}

enum LMDBDbiFlag {
  /// use reverse string keys
  reverseKey(MDB_REVERSEKEY),

  /// use sorted duplicates
  dupSort(MDB_DUPSORT),

  /// numeric keys in native byte order, either unsigned int or [mdb_size_t]
  integerKey(MDB_INTEGERKEY),

  /// with [dupSort], sorted dup items have fixed size
  dupFixed(MDB_DUPFIXED),

  /// with [dupSort], dups are [integerKey]-style integers
  integerDup(MDB_INTEGERDUP),

  /// with [dupSort], use reverse string dups
  reverseDup(MDB_REVERSEDUP),

  /// create DB if not already existing
  create(MDB_CREATE);

  final int value;
  const LMDBDbiFlag(this.value);
}

typedef LMDBDbiFlagSet = Set<LMDBDbiFlag>;

extension LMDBDbiFlagSetExtension on LMDBDbiFlagSet {
  int get value => toList().map((e) => e.value).fold(0, (a, b) => a | b);
}

enum LMDBWriteFlag {
  /// don't write if the key already exists
  noOverwrite(MDB_NOOVERWRITE),

  /// only for [dupSort], don't write if the key and data pair already exist
  noDupData(MDB_NODUPDATA),

  /// overwrite the current key/data pair
  current(MDB_CURRENT),

  /// just reserve space for data, don't copy it
  reserve(MDB_RESERVE),

  /// data is being appended, don't split full pages
  append(MDB_APPEND),

  /// duplicate data is being appended, don't split full pages
  appendDup(MDB_APPENDDUP),

  /// store multiple data items in one call
  multiple(MDB_MULTIPLE);

  final int value;
  const LMDBWriteFlag(this.value);
}

typedef LMDBWriteFlagSet = Set<LMDBWriteFlag>;

extension LMDBWriteFlagSetExtension on LMDBWriteFlagSet {
  int get value => toList().map((e) => e.value).fold(0, (a, b) => a | b);
}

enum LMDBCopyFlag {
  /// compact copy: omit free space from copy, and renumber all pages sequentially
  compact(MDB_CP_COMPACT);

  final int value;
  const LMDBCopyFlag(this.value);
}

typedef LMDBCopyFlagSet = Set<LMDBCopyFlag>;

extension LMDBCopyFlagSetExtension on LMDBCopyFlagSet {
  int get value => toList().map((e) => e.value).fold(0, (a, b) => a | b);
}

abstract final class LMDBFlagSet {
  /// Preset [LMDBEnvFlagSet] values for environment open and transactions.
  ///
  /// For custom combinations, use a literal set of [LMDBEnvFlag], e.g.
  /// `{LMDBEnvFlag.readOnly, LMDBEnvFlag.noTls}`.

  /// Preset for read-only database access.
  ///
  /// Uses [LMDBEnvFlag.readOnly] and [LMDBEnvFlag.noTls]
  /// (C API: `MDB_RDONLY`, `MDB_NOTLS`) for typical multi-reader scenarios.
  ///
  /// Important: Read the LMDB documentation thoroughly before using this
  /// flag combination in production.
  static const readOnly = {LMDBEnvFlag.readOnly, LMDBEnvFlag.noTls};

  /// Preset for read-only access to a database file in an unwritable directory.
  ///
  /// Combines [LMDBEnvFlag.readOnly], [LMDBEnvFlag.noSubdir],
  /// and [LMDBEnvFlag.noLock] (`MDB_RDONLY`, `MDB_NOSUBDIR`, `MDB_NOLOCK`).
  ///
  /// This is commonly used in mobile applications where the database
  /// might be bundled with the application in a read-only location.
  static const readOnlyFromAssets = {
    LMDBEnvFlag.readOnly,
    LMDBEnvFlag.noSubdir,
    LMDBEnvFlag.noLock,
  };

  /// Preset optimized for write throughput (weak durability).
  ///
  /// WARNING: This flag combination prioritizes performance over durability.
  /// It provides ACI (Atomicity, Consistency, Isolation) guarantees but NOT
  /// Durability. This means that the most recent transactions might be lost
  /// in case of a system crash.
  ///
  /// Includes [LMDBEnvFlag.writeMap], [LMDBEnvFlag.mapAsync],
  /// and [LMDBEnvFlag.noSync] (`MDB_WRITEMAP`, `MDB_MAPASYNC`, `MDB_NOSYNC`).
  ///
  /// IMPORTANT: Thoroughly understand the implications and read the LMDB
  /// documentation before using this in production environments.
  static const highPerformance = {
    LMDBEnvFlag.writeMap,
    LMDBEnvFlag.mapAsync,
    LMDBEnvFlag.noSync,
  };
}
