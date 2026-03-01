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
      db.put(txn, LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('value1'));
      db.put(txn, LMDBVal.fromUtf8('key2'), LMDBVal.fromUtf8('value2'));
      db.put(txn, LMDBVal.fromUtf8('key3'), LMDBVal.fromUtf8('value3'));

      // Verify within same transaction
      var result1 = db.get(txn, LMDBVal.fromUtf8('key1'));
      var result2 = db.get(txn, LMDBVal.fromUtf8('key2'));
      var result3 = db.get(txn, LMDBVal.fromUtf8('key3'));

      expect(result1!.toStringUtf8(), equals('value1'));
      expect(result2!.toStringUtf8(), equals('value2'));
      expect(result3!.toStringUtf8(), equals('value3'));

      // Delete one item
      db.delete(txn, LMDBVal.fromUtf8('key2'));

      // Verify deletion within transaction
      result2 = db.get(txn, LMDBVal.fromUtf8('key2'));
      expect(result2, isNull);

      db.txnCommit(txn);
    } catch (e) {
      db.txnAbort(txn);
      rethrow;
    }

    // Verify after transaction commit
    final result1 = db.getAuto(LMDBVal.fromUtf8('key1'));
    final result2 = db.getAuto(LMDBVal.fromUtf8('key2'));
    final result3 = db.getAuto(LMDBVal.fromUtf8('key3'));

    expect(result1!.toStringUtf8(), equals('value1'));
    expect(result2, isNull);
    expect(result3!.toStringUtf8(), equals('value3'));
  });

  test('Transaction rollback', () async {
    // First put some data with auto transaction
    db.putAuto(LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('initial_value'));

    // Start a transaction and modify data
    final txn = db.txnStart();
    try {
      db.put(txn, LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('modified_value'));
      db.put(txn, LMDBVal.fromUtf8('key2'), LMDBVal.fromUtf8('new_value'));

      // Verify changes within transaction
      var result1 = db.get(txn, LMDBVal.fromUtf8('key1'));
      var result2 = db.get(txn, LMDBVal.fromUtf8('key2'));

      expect(result1!.toStringUtf8(), equals('modified_value'));
      expect(result2!.toStringUtf8(), equals('new_value'));

      // Abort transaction instead of committing
      db.txnAbort(txn);
    } catch (e) {
      db.txnAbort(txn);
      rethrow;
    }

    // Verify that changes were rolled back
    final result1 = db.getAuto(LMDBVal.fromUtf8('key1'));
    final result2 = db.getAuto(LMDBVal.fromUtf8('key2'));

    expect(result1!.toStringUtf8(), equals('initial_value'));
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
      db.put(writeTxn, LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('value1'));
      db.txnCommit(writeTxn);
    } catch (e) {
      db.txnAbort(writeTxn);
      rethrow;
    }

    // 2. Sequential read transactions
    final readTxn1 = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    try {
      final result1 = db.get(readTxn1, LMDBVal.fromUtf8('key1'));
      expect(result1!.toStringUtf8(), equals('value1'));
      db.txnCommit(readTxn1);
    } catch (e) {
      db.txnAbort(readTxn1);
      rethrow;
    }

    final readTxn2 = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    try {
      final result2 = db.get(readTxn2, LMDBVal.fromUtf8('key1'));
      expect(result2!.toStringUtf8(), equals('value1'));
      db.txnCommit(readTxn2);
    } catch (e) {
      db.txnAbort(readTxn2);
      rethrow;
    }

    // 3. Another write transaction
    final writeTxn2 = db.txnStart();
    try {
      db.put(writeTxn2, LMDBVal.fromUtf8('key2'), LMDBVal.fromUtf8('value2'));
      db.txnCommit(writeTxn2);
    } catch (e) {
      db.txnAbort(writeTxn2);
      rethrow;
    }

    // 4. Final read to verify all data
    final finalReadTxn = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    try {
      final result1 = db.get(finalReadTxn, LMDBVal.fromUtf8('key1'));
      final result2 = db.get(finalReadTxn, LMDBVal.fromUtf8('key2'));
      expect(result1!.toStringUtf8(), equals('value1'));
      expect(result2!.toStringUtf8(), equals('value2'));
      db.txnCommit(finalReadTxn);
    } catch (e) {
      db.txnAbort(finalReadTxn);
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
      db.put(writeTxn, LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('value1'));

      // Start read transaction while write is in progress
      final readTxn = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
      try {
        // Should not see uncommitted data
        final result = db.get(readTxn, LMDBVal.fromUtf8('key1'));
        expect(result, isNull);
        db.txnCommit(readTxn);
      } catch (e) {
        db.txnAbort(readTxn);
        rethrow;
      }

      // Complete write
      db.txnCommit(writeTxn);
    } catch (e) {
      db.txnAbort(writeTxn);
      rethrow;
    }

    // 2. Multiple database operations in single transaction
    final multiDbTxn = db.txnStart();
    try {
      // Write to default database
      db.put(
        multiDbTxn,
        LMDBVal.fromUtf8('default_key'),
        LMDBVal.fromUtf8('default_value'),
      );

      // Write to named database
      db.put(
        multiDbTxn,
        LMDBVal.fromUtf8('named_key'),
        LMDBVal.fromUtf8('named_value'),
        dbName: 'named_db',
      );

      db.txnCommit(multiDbTxn);
    } catch (e) {
      db.txnAbort(multiDbTxn);
      rethrow;
    }

    // 3. Read from both databases in single transaction
    final readBothTxn = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    try {
      final defaultResult = db.get(
        readBothTxn,
        LMDBVal.fromUtf8('default_key'),
      );
      final namedResult = db.get(
        readBothTxn,
        LMDBVal.fromUtf8('named_key'),
        dbName: 'named_db',
      );

      expect(defaultResult!.toStringUtf8(), equals('default_value'));
      expect(namedResult!.toStringUtf8(), equals('named_value'));

      db.txnCommit(readBothTxn);
    } catch (e) {
      db.txnAbort(readBothTxn);
      rethrow;
    }

    // 4. Transaction with multiple operations and conditional commit/abort
    final complexTxn = db.txnStart();
    try {
      db.put(
        complexTxn,
        LMDBVal.fromUtf8('key_a'),
        LMDBVal.fromUtf8('value_a'),
      );

      final existingValue = db.get(complexTxn, LMDBVal.fromUtf8('key1'));
      expect(existingValue!.toStringUtf8(), equals('value1'));

      db.delete(complexTxn, LMDBVal.fromUtf8('key_a'));

      final deletedValue = db.get(complexTxn, LMDBVal.fromUtf8('key_a'));
      expect(deletedValue, isNull);

      db.txnCommit(complexTxn);
    } catch (e) {
      db.txnAbort(complexTxn);
      rethrow;
    }

    // 5. Verify final state with read-only transaction
    final finalTxn = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    try {
      // Check original data
      final result1 = db.get(finalTxn, LMDBVal.fromUtf8('key1'));
      expect(result1!.toStringUtf8(), equals('value1'));

      // Check multi-db data
      final defaultResult = db.get(finalTxn, LMDBVal.fromUtf8('default_key'));
      final namedResult = db.get(
        finalTxn,
        LMDBVal.fromUtf8('named_key'),
        dbName: 'named_db',
      );
      expect(defaultResult!.toStringUtf8(), equals('default_value'));
      expect(namedResult!.toStringUtf8(), equals('named_value'));

      // Check deleted data
      final deletedResult = db.get(finalTxn, LMDBVal.fromUtf8('key_a'));
      expect(deletedResult, isNull);

      db.txnCommit(finalTxn);
    } catch (e) {
      db.txnAbort(finalTxn);
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
        db.put(
          writeTxn,
          LMDBVal.fromUtf8('key$i'),
          LMDBVal.fromUtf8('value$i'),
        );
      }
      db.txnCommit(writeTxn);
    } catch (e) {
      db.txnAbort(writeTxn);
      rethrow;
    }

    // Now perform parallel reads using different instances
    final readFlags = LMDBFlagSet()..add(MDB_RDONLY);

    // Start parallel read transactions on different instances
    final results = await Future.wait([
      // First range on first instance
      Isolate.run(() async {
        final txn = db.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            30,
            (i) => db.get(txn, LMDBVal.fromUtf8('key$i')),
          );
          db.txnCommit(txn);
          return results;
        } catch (e) {
          db.txnAbort(txn);
          rethrow;
        }
      }),

      // Second range on second instance
      Isolate.run(() async {
        final txn = db.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            30,
            (i) => db.get(txn, LMDBVal.fromUtf8('key${i + 30}')),
          );
          db.txnCommit(txn);
          return results;
        } catch (e) {
          db.txnAbort(txn);
          rethrow;
        }
      }),

      // Third range on third instance
      Isolate.run(() async {
        final txn = db.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            40,
            (i) => db.get(txn, LMDBVal.fromUtf8('key${i + 60}')),
          );
          db.txnCommit(txn);
          return results;
        } catch (e) {
          db.txnAbort(txn);
          rethrow;
        }
      }),
    ]);

    for (int i = 0; i < 30; i++) {
      expect(
        results[0][i]!.toStringUtf8(),
        equals('value$i'),
        reason: 'Mismatch in second instance range',
      );
    }
    for (int i = 0; i < 30; i++) {
      expect(
        results[1][i]!.toStringUtf8(),
        equals('value${i + 30}'),
        reason: 'Mismatch in second instance range',
      );
    }
    for (int i = 0; i < 40; i++) {
      expect(
        results[2][i]!.toStringUtf8(),
        equals('value${i + 60}'),
        reason: 'Mismatch in third instance range',
      );
    }

    // Verify we can still write after parallel reads
    final finalWriteTxn = db.txnStart();
    try {
      db.put(
        finalWriteTxn,
        LMDBVal.fromUtf8('final_key'),
        LMDBVal.fromUtf8('final_value'),
      );
      db.txnCommit(finalWriteTxn);
    } catch (e) {
      db.txnAbort(finalWriteTxn);
      rethrow;
    }

    // Verify the write is visible to other instances
    final readTxn = db.txnStart(flags: readFlags);
    try {
      final result = db.get(readTxn, LMDBVal.fromUtf8('final_key'));
      expect(result!.toStringUtf8(), equals('final_value'));
      db.txnCommit(readTxn);
    } catch (e) {
      db.txnAbort(readTxn);
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
        db1.put(
          writeTxn,
          LMDBVal.fromUtf8('key$i'),
          LMDBVal.fromUtf8('value$i'),
        );
      }
      db1.txnCommit(writeTxn);
    } catch (e) {
      db1.txnAbort(writeTxn);
      rethrow;
    }

    // Now perform parallel reads using different instances
    final readFlags = LMDBFlagSet()..add(MDB_RDONLY);

    // Start parallel read transactions on different instances
    final results = await Future.wait([
      // First range on first instance
      Isolate.run(() async {
        final txn = db1.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            30,
            (i) => db1.get(txn, LMDBVal.fromUtf8('key$i')),
          );
          db1.txnCommit(txn);
          return results;
        } catch (e) {
          db1.txnAbort(txn);
          rethrow;
        }
      }),

      // Second range on second instance
      Isolate.run(() async {
        final txn = db2.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            30,
            (i) => db2.get(txn, LMDBVal.fromUtf8('key${i + 30}')),
          );
          db2.txnCommit(txn);
          return results;
        } catch (e) {
          db2.txnAbort(txn);
          rethrow;
        }
      }),

      // Third range on third instance
      Isolate.run(() async {
        final txn = db3.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            40,
            (i) => db3.get(txn, LMDBVal.fromUtf8('key${i + 60}')),
          );
          db3.txnCommit(txn);
          return results;
        } catch (e) {
          db3.txnAbort(txn);
          rethrow;
        }
      }),
    ]);

    for (int i = 0; i < 30; i++) {
      expect(
        results[0][i]!.toStringUtf8(),
        equals('value$i'),
        reason: 'Mismatch in second instance range',
      );
    }
    for (int i = 0; i < 30; i++) {
      expect(
        results[1][i]!.toStringUtf8(),
        equals('value${i + 30}'),
        reason: 'Mismatch in second instance range',
      );
    }
    for (int i = 0; i < 40; i++) {
      expect(
        results[2][i]!.toStringUtf8(),
        equals('value${i + 60}'),
        reason: 'Mismatch in third instance range',
      );
    }

    // Verify we can still write after parallel reads
    final finalWriteTxn = db1.txnStart();
    try {
      db1.put(
        finalWriteTxn,
        LMDBVal.fromUtf8('final_key'),
        LMDBVal.fromUtf8('final_value'),
      );
      db1.txnCommit(finalWriteTxn);

      // Verify the write is visible to other instances
      final readTxn = db2.txnStart(flags: readFlags);
      try {
        final result = db2.get(readTxn, LMDBVal.fromUtf8('final_key'));
        expect(result!.toStringUtf8(), equals('final_value'));
        db2.txnCommit(readTxn);
      } catch (e) {
        db2.txnAbort(readTxn);
        rethrow;
      }
    } catch (e) {
      db1.txnAbort(finalWriteTxn);
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
            db1.put(
              writeTxn,
              LMDBVal.fromUtf8('key$i'),
              LMDBVal.fromUtf8('value$i'),
            );
            db1.txnCommit(writeTxn);

            // Give other instances a chance to read
            await Future.delayed(Duration(milliseconds: 10));
          } catch (e) {
            db1.txnAbort(writeTxn);
            rethrow;
          }
        }
      }),

      // Instance 2: Read data written by Instance 1 and write own data
      Isolate.run(() async {
        for (int i = 0; i < 10; i++) {
          // Read data written by Instance 1
          final readTxn = db2.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
          try {
            final result = db2.get(readTxn, LMDBVal.fromUtf8('key$i'));
            if (result != null && result.toStringUtf8() != 'value$i') {
              throw Exception('Mismatch in value for key$i');
            }
            db2.txnCommit(readTxn);
          } catch (e) {
            db2.txnAbort(readTxn);
            rethrow;
          }

          // Write own data
          final writeTxn = db2.txnStart();
          try {
            db2.put(
              writeTxn,
              LMDBVal.fromUtf8('db2_key$i'),
              LMDBVal.fromUtf8('db2_value$i'),
            );
            db2.txnCommit(writeTxn);
          } catch (e) {
            db2.txnAbort(writeTxn);
            rethrow;
          }
        }
      }),

      // Instance 3: Read data from both Instance 1 and 2
      Isolate.run(() async {
        for (int i = 0; i < 10; i++) {
          final readTxn = db3.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
          try {
            // Try to read data from Instance 1
            final result1 = db3.get(readTxn, LMDBVal.fromUtf8('key$i'));
            if (result1 != null && result1.toStringUtf8() != 'value$i') {
              throw Exception('Mismatch in value for key$i');
            }

            // Try to read data from Instance 2
            final result2 = db3.get(readTxn, LMDBVal.fromUtf8('db2_key$i'));
            if (result2 != null && result2.toStringUtf8() != 'db2_value$i') {
              throw Exception('Mismatch in value for db2_key$i');
            }

            db3.txnCommit(readTxn);
          } catch (e) {
            db3.txnAbort(readTxn);
            rethrow;
          }

          // Short delay to allow other instances to write
          await Future.delayed(Duration(milliseconds: 5));
        }
      }),
    ]);

    // Final verification of all data
    final verifyTxn = db1.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    try {
      // Verify data written by Instance 1
      for (int i = 0; i < 10; i++) {
        final result1 = db1.get(verifyTxn, LMDBVal.fromUtf8('key$i'));
        expect(result1!.toStringUtf8(), equals('value$i'));
      }

      // Verify data written by Instance 2
      for (int i = 0; i < 10; i++) {
        final result2 = db1.get(verifyTxn, LMDBVal.fromUtf8('db2_key$i'));
        expect(result2!.toStringUtf8(), equals('db2_value$i'));
      }

      db1.txnCommit(verifyTxn);
    } catch (e) {
      db1.txnAbort(verifyTxn);
      rethrow;
    }

    // Clean up
    db1.close();
    db2.close();
    db3.close();
  });
}
