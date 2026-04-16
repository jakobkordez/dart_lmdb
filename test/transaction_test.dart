import 'dart:io';
import 'dart:isolate';
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

  test('Multiple operations in single transaction', () async {
    final txn = db.txnStart();
    try {
      // Put multiple items
      txn.put(LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('value1'));
      txn.put(LMDBVal.fromUtf8('key2'), LMDBVal.fromUtf8('value2'));
      txn.put(LMDBVal.fromUtf8('key3'), LMDBVal.fromUtf8('value3'));

      // Verify within same transaction
      var result1 = txn.get(LMDBVal.fromUtf8('key1'));
      var result2 = txn.get(LMDBVal.fromUtf8('key2'));
      var result3 = txn.get(LMDBVal.fromUtf8('key3'));

      expect(result1!.toUtf8String(), equals('value1'));
      expect(result2!.toUtf8String(), equals('value2'));
      expect(result3!.toUtf8String(), equals('value3'));

      // Delete one item
      txn.delete(LMDBVal.fromUtf8('key2'));

      // Verify deletion within transaction
      result2 = txn.get(LMDBVal.fromUtf8('key2'));
      expect(result2, isNull);

      txn.commit();
    } catch (e) {
      txn.abort();
      rethrow;
    }

    // Verify after transaction commit
    final result1 = db.get(LMDBVal.fromUtf8('key1'));
    final result2 = db.get(LMDBVal.fromUtf8('key2'));
    final result3 = db.get(LMDBVal.fromUtf8('key3'));

    expect(result1!.toUtf8String(), equals('value1'));
    expect(result2, isNull);
    expect(result3!.toUtf8String(), equals('value3'));
  });

  test('Transaction rollback', () async {
    // First put some data with auto transaction
    db.put(LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('initial_value'));

    // Start a transaction and modify data
    final txn = db.txnStart();
    try {
      txn.put(LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('modified_value'));
      txn.put(LMDBVal.fromUtf8('key2'), LMDBVal.fromUtf8('new_value'));

      // Verify changes within transaction
      var result1 = txn.get(LMDBVal.fromUtf8('key1'));
      var result2 = txn.get(LMDBVal.fromUtf8('key2'));

      expect(result1!.toUtf8String(), equals('modified_value'));
      expect(result2!.toUtf8String(), equals('new_value'));

      // Abort transaction instead of committing
      txn.abort();
    } catch (e) {
      txn.abort();
      rethrow;
    }

    // Verify that changes were rolled back
    final result1 = db.get(LMDBVal.fromUtf8('key1'));
    final result2 = db.get(LMDBVal.fromUtf8('key2'));

    expect(result1!.toUtf8String(), equals('initial_value'));
    expect(result2, isNull);
  });

  test('Normal transaction behavior (without MDB_NOTLS)', () async {
    final db = LMDB();
    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
    );

    // 1. Write some initial data
    final writeTxn = db.txnStart();
    try {
      writeTxn.put(LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('value1'));
      writeTxn.commit();
    } catch (e) {
      writeTxn.abort();
      rethrow;
    }

    // 2. Sequential read transactions
    final readTxn1 = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final result1 = readTxn1.get(LMDBVal.fromUtf8('key1'));
      expect(result1!.toUtf8String(), equals('value1'));
      readTxn1.commit();
    } catch (e) {
      readTxn1.abort();
      rethrow;
    }

    final readTxn2 = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final result2 = readTxn2.get(LMDBVal.fromUtf8('key1'));
      expect(result2!.toUtf8String(), equals('value1'));
      readTxn2.commit();
    } catch (e) {
      readTxn2.abort();
      rethrow;
    }

    // 3. Another write transaction
    final writeTxn2 = db.txnStart();
    try {
      writeTxn2.put(LMDBVal.fromUtf8('key2'), LMDBVal.fromUtf8('value2'));
      writeTxn2.commit();
    } catch (e) {
      writeTxn2.abort();
      rethrow;
    }

    // 4. Final read to verify all data
    final finalReadTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final result1 = finalReadTxn.get(LMDBVal.fromUtf8('key1'));
      final result2 = finalReadTxn.get(LMDBVal.fromUtf8('key2'));
      expect(result1!.toUtf8String(), equals('value1'));
      expect(result2!.toUtf8String(), equals('value2'));
      finalReadTxn.commit();
    } catch (e) {
      finalReadTxn.abort();
      rethrow;
    }

    db.close();
  });

  test('Advanced transaction scenarios', () async {
    final db = LMDB();
    db.init(
      testDir.path,
      config: LMDBInitConfig(
        mapSize: LMDBConfig.minMapSize,
        maxDbs: 2, // Allow named databases
      ),
    );

    // 1. Nested read transactions during write
    final writeTxn = db.txnStart();
    try {
      writeTxn.put(LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('value1'));

      // Start read transaction while write is in progress
      final readTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
      try {
        // Should not see uncommitted data
        final result = readTxn.get(LMDBVal.fromUtf8('key1'));
        expect(result, isNull);
        readTxn.commit();
      } catch (e) {
        readTxn.abort();
        rethrow;
      }

      // Complete write
      writeTxn.commit();
    } catch (e) {
      writeTxn.abort();
      rethrow;
    }

    // 2. Multiple database operations in single transaction
    final multiDbTxn = db.txnStart();
    try {
      // Write to default database
      multiDbTxn.put(
        LMDBVal.fromUtf8('default_key'),
        LMDBVal.fromUtf8('default_value'),
      );

      // Write to named database
      multiDbTxn.put(
        LMDBVal.fromUtf8('named_key'),
        LMDBVal.fromUtf8('named_value'),
        dbName: 'named_db',
      );

      multiDbTxn.commit();
    } catch (e) {
      multiDbTxn.abort();
      rethrow;
    }

    // 3. Read from both databases in single transaction
    final readBothTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final defaultResult = readBothTxn.get(LMDBVal.fromUtf8('default_key'));
      final namedResult = readBothTxn.get(
        LMDBVal.fromUtf8('named_key'),
        dbName: 'named_db',
      );

      expect(defaultResult!.toUtf8String(), equals('default_value'));
      expect(namedResult!.toUtf8String(), equals('named_value'));

      readBothTxn.commit();
    } catch (e) {
      readBothTxn.abort();
      rethrow;
    }

    // 4. Transaction with multiple operations and conditional commit/abort
    final complexTxn = db.txnStart();
    try {
      complexTxn.put(LMDBVal.fromUtf8('key_a'), LMDBVal.fromUtf8('value_a'));

      final existingValue = complexTxn.get(LMDBVal.fromUtf8('key1'));
      expect(existingValue!.toUtf8String(), equals('value1'));

      complexTxn.delete(LMDBVal.fromUtf8('key_a'));

      final deletedValue = complexTxn.get(LMDBVal.fromUtf8('key_a'));
      expect(deletedValue, isNull);

      complexTxn.commit();
    } catch (e) {
      complexTxn.abort();
      rethrow;
    }

    // 5. Verify final state with read-only transaction
    final finalTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      // Check original data
      final result1 = finalTxn.get(LMDBVal.fromUtf8('key1'));
      expect(result1!.toUtf8String(), equals('value1'));

      // Check multi-db data
      final defaultResult = finalTxn.get(LMDBVal.fromUtf8('default_key'));
      final namedResult = finalTxn.get(
        LMDBVal.fromUtf8('named_key'),
        dbName: 'named_db',
      );
      expect(defaultResult!.toUtf8String(), equals('default_value'));
      expect(namedResult!.toUtf8String(), equals('named_value'));

      // Check deleted data
      final deletedResult = finalTxn.get(LMDBVal.fromUtf8('key_a'));
      expect(deletedResult, isNull);

      finalTxn.commit();
    } catch (e) {
      finalTxn.abort();
      rethrow;
    }

    db.close();
  });

  test('Parallel read-only transactions with single environment', () async {
    // Create LMDB instances
    final db = LMDB();

    // Initialize instance
    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
    );

    // First populate the database with some data
    final writeTxn = db.txnStart();
    try {
      for (int i = 0; i < 100; i++) {
        writeTxn.put(LMDBVal.fromUtf8('key$i'), LMDBVal.fromUtf8('value$i'));
      }
      writeTxn.commit();
    } catch (e) {
      writeTxn.abort();
      rethrow;
    }

    // Now perform parallel reads using different instances
    final readFlags = {LMDBEnvFlag.readOnly};

    // Start parallel read transactions on different instances
    final results = await Future.wait([
      // First range on first instance
      Isolate.run(() async {
        final txn = db.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            30,
            (i) => txn.get(LMDBVal.fromUtf8('key$i')),
          );
          txn.commit();
          return results;
        } catch (e) {
          txn.abort();
          rethrow;
        }
      }),

      // Second range on second instance
      Isolate.run(() async {
        final txn = db.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            30,
            (i) => txn.get(LMDBVal.fromUtf8('key${i + 30}')),
          );
          txn.commit();
          return results;
        } catch (e) {
          txn.abort();
          rethrow;
        }
      }),

      // Third range on third instance
      Isolate.run(() async {
        final txn = db.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            40,
            (i) => txn.get(LMDBVal.fromUtf8('key${i + 60}')),
          );
          txn.commit();
          return results;
        } catch (e) {
          txn.abort();
          rethrow;
        }
      }),
    ]);

    for (int i = 0; i < 30; i++) {
      expect(
        results[0][i]!.toUtf8String(),
        equals('value$i'),
        reason: 'Mismatch in second instance range',
      );
    }
    for (int i = 0; i < 30; i++) {
      expect(
        results[1][i]!.toUtf8String(),
        equals('value${i + 30}'),
        reason: 'Mismatch in second instance range',
      );
    }
    for (int i = 0; i < 40; i++) {
      expect(
        results[2][i]!.toUtf8String(),
        equals('value${i + 60}'),
        reason: 'Mismatch in third instance range',
      );
    }

    // Verify we can still write after parallel reads
    final finalWriteTxn = db.txnStart();
    try {
      finalWriteTxn.put(
        LMDBVal.fromUtf8('final_key'),
        LMDBVal.fromUtf8('final_value'),
      );
      finalWriteTxn.commit();
    } catch (e) {
      finalWriteTxn.abort();
      rethrow;
    }

    // Verify the write is visible to other instances
    final readTxn = db.txnStart(flags: readFlags);
    try {
      final result = readTxn.get(LMDBVal.fromUtf8('final_key'));
      expect(result!.toUtf8String(), equals('final_value'));
      readTxn.commit();
    } catch (e) {
      readTxn.abort();
      rethrow;
    }

    // Clean up
    db.close();
  });

  test('Parallel read-only transactions with multiple environments', () async {
    // Create multiple LMDB instances for parallel access
    final db1 = LMDB();
    final db2 = LMDB();
    final db3 = LMDB();

    // Initialize all instances with the same database
    db1.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
    );

    db2.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
    );

    db3.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
    );

    // First populate the database with some data using the first instance
    final writeTxn = db1.txnStart();
    try {
      for (int i = 0; i < 100; i++) {
        writeTxn.put(LMDBVal.fromUtf8('key$i'), LMDBVal.fromUtf8('value$i'));
      }
      writeTxn.commit();
    } catch (e) {
      writeTxn.abort();
      rethrow;
    }

    // Now perform parallel reads using different instances
    final readFlags = {LMDBEnvFlag.readOnly};

    // Start parallel read transactions on different instances
    final results = await Future.wait([
      // First range on first instance
      Isolate.run(() async {
        final txn = db1.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            30,
            (i) => txn.get(LMDBVal.fromUtf8('key$i')),
          );
          txn.commit();
          return results;
        } catch (e) {
          txn.abort();
          rethrow;
        }
      }),

      // Second range on second instance
      Isolate.run(() async {
        final txn = db2.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            30,
            (i) => txn.get(LMDBVal.fromUtf8('key${i + 30}')),
          );
          txn.commit();
          return results;
        } catch (e) {
          txn.abort();
          rethrow;
        }
      }),

      // Third range on third instance
      Isolate.run(() async {
        final txn = db3.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            40,
            (i) => txn.get(LMDBVal.fromUtf8('key${i + 60}')),
          );
          txn.commit();
          return results;
        } catch (e) {
          txn.abort();
          rethrow;
        }
      }),
    ]);

    for (int i = 0; i < 30; i++) {
      expect(
        results[0][i]!.toUtf8String(),
        equals('value$i'),
        reason: 'Mismatch in second instance range',
      );
    }
    for (int i = 0; i < 30; i++) {
      expect(
        results[1][i]!.toUtf8String(),
        equals('value${i + 30}'),
        reason: 'Mismatch in second instance range',
      );
    }
    for (int i = 0; i < 40; i++) {
      expect(
        results[2][i]!.toUtf8String(),
        equals('value${i + 60}'),
        reason: 'Mismatch in third instance range',
      );
    }

    // Verify we can still write after parallel reads
    final finalWriteTxn = db1.txnStart();
    try {
      finalWriteTxn.put(
        LMDBVal.fromUtf8('final_key'),
        LMDBVal.fromUtf8('final_value'),
      );
      finalWriteTxn.commit();

      // Verify the write is visible to other instances
      final readTxn = db2.txnStart(flags: readFlags);
      try {
        final result = readTxn.get(LMDBVal.fromUtf8('final_key'));
        expect(result!.toUtf8String(), equals('final_value'));
        readTxn.commit();
      } catch (e) {
        readTxn.abort();
        rethrow;
      }
    } catch (e) {
      finalWriteTxn.abort();
      rethrow;
    }

    // Clean up
    db1.close();
    db2.close();
    db3.close();
  });

  test('Parallel transactions across multiple environments', () async {
    final db1 = LMDB();
    final db2 = LMDB();
    final db3 = LMDB();

    // Initialize all instances with the same database
    db1.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
    );
    db2.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
    );
    db3.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize),
    );

    // Run parallel operations that interact with each other
    await Future.wait([
      // Instance 1: Write data and verify reads from other instances
      Isolate.run(() async {
        for (int i = 0; i < 10; i++) {
          final writeTxn = db1.txnStart();
          try {
            writeTxn.put(
              LMDBVal.fromUtf8('key$i'),
              LMDBVal.fromUtf8('value$i'),
            );
            writeTxn.commit();

            // Give other instances a chance to read
            await Future.delayed(Duration(milliseconds: 10));
          } catch (e) {
            writeTxn.abort();
            rethrow;
          }
        }
      }),

      // Instance 2: Read data written by Instance 1 and write own data
      Isolate.run(() async {
        for (int i = 0; i < 10; i++) {
          // Read data written by Instance 1
          final readTxn = db2.txnStart(flags: {LMDBEnvFlag.readOnly});
          try {
            final result = readTxn.get(LMDBVal.fromUtf8('key$i'));
            if (result != null && result.toUtf8String() != 'value$i') {
              throw Exception('Mismatch in value for key$i');
            }
            readTxn.commit();
          } catch (e) {
            readTxn.abort();
            rethrow;
          }

          // Write own data
          final writeTxn = db2.txnStart();
          try {
            writeTxn.put(
              LMDBVal.fromUtf8('db2_key$i'),
              LMDBVal.fromUtf8('db2_value$i'),
            );
            writeTxn.commit();
          } catch (e) {
            writeTxn.abort();
            rethrow;
          }
        }
      }),

      // Instance 3: Read data from both Instance 1 and 2
      Isolate.run(() async {
        for (int i = 0; i < 10; i++) {
          final readTxn = db3.txnStart(flags: {LMDBEnvFlag.readOnly});
          try {
            // Try to read data from Instance 1
            final result1 = readTxn.get(LMDBVal.fromUtf8('key$i'));
            if (result1 != null && result1.toUtf8String() != 'value$i') {
              throw Exception('Mismatch in value for key$i');
            }

            // Try to read data from Instance 2
            final result2 = readTxn.get(LMDBVal.fromUtf8('db2_key$i'));
            if (result2 != null && result2.toUtf8String() != 'db2_value$i') {
              throw Exception('Mismatch in value for db2_key$i');
            }

            readTxn.commit();
          } catch (e) {
            readTxn.abort();
            rethrow;
          }

          // Short delay to allow other instances to write
          await Future.delayed(Duration(milliseconds: 5));
        }
      }),
    ]);

    // Final verification of all data
    final verifyTxn = db1.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      // Verify data written by Instance 1
      for (int i = 0; i < 10; i++) {
        final result1 = verifyTxn.get(LMDBVal.fromUtf8('key$i'));
        expect(result1!.toUtf8String(), equals('value$i'));
      }

      // Verify data written by Instance 2
      for (int i = 0; i < 10; i++) {
        final result2 = verifyTxn.get(LMDBVal.fromUtf8('db2_key$i'));
        expect(result2!.toUtf8String(), equals('db2_value$i'));
      }

      verifyTxn.commit();
    } catch (e) {
      verifyTxn.abort();
      rethrow;
    }

    // Clean up
    db1.close();
    db2.close();
    db3.close();
  });
}
