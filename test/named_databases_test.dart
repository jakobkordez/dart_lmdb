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
    testDir = Directory(
      path.join(
        Directory.current.path,
        'test_data',
        'named_db_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(10000)}',
      ),
    );

    if (testDir.existsSync()) {
      testDir.deleteSync(recursive: true);
    }
    testDir.createSync(recursive: true);

    dbPath = testDir.path;
    db = LMDB();

    try {
      final config = LMDBInitConfig(
        mapSize: LMDBConfig.minMapSize,
        maxDbs: 5, // Support multiple named databases
      );
      db.init(dbPath, config: config);
    } catch (e) {
      testDir.deleteSync(recursive: true);
      rethrow;
    }
  });

  tearDown(() {
    db.close();
    if (testDir.existsSync()) {
      testDir.deleteSync(recursive: true);
    }
  });

  test('Create and use multiple named databases', () async {
    // Use different named databases
    db.put(LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('value1'), dbName: 'db1');
    db.put(LMDBVal.fromUtf8('key1'), LMDBVal.fromUtf8('value2'), dbName: 'db2');
    db.put(
      LMDBVal.fromUtf8('key1'),
      LMDBVal.fromUtf8('value3'),
    ); // default database

    // Verify values in different databases
    final result1 = db.get(LMDBVal.fromUtf8('key1'), dbName: 'db1');
    final result2 = db.get(LMDBVal.fromUtf8('key1'), dbName: 'db2');
    final result3 = db.get(LMDBVal.fromUtf8('key1')); // default database

    expect(result1!.toUtf8String(), equals('value1'));
    expect(result2!.toUtf8String(), equals('value2'));
    expect(result3!.toUtf8String(), equals('value3'));
  });

  // test('List named databases', () async {
  //   // Create several named databases
  //   db.put(
  //     LMDBVal.fromUtf8('key'),
  //     LMDBVal.fromUtf8('value'),
  //     dbName: 'db1',
  //   );
  //   db.put(
  //     LMDBVal.fromUtf8('key'),
  //     LMDBVal.fromUtf8('value'),
  //     dbName: 'db2',
  //   );
  //   db.put(
  //     LMDBVal.fromUtf8('key'),
  //     LMDBVal.fromUtf8('value'),
  //     dbName: 'db3',
  //   );

  //   final databases = db.list();
  //   expect(databases, containsAll(['db1', 'db2', 'db3']));
  // });

  test('Database isolation', () async {
    // Put data in different databases
    db.put(LMDBVal.fromUtf8('key'), LMDBVal.fromUtf8('value1'), dbName: 'db1');
    db.put(LMDBVal.fromUtf8('key'), LMDBVal.fromUtf8('value2'), dbName: 'db2');

    // Delete from one database shouldn't affect others
    db.delete(LMDBVal.fromUtf8('key'), dbName: 'db1');

    final result1 = db.get(LMDBVal.fromUtf8('key'), dbName: 'db1');
    final result2 = db.get(LMDBVal.fromUtf8('key'), dbName: 'db2');

    expect(result1, isNull);
    expect(result2!.toUtf8String(), equals('value2'));
  });

  test('DBI caching test', () {
    final db = LMDB();
    db.init(
      testDir.path,
      config: LMDBInitConfig(mapSize: LMDBConfig.minMapSize, maxDbs: 5),
    );

    {
      final txn = db.txnStart();
      txn.put(
        LMDBVal.fromUtf8('key1'),
        LMDBVal.fromUtf8('value1'),
        dbName: 'db1',
      );
      txn.abort();
    }

    {
      final txn = db.txnStart();
      txn.put(
        LMDBVal.fromUtf8('key1'),
        LMDBVal.fromUtf8('value1'),
        dbName: 'db1',
      );
      txn.abort();
    }

    db.close();
  });
}
