import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:dart_lmdb/dart_lmdb.dart';

// Helper function for transaction management
T _withTransaction<T>(
  LMDB db,
  T Function(LMDBTransaction) action, {
  bool readOnly = false,
}) => db.withTransaction(action, flags: readOnly ? LMDBFlagSet.readOnly : null);

// Helper class for pagination results
class PageResult {
  final List<LMDBEntry> entries;
  final String? nextPageKey;

  PageResult(this.entries, this.nextPageKey);
}

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

  test('Cursor operations', () async {
    // Test data
    final testData = {
      'user:1': '{"name": "John", "age": 30}',
      'user:2': '{"name": "Jane", "age": 25}',
      'user:3': '{"name": "Bob", "age": 35}',
    };

    // Write test data
    final writeTxn = db.txnStart();
    try {
      final cursor = writeTxn.cursorOpen();
      try {
        for (var entry in testData.entries) {
          cursor.put(
            LMDBVal.fromUtf8(entry.key),
            LMDBVal.fromUtf8(entry.value),
          );
        }
      } finally {
        cursor.close();
      }
      writeTxn.commit();
    } catch (e) {
      writeTxn.abort();
      rethrow;
    }

    // Test reading operations
    final readTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final cursor = readTxn.cursorOpen();
      try {
        // Test cursor count
        final count = readTxn.stats().entries;
        expect(count, equals(testData.length));

        // Test iteration through all entries
        var entry = cursor.getAuto(null, CursorOp.first);
        var foundEntries = 0;
        while (entry != null) {
          final key = entry.key.toUtf8String();
          final data = entry.data.toUtf8String();

          expect(testData.containsKey(key), isTrue);
          expect(testData[key], equals(data));

          foundEntries++;
          entry = cursor.getAuto(null, CursorOp.next);
        }
        expect(foundEntries, equals(testData.length));

        // Test specific key lookup
        final specificKey = 'user:2';
        entry = cursor.getAuto(LMDBVal.fromUtf8(specificKey), CursorOp.set);
        expect(entry, isNotNull);
        expect(entry?.key.toUtf8String(), equals(specificKey));
        expect(entry?.data.toUtf8String(), equals(testData[specificKey]));

        // Test range search
        entry = cursor.getAuto(LMDBVal.fromUtf8('user:'), CursorOp.setRange);
        expect(entry, isNotNull);
        expect(
          entry?.key.toUtf8String(),
          equals('user:1'),
        ); // Should find first user
      } finally {
        cursor.close();
      }
      readTxn.commit();
    } catch (e) {
      readTxn.abort();
      rethrow;
    }

    // Test deletion in a separate write transaction
    final deleteTxn = db.txnStart();
    try {
      final cursor = deleteTxn.cursorOpen();
      try {
        cursor.getAuto(LMDBVal.fromUtf8('user:2'), CursorOp.set);
        cursor.delete();
      } finally {
        cursor.close();
      }
      deleteTxn.commit();
    } catch (e) {
      deleteTxn.abort();
      rethrow;
    }

    // Verify deletion in a final read transaction
    final verifyTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final cursor = verifyTxn.cursorOpen();
      try {
        // Verify deletion
        final entry = cursor.getAuto(LMDBVal.fromUtf8('user:2'), CursorOp.set);
        expect(entry, isNull);

        // Verify remaining count
        final newCount = verifyTxn.stats().entries;
        expect(newCount, equals(testData.length - 1));
      } finally {
        cursor.close();
      }
      verifyTxn.commit();
    } catch (e) {
      verifyTxn.abort();
      rethrow;
    }
  });

  test('Cursor operations with grouped keys', () async {
    // Test data with different key groups
    final testData = {
      // Customer group
      'customer:001:name': 'John Doe',
      'customer:001:email': 'john@example.com',
      'customer:001:phone': '+1234567890',
      'customer:002:name': 'Jane Smith',
      'customer:002:email': 'jane@example.com',
      'customer:002:phone': '+1987654321',
      'customer:003:name': 'Bob Wilson',
      'customer:003:email': 'bob@example.com',
      'customer:003:phone': '+1122334455',

      // Product group
      'product:001:name': 'Laptop',
      'product:001:price': '999.99',
      'product:001:stock': '50',
      'product:002:name': 'Smartphone',
      'product:002:price': '599.99',
      'product:002:stock': '100',
      'product:003:name': 'Tablet',
      'product:003:price': '399.99',
      'product:003:stock': '75',

      // Order group
      'order:001:customer': 'customer:001',
      'order:001:product': 'product:002',
      'order:001:quantity': '2',
      'order:002:customer': 'customer:002',
      'order:002:product': 'product:001',
      'order:002:quantity': '1',
      'order:003:customer': 'customer:003',
      'order:003:product': 'product:003',
      'order:003:quantity': '3',
    };

    // Write test data
    final writeTxn = db.txnStart();
    try {
      final cursor = writeTxn.cursorOpen();
      try {
        for (var entry in testData.entries) {
          cursor.put(
            LMDBVal.fromUtf8(entry.key),
            LMDBVal.fromUtf8(entry.value),
          );
        }
      } finally {
        cursor.close();
      }
      writeTxn.commit();
    } catch (e) {
      writeTxn.abort();
      rethrow;
    }

    // Read and verify groups
    final readTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final cursor = readTxn.cursorOpen();
      try {
        // Test customer group
        var customerEntries = <String, String>{};
        var entry = cursor.getAuto(
          LMDBVal.fromUtf8('customer:'),
          CursorOp.setRange,
        );

        while (entry != null &&
            entry.key.toUtf8String().startsWith('customer:')) {
          customerEntries[entry.key.toUtf8String()] = entry.data.toUtf8String();
          entry = cursor.getAuto(null, CursorOp.next);
        }

        expect(customerEntries.length, equals(9)); // 3 customers × 3 fields
        expect(
          customerEntries.keys.every((k) => k.startsWith('customer:')),
          isTrue,
        );

        // Test product group
        var productEntries = <String, String>{};
        entry = cursor.getAuto(LMDBVal.fromUtf8('product:'), CursorOp.setRange);

        while (entry != null &&
            entry.key.toUtf8String().startsWith('product:')) {
          productEntries[entry.key.toUtf8String()] = entry.data.toUtf8String();
          entry = cursor.getAuto(null, CursorOp.next);
        }

        expect(productEntries.length, equals(9)); // 3 products × 3 fields
        expect(
          productEntries.keys.every((k) => k.startsWith('product:')),
          isTrue,
        );

        // Test order group
        var orderEntries = <String, String>{};
        entry = cursor.getAuto(LMDBVal.fromUtf8('order:'), CursorOp.setRange);

        while (entry != null && entry.key.toUtf8String().startsWith('order:')) {
          orderEntries[entry.key.toUtf8String()] = entry.data.toUtf8String();
          entry = cursor.getAuto(null, CursorOp.next);
        }

        expect(orderEntries.length, equals(9)); // 3 orders × 3 fields
        expect(orderEntries.keys.every((k) => k.startsWith('order:')), isTrue);

        // Test specific customer data
        var customer2Data = <String, String>{};
        entry = cursor.getAuto(
          LMDBVal.fromUtf8('customer:002:'),
          CursorOp.setRange,
        );

        while (entry != null &&
            entry.key.toUtf8String().startsWith('customer:002:')) {
          customer2Data[entry.key.toUtf8String()] = entry.data.toUtf8String();
          entry = cursor.getAuto(null, CursorOp.next);
        }

        expect(customer2Data.length, equals(3));
        expect(customer2Data['customer:002:name'], equals('Jane Smith'));
        expect(customer2Data['customer:002:email'], equals('jane@example.com'));
        expect(customer2Data['customer:002:phone'], equals('+1987654321'));

        // Verify no cross-contamination between groups
        expect(
          customerEntries.keys.any((k) => k.startsWith('product:')),
          isFalse,
        );
        expect(
          customerEntries.keys.any((k) => k.startsWith('order:')),
          isFalse,
        );
        expect(
          productEntries.keys.any((k) => k.startsWith('customer:')),
          isFalse,
        );
        expect(productEntries.keys.any((k) => k.startsWith('order:')), isFalse);
        expect(
          orderEntries.keys.any((k) => k.startsWith('customer:')),
          isFalse,
        );
        expect(orderEntries.keys.any((k) => k.startsWith('product:')), isFalse);
      } finally {
        cursor.close();
      }
      readTxn.commit();
    } catch (e) {
      readTxn.abort();
      rethrow;
    }
  });

  test('Cursor pagination', () async {
    // Setup test data - create enough entries for multiple pages
    final testEntries = List.generate(100, (index) {
      final paddedIndex = index.toString().padLeft(3, '0');
      return MapEntry('key:$paddedIndex', 'value for entry $paddedIndex');
    });

    // Write test data
    final writeTxn = db.txnStart();
    try {
      final cursor = writeTxn.cursorOpen();
      try {
        for (var entry in testEntries) {
          cursor.put(
            LMDBVal.fromUtf8(entry.key),
            LMDBVal.fromUtf8(entry.value),
          );
        }
      } finally {
        cursor.close();
      }
      writeTxn.commit();
    } catch (e) {
      writeTxn.abort();
      rethrow;
    }

    // Test pagination
    final readTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final cursor = readTxn.cursorOpen();
      try {
        // Test parameters
        const pageSize = 10;
        final totalPages = (testEntries.length / pageSize).ceil();

        // Helper function to get a page of results
        Future<List<LMDBEntry>> getPage(int pageNumber) async {
          final results = <LMDBEntry>[];

          // Always start from the beginning for each page request
          var entry = cursor.getAuto(null, CursorOp.first);

          // Skip entries for the requested page
          for (var i = 0; i < pageNumber * pageSize && entry != null; i++) {
            entry = cursor.getAuto(null, CursorOp.next);
          }

          // Collect entries for current page
          for (var i = 0; i < pageSize && entry != null; i++) {
            results.add(entry);
            entry = cursor.getAuto(null, CursorOp.next);
          }

          return results;
        }

        // Test first page (0-9)
        final firstPage = await getPage(0);
        expect(firstPage.length, equals(pageSize));
        expect(firstPage.first.key.toUtf8String(), equals('key:000'));
        expect(firstPage.last.key.toUtf8String(), equals('key:009'));

        // Test middle page (50-59)
        final middlePage = await getPage(5);
        expect(middlePage.length, equals(pageSize));
        expect(middlePage.first.key.toUtf8String(), equals('key:050'));
        expect(middlePage.last.key.toUtf8String(), equals('key:059'));

        // Test last page (90-99)
        final lastPage = await getPage(9);
        expect(lastPage.length, equals(pageSize));
        expect(lastPage.first.key.toUtf8String(), equals('key:090'));
        expect(lastPage.last.key.toUtf8String(), equals('key:099'));

        // Verify sequential access of all pages
        var allEntries = <LMDBEntry>[];
        for (var i = 0; i < totalPages; i++) {
          final page = await getPage(i);
          expect(
            page.length,
            i < totalPages - 1 ? equals(pageSize) : lessThanOrEqualTo(pageSize),
          );
          allEntries.addAll(page);
        }

        expect(allEntries.length, equals(testEntries.length));

        // Verify order and content
        for (var i = 0; i < allEntries.length; i++) {
          final paddedIndex = i.toString().padLeft(3, '0');
          expect(allEntries[i].key.toUtf8String(), equals('key:$paddedIndex'));
          expect(
            allEntries[i].data.toUtf8String(),
            equals('value for entry $paddedIndex'),
          );
        }
      } finally {
        cursor.close();
      }
      readTxn.commit();
    } catch (e) {
      readTxn.abort();
      rethrow;
    }
  });

  test('Cursor range-based pagination', () async {
    // Setup test data with date-based keys
    final testEntries = List.generate(100, (index) {
      final date = DateTime(2024, 1, 1).add(Duration(days: index));
      final formattedDate = date.toIso8601String().split('T').first;
      return MapEntry('entry:$formattedDate', 'value for day $index');
    });

    // Write test data
    final writeTxn = db.txnStart();
    try {
      final cursor = writeTxn.cursorOpen();
      try {
        for (var entry in testEntries) {
          cursor.put(
            LMDBVal.fromUtf8(entry.key),
            LMDBVal.fromUtf8(entry.value),
          );
        }
      } finally {
        cursor.close();
      }
      writeTxn.commit();
    } catch (e) {
      writeTxn.abort();
      rethrow;
    }

    // Test range-based pagination
    final readTxn = db.txnStart(flags: {LMDBEnvFlag.readOnly});
    try {
      final cursor = readTxn.cursorOpen();
      try {
        // Helper function to get entries within a date range
        Future<List<LMDBEntry>> getEntriesInRange(
          String startDate,
          String endDate,
        ) async {
          final results = <LMDBEntry>[];

          var entry = cursor.getAuto(
            LMDBVal.fromUtf8('entry:$startDate'),
            CursorOp.setRange,
          );

          while (entry != null &&
              entry.key.toUtf8String().compareTo('entry:$endDate') <= 0) {
            results.add(entry);
            entry = cursor.getAuto(null, CursorOp.next);
          }

          return results;
        }

        // Test first month
        final januaryEntries = await getEntriesInRange(
          '2024-01-01',
          '2024-01-31',
        );
        expect(januaryEntries.length, equals(31));
        expect(
          januaryEntries.first.key.toUtf8String(),
          equals('entry:2024-01-01'),
        );
        expect(
          januaryEntries.last.key.toUtf8String(),
          equals('entry:2024-01-31'),
        );

        // Test middle range
        final februaryEntries = await getEntriesInRange(
          '2024-02-01',
          '2024-02-29',
        );
        expect(februaryEntries.length, equals(29));
        expect(
          februaryEntries.first.key.toUtf8String(),
          equals('entry:2024-02-01'),
        );
        expect(
          februaryEntries.last.key.toUtf8String(),
          equals('entry:2024-02-29'),
        );

        // Test partial range
        final marchWeek = await getEntriesInRange('2024-03-01', '2024-03-07');
        expect(marchWeek.length, equals(7));
        expect(marchWeek.first.key.toUtf8String(), equals('entry:2024-03-01'));
        expect(marchWeek.last.key.toUtf8String(), equals('entry:2024-03-07'));
      } finally {
        cursor.close();
      }
      readTxn.commit();
    } catch (e) {
      readTxn.abort();
      rethrow;
    }
  });

  test('Efficient cursor-based pagination', () async {
    // Setup test data - create enough entries for multiple pages
    final testEntries = List.generate(100, (index) {
      final paddedIndex = index.toString().padLeft(3, '0');
      return MapEntry('key:$paddedIndex', 'value for entry $paddedIndex');
    });

    // Write test data
    _withTransaction(db, (txn) {
      final cursor = txn.cursorOpen();
      try {
        for (var entry in testEntries) {
          cursor.put(
            LMDBVal.fromUtf8(entry.key),
            LMDBVal.fromUtf8(entry.value),
          );
        }
      } finally {
        cursor.close();
      }
    });

    // Test efficient pagination
    _withTransaction(db, (txn) {
      final cursor = txn.cursorOpen();
      try {
        const pageSize = 10;

        // Helper function to get a page of results
        PageResult getPage(String? startAfterKey) {
          final results = <LMDBEntry>[];
          String? nextKey;

          // Get first entry - either from start or after the given key
          var entry = startAfterKey == null
              ? cursor.getAuto(null, CursorOp.first)
              : cursor.getAuto(
                  LMDBVal.fromUtf8(startAfterKey),
                  CursorOp.setRange,
                );

          // If we started from a specific key, we're already positioned at the next entry
          // No need for an extra next operation

          // Collect entries for current page
          while (entry != null && results.length < pageSize) {
            results.add(entry);
            entry = cursor.getAuto(null, CursorOp.next);
          }

          // Get the key for the next page
          if (entry != null) {
            nextKey = entry.key.toUtf8String();
          }

          return PageResult(results, nextKey);
        }

        // Test first page
        final firstPage = getPage(null);
        expect(firstPage.entries.length, equals(pageSize));
        expect(firstPage.entries.first.key.toUtf8String(), equals('key:000'));
        expect(firstPage.entries.last.key.toUtf8String(), equals('key:009'));
        expect(firstPage.nextPageKey, equals('key:010'));

        // Test middle page using next key from first page
        final middlePage = getPage(firstPage.nextPageKey);
        expect(middlePage.entries.length, equals(pageSize));
        expect(middlePage.entries.first.key.toUtf8String(), equals('key:010'));
        expect(middlePage.entries.last.key.toUtf8String(), equals('key:019'));
        expect(middlePage.nextPageKey, equals('key:020'));

        // Collect all pages efficiently
        var allEntries = <LMDBEntry>[];
        String? currentPageKey;

        while (true) {
          final page = getPage(currentPageKey);
          allEntries.addAll(page.entries);

          if (page.nextPageKey == null) {
            break;
          }
          currentPageKey = page.nextPageKey;
        }

        // Verify complete dataset
        expect(allEntries.length, equals(testEntries.length));

        for (var i = 0; i < allEntries.length; i++) {
          final paddedIndex = i.toString().padLeft(3, '0');
          expect(allEntries[i].key.toUtf8String(), equals('key:$paddedIndex'));
          expect(
            allEntries[i].data.toUtf8String(),
            equals('value for entry $paddedIndex'),
          );
        }

        // Test seeking to specific page by key
        final specificPage = getPage('key:050');
        expect(
          specificPage.entries.first.key.toUtf8String(),
          equals('key:050'),
        );
        expect(specificPage.entries.last.key.toUtf8String(), equals('key:059'));

        // Test last page
        final lastPage = getPage('key:090');
        expect(lastPage.entries.length, equals(10));
        expect(lastPage.entries.first.key.toUtf8String(), equals('key:090'));
        expect(lastPage.entries.last.key.toUtf8String(), equals('key:099'));
        expect(lastPage.nextPageKey, isNull);
      } finally {
        cursor.close();
      }
    }, readOnly: true);
  });

  test('Cursor operations with binary data', () async {
    // Write binary data
    _withTransaction(db, (txn) {
      final cursor = txn.cursorOpen();
      try {
        cursor.put(
          LMDBVal.fromBytes([0x12, 0x34, 0x56]),
          LMDBVal.fromBytes([0xFF, 0xFE, 0xFD]),
        );
        cursor.put(
          LMDBVal.fromBytes([0x45, 0x67, 0x89]),
          LMDBVal.fromBytes([0xAA, 0xBB, 0xCC]),
        );
      } finally {
        cursor.close();
      }
    });

    // Read and verify binary data
    _withTransaction(db, (txn) {
      final cursor = txn.cursorOpen();
      try {
        var entry = cursor.getAuto(null, CursorOp.first);

        expect(entry?.key.asBytes(), equals([0x12, 0x34, 0x56]));
        expect(entry?.data.asBytes(), equals([0xFF, 0xFE, 0xFD]));

        entry = cursor.getAuto(null, CursorOp.next);
        expect(entry?.key.asBytes(), equals([0x45, 0x67, 0x89]));
        expect(entry?.data.asBytes(), equals([0xAA, 0xBB, 0xCC]));
      } finally {
        cursor.close();
      }
    }, readOnly: true);
  });
}
