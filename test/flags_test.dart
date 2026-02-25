import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:dart_lmdb/dart_lmdb.dart';

void main() {
  late Directory testDir;

  setUp(() {
    testDir = Directory(
      path.join(
        Directory.current.path,
        'test_data',
        'flags_db_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(10000)}',
      ),
    );

    if (testDir.existsSync()) {
      testDir.deleteSync(recursive: true);
    }
    testDir.createSync(recursive: true);
  });

  tearDown(() {
    if (testDir.existsSync()) {
      testDir.deleteSync(recursive: true);
    }
  });

  test('Read-only database access', () async {
    final dbPath = path.join(testDir.path, 'readonly_test');

    // First create and populate database
    final writeDb = LMDB();
    writeDb.init(
      dbPath,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize, mode: "0o666"),
    );
    writeDb.putAuto('key', 'value'.codeUnits);
    writeDb.close();

    // Now open in read-only mode
    final readDb = LMDB();
    final readOnlyFlags = LMDBFlagSet.readOnly;

    readDb.init(
      dbPath,
      config: LMDBInitConfig(
        mapSize: LMDBConfig.minMapSize,
        maxDbs: 1,
        mode: "0644",
      ),
      flags: readOnlyFlags,
    );

    // Should be able to read
    final result = readDb.getAuto('key');
    expect(String.fromCharCodes(result!), equals('value'));

    // Write operations should fail
    expect(
      () => readDb.putAuto('key2', 'value2'.codeUnits),
      throwsA(isA<LMDBException>()),
    );

    readDb.close();
  });

  test('High performance mode', () async {
    final db = LMDB();
    final highPerfFlags = LMDBFlagSet.highPerformance;

    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize, maxDbs: 1),
      flags: highPerfFlags,
    );

    // Perform rapid writes
    final txn = db.txnStart();
    try {
      for (int i = 0; i < 1000; i++) {
        db.put(txn, 'key$i', 'value$i'.codeUnits);
      }
      db.txnCommit(txn);
    } catch (e) {
      db.txnAbort(txn);
      rethrow;
    }

    // Force sync to ensure data is written
    db.sync(true);

    // Verify data
    for (int i = 0; i < 1000; i++) {
      final result = db.getAuto('key$i');
      expect(String.fromCharCodes(result!), equals('value$i'));
    }

    db.close();
  });

  test('No sub-directory mode', () async {
    final dbFile = File(path.join(testDir.path, 'data.mdb'));
    final lockFile = File(path.join(testDir.path, 'data.mdb-lock'));

    final db = LMDB();
    final noSubdirFlags = LMDBFlagSet()..add(MDB_NOSUBDIR);

    db.init(dbFile.path, flags: noSubdirFlags);

    db.putAuto('key', 'value'.codeUnits);
    final result = db.getAuto('key');

    expect(String.fromCharCodes(result!), equals('value'));
    expect(dbFile.existsSync(), isTrue);
    expect(lockFile.existsSync(), isTrue);

    db.close();
  });

  test('Combined flags test', () async {
    final dbPath = path.join(testDir.path, 'combined_flags');

    // Create with write access
    final writeDb = LMDB();
    final writeFlags = LMDBFlagSet()
      ..add(MDB_NOSUBDIR)
      ..add(MDB_NOSYNC); // Combine multiple flags

    writeDb.init(
      dbPath,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize, maxDbs: 1),
      flags: writeFlags,
    );

    writeDb.putAuto('key', 'value'.codeUnits);
    writeDb.close();

    // Open same file read-only
    final readDb = LMDB();
    final readFlags = LMDBFlagSet()
      ..add(MDB_NOSUBDIR)
      ..add(MDB_RDONLY);

    readDb.init(
      dbPath,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize, maxDbs: 1),
      flags: readFlags,
    );

    final result = readDb.getAuto('key');
    expect(String.fromCharCodes(result!), equals('value'));

    // Write should fail
    expect(
      () => readDb.putAuto('key2', 'value2'.codeUnits),
      throwsA(isA<LMDBException>()),
    );

    readDb.close();
  });

  test('Write map mode', () async {
    if (Platform.isWindows) {
      print('Test skipped on Windows - write map mode not supported (yet)');
      return;
    }
    final db = LMDB();
    final writeMapFlags = LMDBFlagSet()..add(MDB_WRITEMAP);

    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
      flags: writeMapFlags,
    );

    // Test write performance
    final txn = db.txnStart();
    try {
      for (int i = 0; i < 1000; i++) {
        db.put(txn, 'key$i', 'value$i'.codeUnits);
      }
      db.txnCommit(txn);
    } catch (e) {
      db.txnAbort(txn);
      rethrow;
    }

    db.close();
  });

  test('No lock mode with multiple readers', () async {
    final dbPath = path.join(testDir.path, 'nolock_test');

    // First create and populate database
    final writeDb = LMDB();
    writeDb.init(
      dbPath,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
    );

    // Add some test data
    writeDb.putAuto('key1', 'value1'.codeUnits);
    writeDb.putAuto('key2', 'value2'.codeUnits);
    writeDb.putAuto('key3', 'value3'.codeUnits);
    writeDb.close();

    // Now open multiple read-only instances without locking
    final noLockFlags = LMDBFlagSet()
      ..add(MDB_NOLOCK)
      ..add(MDB_RDONLY);

    // Create multiple readers
    final readers = await Future.wait(
      List.generate(5, (index) async {
        final db = LMDB();
        db.init(
          dbPath,
          config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
          flags: noLockFlags,
        );
        return db;
      }),
    );

    // Test concurrent reads from all instances
    await Future.wait(
      readers.map((db) async {
        final result1 = db.getAuto('key1');
        final result2 = db.getAuto('key2');
        final result3 = db.getAuto('key3');

        expect(String.fromCharCodes(result1!), equals('value1'));
        expect(String.fromCharCodes(result2!), equals('value2'));
        expect(String.fromCharCodes(result3!), equals('value3'));
      }),
    );

    // Clean up
    for (var db in readers) {
      db.close();
    }
  });

  test('No TLS mode', () async {
    final db = LMDB();
    final noTLSFlags = LMDBFlagSet()..add(MDB_NOTLS);

    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
      flags: noTLSFlags,
    );

    // With MDB_NOTLS, we should test sequential transactions
    // as transactions cannot be shared between threads
    for (int i = 0; i < 10; i++) {
      final txn = db.txnStart();
      try {
        db.put(txn, 'key$i', 'value$i'.codeUnits);
        db.txnCommit(txn);

        // Verify the write
        final result = db.getAuto('key$i');
        expect(String.fromCharCodes(result!), equals('value$i'));
      } catch (e) {
        db.txnAbort(txn);
        rethrow;
      }
    }

    db.close();
  });

  test('Transaction behavior with MDB_NOTLS', () async {
    final db = LMDB();
    final noTLSFlags = LMDBFlagSet()..add(MDB_NOTLS);

    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
      flags: noTLSFlags,
    );

    // 1. Single write transaction should work
    final writeTxn = db.txnStart();
    try {
      db.put(writeTxn, 'key1', 'value1'.codeUnits);
      db.txnCommit(writeTxn);
    } catch (e) {
      db.txnAbort(writeTxn);
      rethrow;
    }

    // 2. Multiple read-only transactions should work with MDB_NOTLS
    final txn1 = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    final txn2 = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));

    try {
      final result1 = db.get(txn1, 'key1');
      final result2 = db.get(txn2, 'key1');

      expect(String.fromCharCodes(result1!), equals('value1'));
      expect(String.fromCharCodes(result2!), equals('value1'));
    } finally {
      db.txnAbort(txn1);
      db.txnAbort(txn2);
    }

    db.close();
  });

  test('No metadata sync mode', () async {
    final db = LMDB();
    final noMetaSyncFlags = LMDBFlagSet()..add(MDB_NOMETASYNC);

    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
      flags: noMetaSyncFlags,
    );

    // Perform writes without metadata sync
    for (int i = 0; i < 100; i++) {
      db.putAuto('key$i', 'value$i'.codeUnits);
    }

    // Force sync
    db.sync(true);
    db.close();
  });

  test('Read ahead disabled mode', () async {
    final db = LMDB();
    final noReadAheadFlags = LMDBFlagSet()..add(MDB_NORDAHEAD);

    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
      flags: noReadAheadFlags,
    );

    // Test random access pattern
    final random = Random();
    final keys = List.generate(100, (i) => 'key$i');

    // First write all values
    for (var key in keys) {
      db.putAuto(key, 'value'.codeUnits);
    }

    // Then read in random order
    for (int i = 0; i < 50; i++) {
      final randomKey = keys[random.nextInt(keys.length)];
      final result = db.getAuto(randomKey);
      expect(result, isNotNull);
    }

    db.close();
  });

  test('Multiple flag combinations', () async {
    final db = LMDB();
    final combinedFlags = LMDBFlagSet()
      ..add(MDB_WRITEMAP)
      ..add(MDB_NOMETASYNC)
      ..add(MDB_NORDAHEAD)
      ..add(MDB_NOSYNC);

    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
      flags: combinedFlags,
    );

    // Test high-performance write scenario
    final txn = db.txnStart();
    try {
      for (int i = 0; i < 10000; i++) {
        db.put(txn, 'key$i', 'value$i'.codeUnits);
      }
      db.txnCommit(txn);
    } catch (e) {
      db.txnAbort(txn);
      rethrow;
    }

    // Force sync to ensure durability
    db.sync(true);
    db.close();
  });
}
