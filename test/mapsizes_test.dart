import 'package:test/test.dart';
import 'package:dart_lmdb/dart_lmdb.dart';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as path;

void main() {
  late Directory testDir;

  setUp(() {
    testDir = Directory(
      path.join(
        Directory.current.path,
        'test_data',
        'db_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(10000)}',
      ),
    );

    // Ensure clean state
    if (testDir.existsSync()) {
      testDir.deleteSync(recursive: true);
    }
    testDir.createSync(recursive: true);
  });

  tearDown(() {
    try {
      if (testDir.existsSync()) {
        testDir.deleteSync(recursive: true);
      }
    } catch (e) {
      print('Warning: Error during test directory cleanup: $e');
    }
  });

  test('DB size and read/write behavior test', () async {
    final db = LMDB();
    final largeMapSize = 100 * 1024 * 1024; // 100MB

    // 1. Create and fill large DB
    db.init(testDir.path, config: LMDBInitConfig(mapSize: largeMapSize));

    var txn = db.txnStart();
    try {
      // write ~75MB Daten
      for (var i = 0; i < 50000; i++) {
        final key = 'key_$i';
        final value = List.filled(1024, 42); // 1KB per entry
        txn.put(LMDBVal.fromUtf8(key), LMDBVal.fromBytes(value));
      }
      txn.commit();

      final stats = db.stats();
      final actualSize =
          stats.pageSize *
          (stats.branchPages + stats.leafPages + stats.overflowPages);
      print('Actual DB size: ${actualSize / (1024 * 1024)} MB');
    } catch (e) {
      txn.abort();
      rethrow;
    } finally {
      db.close();
    }

    // 2. open with smaller mapsize in READ-ONLY mode - should work:
    final smallMapSize = 1 * 1024 * 1024; // 1MB
    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: smallMapSize),
      flags: {LMDBEnvFlag.readOnly},
    );

    final readTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final data = readTxn.get(LMDBVal.fromUtf8('key_1'));
      expect(data, isNotNull);
      expect(data!.asBytes().length, equals(1024));
      readTxn.commit();
    } catch (e) {
      readTxn.abort();
      rethrow;
    } finally {
      db.close();
    }

    // 3. open with smaller mapsize and try writing - should fail:
    db.init(testDir.path, config: LMDBInitConfig(mapSize: smallMapSize));

    txn = db.txnStart();
    try {
      txn.put(LMDBVal.fromUtf8('new_key'), LMDBVal.fromUtf8('test_value'));
      txn.commit();
      fail('Should not be able to write with smaller mapsize');
    } catch (e) {
      expect(e, isA<LMDBException>());
      expect((e as LMDBException).errorCode, equals(MDB_MAP_FULL));
      txn.abort();
    } finally {
      db.close();
    }
  });

  test('MapSize limit test', () async {
    final db = LMDB();
    final smallMapSize = 1 * 1024 * 1024; // 1MB

    db.init(testDir.path, config: LMDBInitConfig(mapSize: smallMapSize));

    var txn = db.txnStart();
    try {
      // try writing more than mapsize
      for (var i = 0; i < 2000; i++) {
        // write ~2MB
        final key = 'key_$i';
        final value = List.filled(1024, 42); // 1KB per entry
        txn.put(LMDBVal.fromUtf8(key), LMDBVal.fromBytes(value));
      }
      txn.commit();
      fail('Should not be able to write beyond mapsize');
    } catch (e) {
      expect(e, isA<LMDBException>());
      expect((e as LMDBException).errorCode, equals(MDB_MAP_FULL));
      txn.abort();
      print('Got expected MDB_MAP_FULL error when exceeding mapsize');
    } finally {
      db.close();
    }
  });

  test('MapSize growth test', () async {
    final db = LMDB();

    // 1. create db with small initial mapsize:
    final initialMapSize = 10 * 1024 * 1024; // 10MB
    db.init(testDir.path, config: LMDBInitConfig(mapSize: initialMapSize));

    // fill db nearly to the limit:
    var txn = db.txnStart();
    try {
      for (var i = 0; i < 9; i++) {
        // ~9MB data
        final key = 'key_$i';
        final value = List.filled(1024 * 1024, 42); // 1KB per entry
        txn.put(LMDBVal.fromUtf8(key), LMDBVal.fromBytes(value));
      }
    } catch (e) {
      txn.abort();
      rethrow;
    }
    txn.commit();

    var stats = db.stats();
    var actualSize =
        stats.pageSize *
        (stats.branchPages + stats.leafPages + stats.overflowPages);
    print('Initial DB size: ${actualSize / (1024 * 1024)} MB');

    db.close();

    // 2. open with bigger mapsize
    final largerMapSize = 20 * 1024 * 1024; // 20MB
    db.init(testDir.path, config: LMDBInitConfig(mapSize: largerMapSize));

    // try writing more data
    txn = db.txnStart();
    try {
      for (var i = 9000; i < 15000; i++) {
        // more ~6MB
        final key = 'key_$i';
        final value = List.filled(1024, 42);
        txn.put(LMDBVal.fromUtf8(key), LMDBVal.fromBytes(value));
      }
      txn.commit();

      stats = db.stats();
      actualSize =
          stats.pageSize *
          (stats.branchPages + stats.leafPages + stats.overflowPages);
      print('Final DB size: ${actualSize / (1024 * 1024)} MB');
      print(
        'Successful growth from ${initialMapSize / (1024 * 1024)}MB to ${largerMapSize / (1024 * 1024)}MB mapsize',
      );
    } catch (e) {
      txn.abort();
      fail('Should be able to write with larger mapsize: $e');
    }

    db.close();
  });

  test('MapSize read performance comparison', () async {
    final db = LMDB();
    final largeMapSize = 100 * 1024 * 1024; // 100MB

    // 1. First create a large database
    db.init(testDir.path, config: LMDBInitConfig(mapSize: largeMapSize));
    var txn = db.txnStart();
    try {
      // Write ~95MB data
      for (var i = 0; i < 55000; i++) {
        final key = 'key_$i';
        final value = List.filled(1024, 42); // 1KB per entry
        txn.put(LMDBVal.fromUtf8(key), LMDBVal.fromBytes(value));
      }
      txn.commit();
      final stats = db.stats();
      final actualSize =
          stats.pageSize *
          (stats.branchPages + stats.leafPages + stats.overflowPages);
      print('Database size: ${actualSize / (1024 * 1024)} MB');
    } finally {
      db.close();
    }

    // 2. Read with small MapSize
    final smallMapSize = 1 * 1024 * 1024; // 1MB
    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: smallMapSize),
      flags: {LMDBEnvFlag.readOnly},
    );

    final stopwatch1 = Stopwatch()..start();
    txn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      // Random access to data
      for (var i = 0; i < 1000; i++) {
        final randomKey = 'key_${Random().nextInt(50000)}';
        final data = txn.get(LMDBVal.fromUtf8(randomKey));
        expect(data, isNotNull);
      }
    } finally {
      txn.commit();
      db.close();
    }
    final smallMapSizeTime = stopwatch1.elapsed;
    print('Read time with small MapSize: ${smallMapSizeTime.inMilliseconds}ms');

    // 3. Read with large MapSize
    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: largeMapSize),
      flags: {LMDBEnvFlag.readOnly},
    );

    final stopwatch2 = Stopwatch()..start();
    txn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      // Same random access pattern
      for (var i = 0; i < 1000; i++) {
        final randomKey = 'key_${Random().nextInt(50000)}';
        final data = txn.get(LMDBVal.fromUtf8(randomKey));
        expect(data, isNotNull);
      }
    } finally {
      txn.commit();
      db.close();
    }
    final largeMapSizeTime = stopwatch2.elapsed;
    print('Read time with large MapSize: ${largeMapSizeTime.inMilliseconds}ms');
  });
}
