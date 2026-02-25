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

  test('Multiple operations in single transaction', () async {
    final txn = db.txnStart();
    try {
      // Put multiple items
      db.put(txn, 'key1', 'value1'.codeUnits);
      db.put(txn, 'key2', 'value2'.codeUnits);
      db.put(txn, 'key3', 'value3'.codeUnits);

      // Verify within same transaction
      var result1 = db.get(txn, 'key1');
      var result2 = db.get(txn, 'key2');
      var result3 = db.get(txn, 'key3');

      expect(String.fromCharCodes(result1!), equals('value1'));
      expect(String.fromCharCodes(result2!), equals('value2'));
      expect(String.fromCharCodes(result3!), equals('value3'));

      // Delete one item
      db.delete(txn, 'key2');

      // Verify deletion within transaction
      result2 = db.get(txn, 'key2');
      expect(result2, isNull);

      db.txnCommit(txn);
    } catch (e) {
      db.txnAbort(txn);
      rethrow;
    }

    // Verify after transaction commit
    final result1 = db.getAuto('key1');
    final result2 = db.getAuto('key2');
    final result3 = db.getAuto('key3');

    expect(String.fromCharCodes(result1!), equals('value1'));
    expect(result2, isNull);
    expect(String.fromCharCodes(result3!), equals('value3'));
  });

  test('Transaction rollback', () async {
    // First put some data with auto transaction
    db.putAuto('key1', 'initial_value'.codeUnits);

    // Start a transaction and modify data
    final txn = db.txnStart();
    try {
      db.put(txn, 'key1', 'modified_value'.codeUnits);
      db.put(txn, 'key2', 'new_value'.codeUnits);

      // Verify changes within transaction
      var result1 = db.get(txn, 'key1');
      var result2 = db.get(txn, 'key2');

      expect(String.fromCharCodes(result1!), equals('modified_value'));
      expect(String.fromCharCodes(result2!), equals('new_value'));

      // Abort transaction instead of committing
      db.txnAbort(txn);
    } catch (e) {
      db.txnAbort(txn);
      rethrow;
    }

    // Verify that changes were rolled back
    final result1 = db.getAuto('key1');
    final result2 = db.getAuto('key2');

    expect(String.fromCharCodes(result1!), equals('initial_value'));
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
      db.put(writeTxn, 'key1', 'value1'.codeUnits);
      db.txnCommit(writeTxn);
    } catch (e) {
      db.txnAbort(writeTxn);
      rethrow;
    }

    // 2. Sequential read transactions
    final readTxn1 = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    try {
      final result1 = db.get(readTxn1, 'key1');
      expect(String.fromCharCodes(result1!), equals('value1'));
      db.txnCommit(readTxn1);
    } catch (e) {
      db.txnAbort(readTxn1);
      rethrow;
    }

    final readTxn2 = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    try {
      final result2 = db.get(readTxn2, 'key1');
      expect(String.fromCharCodes(result2!), equals('value1'));
      db.txnCommit(readTxn2);
    } catch (e) {
      db.txnAbort(readTxn2);
      rethrow;
    }

    // 3. Another write transaction
    final writeTxn2 = db.txnStart();
    try {
      db.put(writeTxn2, 'key2', 'value2'.codeUnits);
      db.txnCommit(writeTxn2);
    } catch (e) {
      db.txnAbort(writeTxn2);
      rethrow;
    }

    // 4. Final read to verify all data
    final finalReadTxn = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
    try {
      final result1 = db.get(finalReadTxn, 'key1');
      final result2 = db.get(finalReadTxn, 'key2');
      expect(String.fromCharCodes(result1!), equals('value1'));
      expect(String.fromCharCodes(result2!), equals('value2'));
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
      db.put(writeTxn, 'key1', 'value1'.codeUnits);

      // Start read transaction while write is in progress
      final readTxn = db.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
      try {
        // Should not see uncommitted data
        final result = db.get(readTxn, 'key1');
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
      db.put(multiDbTxn, 'default_key', 'default_value'.codeUnits);

      // Write to named database
      db.put(
        multiDbTxn,
        'named_key',
        'named_value'.codeUnits,
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
      final defaultResult = db.get(readBothTxn, 'default_key');
      final namedResult = db.get(readBothTxn, 'named_key', dbName: 'named_db');

      expect(String.fromCharCodes(defaultResult!), equals('default_value'));
      expect(String.fromCharCodes(namedResult!), equals('named_value'));

      db.txnCommit(readBothTxn);
    } catch (e) {
      db.txnAbort(readBothTxn);
      rethrow;
    }

    // 4. Transaction with multiple operations and conditional commit/abort
    final complexTxn = db.txnStart();
    try {
      db.put(complexTxn, 'key_a', 'value_a'.codeUnits);

      final existingValue = db.get(complexTxn, 'key1');
      expect(String.fromCharCodes(existingValue!), equals('value1'));

      db.delete(complexTxn, 'key_a');

      final deletedValue = db.get(complexTxn, 'key_a');
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
      final result1 = db.get(finalTxn, 'key1');
      expect(String.fromCharCodes(result1!), equals('value1'));

      // Check multi-db data
      final defaultResult = db.get(finalTxn, 'default_key');
      final namedResult = db.get(finalTxn, 'named_key', dbName: 'named_db');
      expect(String.fromCharCodes(defaultResult!), equals('default_value'));
      expect(String.fromCharCodes(namedResult!), equals('named_value'));

      // Check deleted data
      final deletedResult = db.get(finalTxn, 'key_a');
      expect(deletedResult, isNull);

      db.txnCommit(finalTxn);
    } catch (e) {
      db.txnAbort(finalTxn);
      rethrow;
    }

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
        db1.put(writeTxn, 'key$i', 'value$i'.codeUnits);
      }
      db1.txnCommit(writeTxn);
    } catch (e) {
      db1.txnAbort(writeTxn);
      rethrow;
    }

    // Now perform parallel reads using different instances
    final readFlags = LMDBFlagSet()..add(MDB_RDONLY);

    // Start parallel read transactions on different instances
    await Future.wait([
      // First range on first instance
      Future(() async {
        final txn = db1.txnStart(flags: readFlags);
        try {
          final results = List.generate(30, (i) => db1.get(txn, 'key$i'));
          for (int i = 0; i < 30; i++) {
            expect(
              String.fromCharCodes(results[i]!),
              equals('value$i'),
              reason: 'Mismatch in first instance range',
            );
          }
          db1.txnCommit(txn);
        } catch (e) {
          db1.txnAbort(txn);
          rethrow;
        }
      }),

      // Second range on second instance
      Future(() async {
        final txn = db2.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            30,
            (i) => db2.get(txn, 'key${i + 30}'),
          );
          for (int i = 0; i < 30; i++) {
            expect(
              String.fromCharCodes(results[i]!),
              equals('value${i + 30}'),
              reason: 'Mismatch in second instance range',
            );
          }
          db2.txnCommit(txn);
        } catch (e) {
          db2.txnAbort(txn);
          rethrow;
        }
      }),

      // Third range on third instance
      Future(() async {
        final txn = db3.txnStart(flags: readFlags);
        try {
          final results = List.generate(
            40,
            (i) => db3.get(txn, 'key${i + 60}'),
          );
          for (int i = 0; i < 40; i++) {
            expect(
              String.fromCharCodes(results[i]!),
              equals('value${i + 60}'),
              reason: 'Mismatch in third instance range',
            );
          }
          db3.txnCommit(txn);
        } catch (e) {
          db3.txnAbort(txn);
          rethrow;
        }
      }),
    ]);

    // Verify we can still write after parallel reads
    final finalWriteTxn = db1.txnStart();
    try {
      db1.put(finalWriteTxn, 'final_key', 'final_value'.codeUnits);
      db1.txnCommit(finalWriteTxn);

      // Verify the write is visible to other instances
      final readTxn = db2.txnStart(flags: readFlags);
      try {
        final result = db2.get(readTxn, 'final_key');
        expect(String.fromCharCodes(result!), equals('final_value'));
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
      Future(() async {
        for (int i = 0; i < 10; i++) {
          final writeTxn = db1.txnStart();
          try {
            db1.put(writeTxn, 'key$i', 'value$i'.codeUnits);
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
      Future(() async {
        for (int i = 0; i < 10; i++) {
          // Read data written by Instance 1
          final readTxn = db2.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
          try {
            final result = db2.get(readTxn, 'key$i');
            if (result != null) {
              expect(String.fromCharCodes(result), equals('value$i'));
            }
            db2.txnCommit(readTxn);
          } catch (e) {
            db2.txnAbort(readTxn);
            rethrow;
          }

          // Write own data
          final writeTxn = db2.txnStart();
          try {
            db2.put(writeTxn, 'db2_key$i', 'db2_value$i'.codeUnits);
            db2.txnCommit(writeTxn);
          } catch (e) {
            db2.txnAbort(writeTxn);
            rethrow;
          }
        }
      }),

      // Instance 3: Read data from both Instance 1 and 2
      Future(() async {
        for (int i = 0; i < 10; i++) {
          final readTxn = db3.txnStart(flags: LMDBFlagSet()..add(MDB_RDONLY));
          try {
            // Try to read data from Instance 1
            final result1 = db3.get(readTxn, 'key$i');
            if (result1 != null) {
              expect(String.fromCharCodes(result1), equals('value$i'));
            }

            // Try to read data from Instance 2
            final result2 = db3.get(readTxn, 'db2_key$i');
            if (result2 != null) {
              expect(String.fromCharCodes(result2), equals('db2_value$i'));
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
        final result1 = db1.get(verifyTxn, 'key$i');
        expect(String.fromCharCodes(result1!), equals('value$i'));
      }

      // Verify data written by Instance 2
      for (int i = 0; i < 10; i++) {
        final result2 = db1.get(verifyTxn, 'db2_key$i');
        expect(String.fromCharCodes(result2!), equals('db2_value$i'));
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
