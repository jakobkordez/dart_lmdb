import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:dart_lmdb/dart_lmdb.dart';

void main() {
  late LMDB db;
  late String dbPath;
  late Directory testDir;

  setUp(() async {
    // Create test directory with unique name
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

    dbPath = testDir.path;

    // Initialize database
    db = LMDB();
    try {
      final config = LMDBInitConfig(mapSize: LMDBConfig.minMapSize);
      db.init(dbPath, config: config);
    } catch (e) {
      // If initialization fails, clean up and rethrow
      testDir.deleteSync(recursive: true);
      rethrow;
    }
  });

  tearDown(() async {
    // Ensure database is properly closed
    try {
      db.close();
    } catch (e) {
      print('Warning: Error during database closure: $e');
    } finally {
      // Always try to clean up the test directory
      try {
        if (testDir.existsSync()) {
          testDir.deleteSync(recursive: true);
        }
      } catch (e) {
        print('Warning: Error during test directory cleanup: $e');
      }
    }
  });

  test('Version', () {
    final version = LMDB.getVersion();
    expect(version, contains('LMDB'));
  });

  test('Basic put and get operations with auto transactions', () async {
    final key = 'test_key';
    final value = 'test_value';

    db.put(LMDBVal.fromUtf8(key), LMDBVal.fromUtf8(value));
    final result = db.get(LMDBVal.fromUtf8(key));

    expect(result, isNotNull);
    expect(result!.toUtf8String(), equals(value));
  });

  test('Delete data with auto transaction', () async {
    final key = 'test_key';
    final value = 'test_value';

    db.put(LMDBVal.fromUtf8(key), LMDBVal.fromUtf8(value));
    db.delete(LMDBVal.fromUtf8(key));
    final result = db.get(LMDBVal.fromUtf8(key));

    expect(result, isNull);
  });

  test('Non-existent key returns null with auto transaction', () async {
    final result = db.get(LMDBVal.fromUtf8('non_existent_key'));
    expect(result, isNull);
  });

  test('UTF-8 string operations', () async {
    final db = LMDB();
    db.init(testDir.path);

    // Test with different string types
    final testData = {
      'simple': 'Hello World',
      'unicode': 'Hello 世界 🌍',
      'multiline': 'Line 1\nLine 2\nLine 3',
      'special': 'Special chars: äöüß',
    };

    // Write with explicit transaction
    final writeTxn = db.txnStart();
    try {
      for (var entry in testData.entries) {
        writeTxn.put(
          LMDBVal.fromUtf8(entry.key),
          LMDBVal.fromUtf8(entry.value),
        );
      }
      writeTxn.commit();
    } catch (e) {
      writeTxn.abort();
      rethrow;
    }

    // Read with explicit transaction
    final readTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      for (var entry in testData.entries) {
        final result = readTxn.get(LMDBVal.fromUtf8(entry.key));
        expect(result!.toUtf8String(), equals(entry.value));
      }
      readTxn.commit();
    } catch (e) {
      readTxn.abort();
      rethrow;
    }

    // Test with auto transactions
    db.put(
      LMDBVal.fromUtf8('auto_key'),
      LMDBVal.fromUtf8('Auto Transaction Test'),
    );
    final autoResult = db.get(LMDBVal.fromUtf8('auto_key'));
    expect(autoResult!.toUtf8String(), equals('Auto Transaction Test'));

    db.close();
  });
}
