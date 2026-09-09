import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:audiolens/services/history_service.dart';

/// Builds a database file matching the exact schema an app at [version]
/// would have produced, so migration tests exercise real historical
/// schemas rather than a synthetic approximation (T09).
Future<String> _createOldSchemaDb(Directory dir, int version) async {
  final path = join(dir.path, 'old_v$version.db');
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            imagePath TEXT NOT NULL,
            title TEXT NOT NULL,
            script TEXT NOT NULL,
            locationName TEXT,
            createdAt TEXT NOT NULL
          )
        ''');
        if (v >= 2) {
          await db.execute('ALTER TABLE history ADD COLUMN audioPath TEXT');
        }
        if (v >= 3) {
          await db.execute(
              "ALTER TABLE history ADD COLUMN status TEXT NOT NULL DEFAULT 'complete'");
        }
        if (v >= 4) {
          await db.execute('ALTER TABLE history ADD COLUMN ttsModel TEXT');
        }
        if (v >= 5) {
          for (final col in [
            'ALTER TABLE history ADD COLUMN aiModel TEXT',
            'ALTER TABLE history ADD COLUMN analyzedAt TEXT',
            'ALTER TABLE history ADD COLUMN analysisSource TEXT',
            'ALTER TABLE history ADD COLUMN gpsSource TEXT',
            'ALTER TABLE history ADD COLUMN wikipediaUsed INTEGER NOT NULL DEFAULT 0',
            'ALTER TABLE history ADD COLUMN wordCount INTEGER',
            'ALTER TABLE history ADD COLUMN analysisDurationMs INTEGER',
            'ALTER TABLE history ADD COLUMN gpsLatitude REAL',
            'ALTER TABLE history ADD COLUMN gpsLongitude REAL',
            'ALTER TABLE history ADD COLUMN gpsAddress TEXT',
          ]) {
            await db.execute(col);
          }
        }
        if (v >= 6) {
          await db.execute('ALTER TABLE history ADD COLUMN aiFallback INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE history ADD COLUMN ttsFallback INTEGER NOT NULL DEFAULT 0');
        }
      },
    ),
  );

  await db.insert('history', {
    'imagePath': '/tmp/photo_v$version.jpg',
    'title': 'Entry from schema v$version',
    'script': 'Some narration text.',
    'locationName': 'Paris',
    'createdAt': DateTime(2026, 1, version).toIso8601String(),
  });
  await db.close();
  return path;
}

/// Builds a full v9 schema (matching HistoryService's own onCreate table
/// definition, since v9 is the last version before #288's repair
/// migration) with caller-supplied rows — used to set up specific
/// ttsModel/audioPath combinations the v10 migration needs to
/// distinguish, which the simpler incremental helper above isn't meant
/// to express.
Future<String> _createV9DbWithRows(
  Directory dir,
  String name,
  List<Map<String, Object?>> rows,
) async {
  final path = join(dir.path, name);
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 9,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            imagePath TEXT NOT NULL,
            title TEXT NOT NULL,
            script TEXT NOT NULL,
            locationName TEXT,
            audioPath TEXT,
            status TEXT NOT NULL DEFAULT 'complete',
            ttsModel TEXT,
            aiModel TEXT,
            analyzedAt TEXT,
            analysisSource TEXT,
            gpsSource TEXT,
            wikipediaUsed INTEGER NOT NULL DEFAULT 0,
            wordCount INTEGER,
            analysisDurationMs INTEGER,
            gpsLatitude REAL,
            gpsLongitude REAL,
            gpsAddress TEXT,
            aiFallback INTEGER NOT NULL DEFAULT 0,
            ttsFallback INTEGER NOT NULL DEFAULT 0,
            isFavorite INTEGER NOT NULL DEFAULT 0,
            rotationQuarters INTEGER NOT NULL DEFAULT 0,
            scriptStyle TEXT,
            outputLanguage TEXT,
            promptVersion TEXT,
            createdAt TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE collections(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            createdAt TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE history_collections(
            historyId INTEGER NOT NULL,
            collectionId INTEGER NOT NULL,
            PRIMARY KEY (historyId, collectionId)
          )
        ''');
      },
    ),
  );
  for (final row in rows) {
    await db.insert('history', row);
  }
  await db.close();
  return path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('history_migration_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  for (final oldVersion in [1, 2, 3, 4, 5, 6]) {
    test('migrates cleanly from schema v$oldVersion to v11, keeping data (T09)', () async {
      final path = await _createOldSchemaDb(tempDir, oldVersion);

      final service = HistoryService();
      await service.init(dbPath: path);

      expect(service.entries, hasLength(1));
      final entry = service.entries.single;
      expect(entry.title, 'Entry from schema v$oldVersion');
      expect(entry.script, 'Some narration text.');
      expect(entry.locationName, 'Paris');
      // Columns added after this version should carry their defaults,
      // not null-crash or silently drop the row.
      expect(entry.status, AnalysisStatus.complete);
      expect(entry.aiFallback, isFalse);
      expect(entry.ttsFallback, isFalse);
      expect(entry.wikipediaUsed, isFalse);
      expect(entry.isFavorite, isFalse); // T51
      expect(entry.rotationQuarters, 0); // #152/#183
      expect(entry.scriptStyle, isNull); // #138
      expect(entry.outputLanguage, isNull); // #138
      expect(entry.promptVersion, isNull); // #138
      expect(service.collections, isEmpty); // T51

      final version = await databaseFactoryFfi.openDatabase(path).then((db) async {
        final v = await db.getVersion();
        await db.close();
        return v;
      });
      expect(version, 11);
    });
  }

  test('a fresh install (no prior db) creates schema v11 directly', () async {
    final path = join(tempDir.path, 'fresh.db');
    final service = HistoryService();
    await service.init(dbPath: path);

    expect(service.entries, isEmpty);
    expect(service.collections, isEmpty); // T51
    final version = await databaseFactoryFfi.openDatabase(path).then((db) async {
      final v = await db.getVersion();
      await db.close();
      return v;
    });
    expect(version, 11);
  });

  // #288
  group('v9 -> v10 repairs entries corrupted by the stale gemini_tts_output.wav bug', () {
    test('a native-tts entry with a wrongly-cached audioPath gets repaired', () async {
      final staleAudio = File(join(tempDir.path, 'stale_gemini_audio.wav'));
      await staleAudio.writeAsString('fake wav bytes');

      final path = await _createV9DbWithRows(tempDir, 'corrupted.db', [
        {
          'imagePath': '/tmp/photo.jpg',
          'title': 'Entrée en IA locale',
          'script': 'Un texte.',
          'ttsModel': 'native-tts',
          'audioPath': staleAudio.path,
          'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        },
      ]);

      final service = HistoryService();
      await service.init(dbPath: path);

      final entry = service.entries.single;
      expect(entry.ttsModel, 'native-tts');
      expect(entry.audioPath, isNull);
      expect(await staleAudio.exists(), isFalse,
          reason: 'the wrongly-copied file should be deleted, not just unlinked');
    });

    test('a legitimate gemini-tts entry with a real audioPath is left untouched', () async {
      final realAudio = File(join(tempDir.path, 'real_gemini_audio.wav'));
      await realAudio.writeAsString('fake wav bytes');

      final path = await _createV9DbWithRows(tempDir, 'legit.db', [
        {
          'imagePath': '/tmp/photo.jpg',
          'title': 'Entrée cloud',
          'script': 'Un texte.',
          'ttsModel': 'gemini-tts',
          'audioPath': realAudio.path,
          'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        },
      ]);

      final service = HistoryService();
      await service.init(dbPath: path);

      final entry = service.entries.single;
      expect(entry.ttsModel, 'gemini-tts');
      expect(entry.audioPath, realAudio.path);
      expect(await realAudio.exists(), isTrue);
    });

    test('a script-only entry (no ttsModel, no audioPath) is left untouched', () async {
      final path = await _createV9DbWithRows(tempDir, 'scriptonly.db', [
        {
          'imagePath': '/tmp/photo.jpg',
          'title': 'Script seul',
          'script': 'Un texte.',
          'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        },
      ]);

      final service = HistoryService();
      await service.init(dbPath: path);

      final entry = service.entries.single;
      expect(entry.ttsModel, isNull);
      expect(entry.audioPath, isNull);
    });
  });

  test('onUpgrade runs inside a single transaction: a mid-migration failure '
      'leaves the database untouched at the old version, not half-upgraded',
      () async {
    // Documents a real sqflite guarantee (verified by reading
    // sqflite_common's source, not assumed): openDatabase wraps the whole
    // onCreate/onUpgrade callback in one exclusive transaction, so a
    // failure partway through rolls back everything already executed in
    // that callback and never calls setVersion. Reproduced directly here
    // rather than against HistoryService, since forcing a failure in the
    // real migration would require invasive fault injection.
    final path = join(tempDir.path, 'rollback.db');
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, v) =>
            db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY, a TEXT)'),
      ),
    );
    await db.close();

    Future<Database> reopenAndUpgrade() => databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 2,
            onUpgrade: (db, oldV, newV) async {
              await db.execute('ALTER TABLE t ADD COLUMN b TEXT');
              throw Exception('simulated failure after the first ALTER');
            },
          ),
        );

    await expectLater(reopenAndUpgrade(), throwsException);

    final reopened = await databaseFactoryFfi.openDatabase(path);
    expect(await reopened.getVersion(), 1, reason: 'version must not bump on failure');
    final columns = await reopened.rawQuery('PRAGMA table_info(t)');
    expect(
      columns.map((c) => c['name']),
      isNot(contains('b')),
      reason: 'the ALTER from the failed migration must have been rolled back',
    );
    await reopened.close();
  });
}
