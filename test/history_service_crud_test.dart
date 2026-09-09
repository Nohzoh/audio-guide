import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:audiolens/constants/analysis_provenance.dart';
import 'package:audiolens/models/quiz_question.dart';
import 'package:audiolens/services/history_service.dart';

/// T68 — HistoryService's actual CRUD methods (as opposed to just
/// HistoryEntry's toMap/fromMap serialization, already covered by
/// history_entry_test.dart/history_serialization_test.dart) had no direct
/// test against a real database before this.
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmpDir;
  late String dbPath;
  late String sourceImagePath;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('history_crud_test');
    dbPath = join(tmpDir.path, 'history.db');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return tmpDir.path;
      return null;
    });
    sourceImagePath = join(tmpDir.path, 'source.jpg');
    File(sourceImagePath).writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    await tmpDir.delete(recursive: true);
  });

  test('addPendingEntry copies the source image and inserts a pending entry',
      () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);

    final entry = await service.addPendingEntry(imagePath: sourceImagePath);

    expect(entry.id, isNotNull);
    expect(entry.status, AnalysisStatus.pending);
    // Copied to permanent storage, not left pointing at the source.
    expect(entry.imagePath, isNot(sourceImagePath));
    expect(File(entry.imagePath).existsSync(), isTrue);
    expect(service.entries, hasLength(1));
    expect(service.entries.single.id, entry.id);
  });

  test('addCapturedEntry inserts a captured entry with raw GPS, no analysis yet',
      () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);

    final entry = await service.addCapturedEntry(
      imagePath: sourceImagePath,
      gpsLatitude: 48.86,
      gpsLongitude: 2.33,
      gpsSource: 'exif',
    );

    expect(entry.status, AnalysisStatus.captured);
    expect(entry.gpsLatitude, 48.86);
    expect(entry.gpsLongitude, 2.33);
    expect(entry.gpsSource, 'exif');
    expect(entry.script, isEmpty);
  });

  test('completeEntry transitions a pending entry to complete with the analysis result',
      () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);

    await service.completeEntry(
      entryId: pending.id!,
      title: 'La Joconde',
      script: 'Bienvenue devant ce chef-d\'oeuvre emblematique.',
      locationName: 'Paris',
      aiModel: 'gemini-3.5-flash',
      analysisSource: 'camera',
      gpsSource: 'exif',
      wikipediaUsed: true,
      analysisDurationMs: 1234,
      gpsLatitude: 48.86,
      gpsLongitude: 2.33,
      gpsAddress: 'Musee du Louvre',
      aiFallback: true,
      ttsFallback: false,
      scriptStyle: 'academic', // #138
      outputLanguage: 'English', // #138
    );

    final updated = service.entries.firstWhere((e) => e.id == pending.id);
    expect(updated.status, AnalysisStatus.complete);
    expect(updated.title, 'La Joconde');
    expect(updated.locationName, 'Paris');
    expect(updated.aiModel, 'gemini-3.5-flash');
    expect(updated.analysisSource, 'camera');
    expect(updated.wikipediaUsed, isTrue);
    expect(updated.analysisDurationMs, 1234);
    expect(updated.gpsLatitude, 48.86);
    expect(updated.gpsAddress, 'Musee du Louvre');
    expect(updated.aiFallback, isTrue);
    expect(updated.wordCount, greaterThan(0));
    // #138: scriptStyle/outputLanguage come from the caller, promptVersion
    // is stamped unconditionally from the current build's constant.
    expect(updated.scriptStyle, 'academic');
    expect(updated.outputLanguage, 'English');
    expect(updated.promptVersion, promptSchemaVersion);
  });

  test('completeEntry deletes a stale audio file from a previous run', () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);
    await service.completeEntry(entryId: pending.id!, title: 't1', script: 's1');

    final wavSource = join(tmpDir.path, 'audio_source.wav');
    File(wavSource).writeAsBytesSync([1, 2, 3, 4]);
    await service.saveAudioPath(pending.id!, wavSource, ttsModel: 'gemini-tts');
    final firstAudioPath = service.entries.firstWhere((e) => e.id == pending.id).audioPath!;
    expect(File(firstAudioPath).existsSync(), isTrue);

    // Re-completing (e.g. a retry) must not leave the previous audio file
    // orphaned on disk.
    await service.completeEntry(entryId: pending.id!, title: 't2', script: 's2');

    expect(File(firstAudioPath).existsSync(), isFalse);
    expect(service.entries.firstWhere((e) => e.id == pending.id).audioPath, isNull);
  });

  test('failEntry transitions a pending entry to failed', () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);

    await service.failEntry(pending.id!);

    final updated = service.entries.firstWhere((e) => e.id == pending.id);
    expect(updated.status, AnalysisStatus.failed);
  });

  test('failEntry persists the resolved GPS so a retry can reuse it', () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);

    await service.failEntry(
      pending.id!,
      gpsLatitude: 48.86,
      gpsLongitude: 2.33,
      gpsSource: 'map',
    );

    final updated = service.entries.firstWhere((e) => e.id == pending.id);
    expect(updated.status, AnalysisStatus.failed);
    expect(updated.gpsLatitude, 48.86);
    expect(updated.gpsLongitude, 2.33);
    expect(updated.gpsSource, 'map');

    // Reload from the DB (not just the in-memory list) to confirm the
    // columns were actually persisted, not only reflected in-memory.
    final reloaded = HistoryService();
    await reloaded.init(dbPath: dbPath);
    final reloadedEntry = reloaded.entries.firstWhere((e) => e.id == pending.id);
    expect(reloadedEntry.gpsLatitude, 48.86);
    expect(reloadedEntry.gpsLongitude, 2.33);
    expect(reloadedEntry.gpsSource, 'map');
  });

  test('failEntry without GPS args leaves gps fields null (no partial write)', () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);

    await service.failEntry(pending.id!);

    final updated = service.entries.firstWhere((e) => e.id == pending.id);
    expect(updated.gpsLatitude, isNull);
    expect(updated.gpsLongitude, isNull);
  });

  test('failOrphanedPendingEntries (T120) flips a leftover pending entry to failed',
      () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);

    final count = await service.failOrphanedPendingEntries();

    expect(count, 1);
    final updated = service.entries.firstWhere((e) => e.id == pending.id);
    expect(updated.status, AnalysisStatus.failed);
    expect(updated.title, 'Analyse échouée');
  });

  test('failOrphanedPendingEntries (T120) leaves captured and complete entries untouched',
      () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final captured = await service.addCapturedEntry(
      imagePath: sourceImagePath,
      gpsLatitude: 48.86,
      gpsLongitude: 2.33,
      gpsSource: 'exif',
    );
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);
    await service.completeEntry(
      entryId: pending.id!,
      title: 'La Joconde',
      script: 'Bienvenue.',
    );

    final count = await service.failOrphanedPendingEntries();

    expect(count, 0);
    final reloadedCaptured = service.entries.firstWhere((e) => e.id == captured.id);
    expect(reloadedCaptured.status, AnalysisStatus.captured);
    final reloadedComplete = service.entries.firstWhere((e) => e.id == pending.id);
    expect(reloadedComplete.status, AnalysisStatus.complete);
  });

  test('failOrphanedPendingEntries (T120) handles multiple orphaned entries in one call',
      () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final first = await service.addPendingEntry(imagePath: sourceImagePath);
    final second = await service.addPendingEntry(imagePath: sourceImagePath);

    final count = await service.failOrphanedPendingEntries();

    expect(count, 2);
    expect(service.entries.firstWhere((e) => e.id == first.id).status,
        AnalysisStatus.failed);
    expect(service.entries.firstWhere((e) => e.id == second.id).status,
        AnalysisStatus.failed);
  });

  test('saveAudioPath copies the WAV to permanent storage and records the tts model',
      () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);
    await service.completeEntry(entryId: pending.id!, title: 't', script: 's');

    final wavSource = join(tmpDir.path, 'audio_source.wav');
    File(wavSource).writeAsBytesSync([1, 2, 3, 4]);

    await service.saveAudioPath(pending.id!, wavSource, ttsModel: 'native-tts');

    final updated = service.entries.firstWhere((e) => e.id == pending.id);
    expect(updated.audioPath, isNotNull);
    expect(updated.audioPath, isNot(wavSource));
    expect(File(updated.audioPath!).existsSync(), isTrue);
    expect(updated.ttsModel, 'native-tts');
  });

  test('saveTtsModel records the tts model without touching audioPath (T93)', () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);
    await service.completeEntry(entryId: pending.id!, title: 't', script: 's');

    await service.saveTtsModel(pending.id!, 'native-tts', ttsFallback: true);

    final updated = service.entries.firstWhere((e) => e.id == pending.id);
    expect(updated.ttsModel, 'native-tts');
    expect(updated.ttsFallback, isTrue);
    expect(updated.audioPath, isNull);
    expect(updated.hasAudio, isFalse);

    // Reload from the DB to confirm it was actually persisted, not just
    // reflected in-memory.
    final reloaded = HistoryService();
    await reloaded.init(dbPath: dbPath);
    final reloadedEntry = reloaded.entries.firstWhere((e) => e.id == pending.id);
    expect(reloadedEntry.ttsModel, 'native-tts');
    expect(reloadedEntry.ttsFallback, isTrue);
  });

  test('deleteEntry removes the entry from the list/db and deletes its image file',
      () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);
    final imagePath = pending.imagePath;
    expect(File(imagePath).existsSync(), isTrue);

    await service.deleteEntry(pending.id!);

    expect(service.entries, isEmpty);
    expect(File(imagePath).existsSync(), isFalse);

    // Reloading from disk must also reflect the deletion, not just the
    // in-memory list.
    final reloaded = HistoryService();
    await reloaded.init(dbPath: dbPath);
    expect(reloaded.entries, isEmpty);
  });

  test('deleteEntry also deletes the audio file when one was generated', () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final pending = await service.addPendingEntry(imagePath: sourceImagePath);
    await service.completeEntry(entryId: pending.id!, title: 't', script: 's');
    final wavSource = join(tmpDir.path, 'audio_source.wav');
    File(wavSource).writeAsBytesSync([1, 2, 3, 4]);
    await service.saveAudioPath(pending.id!, wavSource, ttsModel: 'gemini-tts');
    final audioPath = service.entries.firstWhere((e) => e.id == pending.id).audioPath!;

    await service.deleteEntry(pending.id!);

    expect(File(audioPath).existsSync(), isFalse);
  });

  // #373 (follow-up): cached quiz questions let a later quiz round on the
  // same entry reuse a batch call's leftovers instead of spending another
  // API call.
  group('quiz question cache', () {
    QuizQuestion quizQ(String question) => QuizQuestion(
          question: question,
          correctAnswer: 'A',
          wrongAnswers: const ['B', 'C', 'D'],
        );

    test('takeCachedQuizQuestion returns null when nothing is cached',
        () async {
      final service = HistoryService();
      await service.init(dbPath: dbPath);
      final entry = await service.addPendingEntry(imagePath: sourceImagePath);
      await service.completeEntry(entryId: entry.id!, title: 't', script: 's');

      expect(await service.takeCachedQuizQuestion(entry.id!), isNull);
    });

    test('caches a batch, then takes questions oldest-first until empty',
        () async {
      final service = HistoryService();
      await service.init(dbPath: dbPath);
      final entry = await service.addPendingEntry(imagePath: sourceImagePath);
      await service.completeEntry(entryId: entry.id!, title: 't', script: 's');

      await service.cacheQuizQuestions(entry.id!, [quizQ('Q1'), quizQ('Q2')]);

      final first = await service.takeCachedQuizQuestion(entry.id!);
      expect(first?.question, 'Q1');
      final second = await service.takeCachedQuizQuestion(entry.id!);
      expect(second?.question, 'Q2');
      // Consumed — nothing left for a third round.
      expect(await service.takeCachedQuizQuestion(entry.id!), isNull);
    });

    test('completeEntry (a regenerate) invalidates previously cached '
        'questions for that entry', () async {
      final service = HistoryService();
      await service.init(dbPath: dbPath);
      final entry = await service.addPendingEntry(imagePath: sourceImagePath);
      await service.completeEntry(entryId: entry.id!, title: 't', script: 's');
      await service.cacheQuizQuestions(entry.id!, [quizQ('Stale, about the old script')]);

      // Regenerate — same entryId, new script.
      await service.completeEntry(entryId: entry.id!, title: 't2', script: 's2');

      expect(await service.takeCachedQuizQuestion(entry.id!), isNull);
    });

    test('deleteEntry removes any cached questions for that entry', () async {
      final service = HistoryService();
      await service.init(dbPath: dbPath);
      final entry = await service.addPendingEntry(imagePath: sourceImagePath);
      await service.completeEntry(entryId: entry.id!, title: 't', script: 's');
      await service.cacheQuizQuestions(entry.id!, [quizQ('Q1')]);

      await service.deleteEntry(entry.id!);

      // A fresh instance so a leftover in-memory list can't mask an
      // orphaned row still sitting in the db.
      final reloaded = HistoryService();
      await reloaded.init(dbPath: dbPath);
      expect(await reloaded.takeCachedQuizQuestion(entry.id!), isNull);
    });
  });

  test('addPendingEntry never collides two entries created in the same '
      'millisecond (T104)', () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final secondSource = join(tmpDir.path, 'second.jpg');
    File(secondSource).writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);

    // No delay between the two calls — this is the exact scenario that
    // used to alias one entry's photo to the other's when the
    // destination filename was a bare millisecond timestamp.
    final results = await Future.wait([
      service.addPendingEntry(imagePath: sourceImagePath),
      service.addPendingEntry(imagePath: secondSource),
    ]);

    expect(results[0].imagePath, isNot(results[1].imagePath));
    expect(File(results[0].imagePath).existsSync(), isTrue);
    expect(File(results[1].imagePath).existsSync(), isTrue);
  });

  test('purgeEntriesOlderThan deletes only entries past the cutoff (T95)',
      () async {
    final service = HistoryService();
    await service.init(dbPath: dbPath);
    final oldEntry = await service.addPendingEntry(imagePath: sourceImagePath);
    final recentSource = join(tmpDir.path, 'recent.jpg');
    File(recentSource).writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
    final recentEntry = await service.addPendingEntry(imagePath: recentSource);

    // addPendingEntry always stamps createdAt as DateTime.now() — reach
    // into the DB directly to backdate one entry, the only way to
    // exercise the cutoff without adding test-only production API.
    final raw = await databaseFactory.openDatabase(dbPath);
    await raw.update(
      'history',
      {'createdAt': DateTime.now().subtract(const Duration(days: 40)).toIso8601String()},
      where: 'id = ?',
      whereArgs: [oldEntry.id],
    );
    await raw.close();

    final reloaded = HistoryService();
    await reloaded.init(dbPath: dbPath);
    final oldImagePath = reloaded.entries.firstWhere((e) => e.id == oldEntry.id).imagePath;

    await reloaded.purgeEntriesOlderThan(30);

    expect(reloaded.entries.map((e) => e.id), [recentEntry.id]);
    expect(File(oldImagePath).existsSync(), isFalse);
    expect(File(recentEntry.imagePath).existsSync(), isTrue);
  });
}
