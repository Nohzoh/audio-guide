import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../constants/analysis_provenance.dart';
import '../models/guide_error.dart';
import '../models/quiz_question.dart';

/// Thrown when copying a photo or audio file to permanent storage fails
/// (T116) — most commonly because the device is out of storage. Callers
/// should catch this and localize [kind]/[detail] via
/// `localizeHistoryStorageException` (#230) instead of letting a raw I/O
/// exception surface.
class HistoryStorageException implements Exception {
  final GuideErrorKind kind;
  final String? detail;
  const HistoryStorageException(this.kind, [this.detail]);
  @override
  String toString() => detail == null ? kind.name : '${kind.name}: $detail';
}

/// ENOSPC ("no space left on device") on Linux/Android.
const _enospc = 28;

Future<void> _copyFileOrThrowStorageError(File source, String destPath) async {
  try {
    await source.copy(destPath);
  } on FileSystemException catch (e) {
    if (e.osError?.errorCode == _enospc) {
      throw const HistoryStorageException(GuideErrorKind.storageDiskFull);
    }
    throw HistoryStorageException(
        GuideErrorKind.storageWriteFailed, e.osError?.message ?? e.message);
  }
}

enum AnalysisStatus {
  complete,
  pending,
  failed,

  /// Photo + raw GPS captured, analysis not started yet (T78) — distinct
  /// from [pending], which means an analysis is currently in progress.
  captured,
}

class HistoryEntry {
  final int? id;
  final String imagePath;
  final String title;
  final String script;
  final String? locationName;
  final String? audioPath;
  final DateTime createdAt;
  final AnalysisStatus status;
  final String? ttsModel; // e.g. "gemini-tts", "native-tts" (was "piper" before T89)
  final String? aiModel; // e.g. "gemini-3.5-flash", "gemini-nano"
  final DateTime? analyzedAt;
  final String? analysisSource; // "camera", "gallery", "retry"
  final String? gpsSource; // "realtime", "exif", "none"
  final bool wikipediaUsed;
  final int? wordCount;
  final int? analysisDurationMs;
  final double? gpsLatitude;
  final double? gpsLongitude;
  final String? gpsAddress;
  final bool aiFallback; // a fallback model was used for the analysis
  final bool ttsFallback; // Gemini TTS failed → fell back to the native engine
  final bool isFavorite; // T51

  /// #138: the settings this specific analysis was generated with — null
  /// for entries predating this field. Independent of the *current*
  /// Settings value, which may have changed since.
  final String? scriptStyle;
  final String? outputLanguage;

  /// #138: `promptSchemaVersion` at the time this entry was generated —
  /// see its doc comment for what "version" means here.
  final String? promptVersion;

  /// User-applied display rotation, in quarter turns clockwise (0-3).
  ///
  /// Stored rather than baked into the file: the image on disk is also
  /// what EXIF GPS extraction reads, so rewriting its pixels to rotate it
  /// would mean re-preserving that metadata on every rotation and risking
  /// the user's original photo on a failure. Applied at display time
  /// instead.
  final int rotationQuarters;

  const HistoryEntry({
    this.id,
    required this.imagePath,
    required this.title,
    required this.script,
    this.locationName,
    this.audioPath,
    required this.createdAt,
    this.status = AnalysisStatus.complete,
    this.ttsModel,
    this.aiModel,
    this.analyzedAt,
    this.analysisSource,
    this.gpsSource,
    this.wikipediaUsed = false,
    this.wordCount,
    this.analysisDurationMs,
    this.gpsLatitude,
    this.gpsLongitude,
    this.gpsAddress,
    this.aiFallback = false,
    this.ttsFallback = false,
    this.isFavorite = false,
    this.rotationQuarters = 0,
    this.scriptStyle,
    this.outputLanguage,
    this.promptVersion,
  });

  bool get hasAudio => audioPath != null && File(audioPath!).existsSync();
  bool get isPending => status == AnalysisStatus.pending;
  bool get isCaptured => status == AnalysisStatus.captured;
  // True for two distinct "can be upgraded to a better voice" cases (T133):
  // the legacy "piper" engine (pre-T89, cached audioPath) — and the
  // current native-TTS fallback (Gemini TTS failed at analysis time,
  // ttsFallback records that; native TTS never caches a file, so
  // audioPath is always null for this case).
  bool get hasLowQualityTts =>
      (ttsModel == "piper" && audioPath != null) ||
      (ttsModel == "native-tts" && ttsFallback);
  String get audioDurationEstimate {
    if (wordCount == null) return '';
    final seconds = (wordCount! / 2.5).round(); // ~150 words/min
    if (seconds < 60) return '~${seconds}s';
    return '~${seconds ~/ 60}min${seconds % 60 > 0 ? " ${seconds % 60}s" : ""}';
  }

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'imagePath': imagePath,
    'title': title,
    'script': script,
    'locationName': locationName,
    'audioPath': audioPath,
    'createdAt': createdAt.toIso8601String(),
    'status': status.name,
    'ttsModel': ttsModel,
    'aiModel': aiModel,
    'analyzedAt': analyzedAt?.toIso8601String(),
    'analysisSource': analysisSource,
    'gpsSource': gpsSource,
    'wikipediaUsed': wikipediaUsed ? 1 : 0,
    'wordCount': wordCount,
    'analysisDurationMs': analysisDurationMs,
    'gpsLatitude': gpsLatitude,
    'gpsLongitude': gpsLongitude,
    'gpsAddress': gpsAddress,
    'aiFallback': aiFallback ? 1 : 0,
    'ttsFallback': ttsFallback ? 1 : 0,
    'isFavorite': isFavorite ? 1 : 0,
    'rotationQuarters': rotationQuarters,
    'scriptStyle': scriptStyle,
    'outputLanguage': outputLanguage,
    'promptVersion': promptVersion,
  };

  factory HistoryEntry.fromMap(Map<String, dynamic> map) => HistoryEntry(
    id: map['id'] as int?,
    imagePath: map['imagePath'] as String,
    title: map['title'] as String,
    script: map['script'] as String,
    locationName: map['locationName'] as String?,
    audioPath: map['audioPath'] as String?,
    createdAt: DateTime.parse(map['createdAt'] as String),
    ttsModel: map['ttsModel'] as String?,
    aiModel: map['aiModel'] as String?,
    analyzedAt: map['analyzedAt'] != null ? DateTime.parse(map['analyzedAt'] as String) : null,
    analysisSource: map['analysisSource'] as String?,
    gpsSource: map['gpsSource'] as String?,
    wikipediaUsed: (map['wikipediaUsed'] as int? ?? 0) == 1,
    wordCount: map['wordCount'] as int?,
    analysisDurationMs: map['analysisDurationMs'] as int?,
    gpsLatitude: map['gpsLatitude'] as double?,
    gpsLongitude: map['gpsLongitude'] as double?,
    gpsAddress: map['gpsAddress'] as String?,
    aiFallback: (map['aiFallback'] as int? ?? 0) == 1,
    ttsFallback: (map['ttsFallback'] as int? ?? 0) == 1,
    isFavorite: (map['isFavorite'] as int? ?? 0) == 1,
    rotationQuarters: map['rotationQuarters'] as int? ?? 0,
    scriptStyle: map['scriptStyle'] as String?,
    outputLanguage: map['outputLanguage'] as String?,
    promptVersion: map['promptVersion'] as String?,
    status: AnalysisStatus.values.firstWhere(
      (s) => s.name == (map['status'] as String? ?? 'complete'),
      orElse: () => AnalysisStatus.complete,
    ),
  );

  HistoryEntry copyWith({
    String? audioPath,
    AnalysisStatus? status,
    String? ttsModel,
    String? aiModel,
    String? title,
    String? script,
    String? locationName,
    DateTime? analyzedAt,
    String? analysisSource,
    String? gpsSource,
    bool? wikipediaUsed,
    int? wordCount,
    int? analysisDurationMs,
    double? gpsLatitude,
    double? gpsLongitude,
    String? gpsAddress,
    bool? aiFallback,
    bool? ttsFallback,
    bool? isFavorite,
    int? rotationQuarters,
    String? scriptStyle,
    String? outputLanguage,
    String? promptVersion,
  }) => HistoryEntry(
    id: id,
    imagePath: imagePath,
    title: title ?? this.title,
    script: script ?? this.script,
    locationName: locationName ?? this.locationName,
    audioPath: audioPath ?? this.audioPath,
    createdAt: createdAt,
    status: status ?? this.status,
    ttsModel: ttsModel ?? this.ttsModel,
    aiModel: aiModel ?? this.aiModel,
    analyzedAt: analyzedAt ?? this.analyzedAt,
    analysisSource: analysisSource ?? this.analysisSource,
    gpsSource: gpsSource ?? this.gpsSource,
    wikipediaUsed: wikipediaUsed ?? this.wikipediaUsed,
    wordCount: wordCount ?? this.wordCount,
    analysisDurationMs: analysisDurationMs ?? this.analysisDurationMs,
    gpsLatitude: gpsLatitude ?? this.gpsLatitude,
    gpsLongitude: gpsLongitude ?? this.gpsLongitude,
    gpsAddress: gpsAddress ?? this.gpsAddress,
    aiFallback: aiFallback ?? this.aiFallback,
    ttsFallback: ttsFallback ?? this.ttsFallback,
    isFavorite: isFavorite ?? this.isFavorite,
    rotationQuarters: rotationQuarters ?? this.rotationQuarters,
    scriptStyle: scriptStyle ?? this.scriptStyle,
    outputLanguage: outputLanguage ?? this.outputLanguage,
    promptVersion: promptVersion ?? this.promptVersion,
  );
}

/// A named group of history entries (T51), e.g. "Louvre" or "Rome trip" —
/// many-to-many via the `history_collections` join table, so one entry can
/// belong to several collections.
class Collection {
  final int? id;
  final String name;
  final DateTime createdAt;

  const Collection({this.id, required this.name, required this.createdAt});

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
  };

  factory Collection.fromMap(Map<String, dynamic> map) => Collection(
    id: map['id'] as int?,
    name: map['name'] as String,
    createdAt: DateTime.parse(map['createdAt'] as String),
  );
}

class HistoryService extends ChangeNotifier {
  Database? _db;
  List<HistoryEntry> _entries = [];
  List<Collection> _collections = [];
  Map<int, Set<int>> _entryCollectionIds = {};

  List<HistoryEntry> get entries => _entries;
  List<Collection> get collections => _collections;
  Set<int> collectionIdsForEntry(int entryId) =>
      _entryCollectionIds[entryId] ?? const {};

  /// [dbPath] allows pointing at an isolated database file in tests
  /// instead of the app's real one.
  Future<void> init({String? dbPath}) async {
    final path = dbPath ?? join(await getDatabasesPath(), 'audio_guide_history.db');
    _db = await openDatabase(
      path,
      version: 11,
      onCreate: (db, version) async {
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
        await db.execute(_createCollectionsTableSql);
        await db.execute(_createHistoryCollectionsTableSql);
        await db.execute(_createQuizQuestionsTableSql);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE history ADD COLUMN audioPath TEXT');
        }
        if (oldVersion < 3) {
          await db.execute("ALTER TABLE history ADD COLUMN status TEXT NOT NULL DEFAULT 'complete'");
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE history ADD COLUMN ttsModel TEXT');
        }
        if (oldVersion < 5) {
          for (final col in [
            'ALTER TABLE history ADD COLUMN aiModel TEXT',
            'ALTER TABLE history ADD COLUMN analyzedAt TEXT',
            'ALTER TABLE history ADD COLUMN analysisSource TEXT',
            'ALTER TABLE history ADD COLUMN gpsSource TEXT',
            "ALTER TABLE history ADD COLUMN wikipediaUsed INTEGER NOT NULL DEFAULT 0",
            'ALTER TABLE history ADD COLUMN wordCount INTEGER',
            'ALTER TABLE history ADD COLUMN analysisDurationMs INTEGER',
            'ALTER TABLE history ADD COLUMN gpsLatitude REAL',
            'ALTER TABLE history ADD COLUMN gpsLongitude REAL',
            'ALTER TABLE history ADD COLUMN gpsAddress TEXT',
          ]) {
            await db.execute(col);
          }
        }
        if (oldVersion < 6) {
          await db.execute('ALTER TABLE history ADD COLUMN aiFallback INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE history ADD COLUMN ttsFallback INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 7) {
          await db.execute('ALTER TABLE history ADD COLUMN isFavorite INTEGER NOT NULL DEFAULT 0');
          await db.execute(_createCollectionsTableSql);
          await db.execute(_createHistoryCollectionsTableSql);
        }
        if (oldVersion < 8) {
          await db.execute('ALTER TABLE history ADD COLUMN rotationQuarters INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 9) {
          // #138 — null for every pre-existing entry, same as every other
          // provenance field added by a prior migration.
          await db.execute('ALTER TABLE history ADD COLUMN scriptStyle TEXT');
          await db.execute('ALTER TABLE history ADD COLUMN outputLanguage TEXT');
          await db.execute('ALTER TABLE history ADD COLUMN promptVersion TEXT');
        }
        if (oldVersion < 10) {
          // #288: AudioGuideService._synthesizeAndPlay used to cache
          // _lastAudioPath unconditionally after every synthesis, by
          // checking whether the single shared gemini_tts_output.wav file
          // happened to exist on disk — not whether *this* synthesis
          // actually wrote it. When native TTS ran (e.g. after switching
          // to local AI) right after an earlier Gemini TTS call had left
          // that file behind, the stale cloud file got wrongly copied in
          // as the new entry's own cached audio. Detectable precisely
          // because `ttsModel` still correctly says 'native-tts' (that's
          // what actually spoke) while `audioPath` points at a real file —
          // a combination that should never legitimately occur, since
          // native TTS never produces a cacheable file at all. The code
          // fix alone only stops new entries from getting corrupted this
          // way; this repairs whatever's already sitting in an existing
          // history.
          final corrupted = await db.query(
            'history',
            columns: ['id', 'audioPath'],
            where: "ttsModel = 'native-tts' AND audioPath IS NOT NULL",
          );
          for (final row in corrupted) {
            final path = row['audioPath'] as String?;
            if (path != null) {
              try {
                await File(path).delete();
              } catch (_) {}
            }
          }
          await db.update(
            'history',
            {'audioPath': null},
            where: "ttsModel = 'native-tts' AND audioPath IS NOT NULL",
          );
        }
        if (oldVersion < 11) {
          // #373 (follow-up): batch-generated quiz questions cached for
          // reuse — see takeCachedQuizQuestion/cacheQuizQuestions below.
          await db.execute(_createQuizQuestionsTableSql);
        }
      },
    );
    await _loadEntries();
    await _loadCollectionsAndMemberships();
  }

  static const _createCollectionsTableSql = '''
    CREATE TABLE collections(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      createdAt TEXT NOT NULL
    )
  ''';

  static const _createHistoryCollectionsTableSql = '''
    CREATE TABLE history_collections(
      historyId INTEGER NOT NULL,
      collectionId INTEGER NOT NULL,
      PRIMARY KEY (historyId, collectionId)
    )
  ''';

  // #373 (follow-up): a batch call to GeminiApiService.generateQuizQuestions
  // can return more than one usable question — only the first is asked
  // immediately, the rest are stored here so a later quiz round landing on
  // the same entry can reuse them instead of spending another API call.
  // Rows are consumed (deleted) as they're taken, so this table only ever
  // holds not-yet-asked leftovers, never a history of what was asked.
  static const _createQuizQuestionsTableSql = '''
    CREATE TABLE quiz_questions(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      historyId INTEGER NOT NULL,
      question TEXT NOT NULL,
      correctAnswer TEXT NOT NULL,
      wrongAnswers TEXT NOT NULL,
      createdAt TEXT NOT NULL
    )
  ''';

  Future<void> _loadEntries() async {
    final maps = await _db!.query('history', orderBy: 'createdAt DESC');
    _entries = maps.map(HistoryEntry.fromMap).toList();
    notifyListeners();
  }

  Future<void> _loadCollectionsAndMemberships() async {
    final collectionMaps = await _db!.query('collections', orderBy: 'createdAt ASC');
    _collections = collectionMaps.map(Collection.fromMap).toList();

    final joinRows = await _db!.query('history_collections');
    _entryCollectionIds = {};
    for (final row in joinRows) {
      final historyId = row['historyId'] as int;
      final collectionId = row['collectionId'] as int;
      (_entryCollectionIds[historyId] ??= <int>{}).add(collectionId);
    }
    notifyListeners();
  }

  /// Add a pending entry immediately when photo is taken
  /// so it appears in gallery even before analysis completes
  Future<HistoryEntry> addPendingEntry({required String imagePath}) async {
    final permanentPath = await _copyImageToPermanentStorage(imagePath);
    final entry = HistoryEntry(
      imagePath: permanentPath,
      title: 'Analyse en attente...',
      script: '',
      createdAt: DateTime.now(),
      status: AnalysisStatus.pending,
    );
    final id = await _db!.insert('history', entry.toMap());
    final withId = HistoryEntry(
      id: id,
      imagePath: permanentPath,
      title: 'Analyse en attente...',
      script: '',
      createdAt: entry.createdAt,
      status: AnalysisStatus.pending,
    );
    _entries.insert(0, withId);
    notifyListeners();
    return withId;
  }

  /// Add a captured entry: photo + raw GPS saved, no analysis run yet
  /// (T78 — deferred capture, e.g. to save data until back on wifi).
  /// [gpsLatitude]/[gpsLongitude] are the raw coordinates only — no
  /// reverse geocoding/Wikipedia/AI has run, so there's no address or
  /// city yet; those are resolved when the analysis is later launched.
  Future<HistoryEntry> addCapturedEntry({
    required String imagePath,
    double? gpsLatitude,
    double? gpsLongitude,
    String? gpsSource,
  }) async {
    final permanentPath = await _copyImageToPermanentStorage(imagePath);
    final entry = HistoryEntry(
      imagePath: permanentPath,
      title: 'Capturé — analyse à lancer',
      script: '',
      createdAt: DateTime.now(),
      status: AnalysisStatus.captured,
      gpsLatitude: gpsLatitude,
      gpsLongitude: gpsLongitude,
      gpsSource: gpsSource,
    );
    final id = await _db!.insert('history', entry.toMap());
    final withId = HistoryEntry(
      id: id,
      imagePath: permanentPath,
      title: entry.title,
      script: '',
      createdAt: entry.createdAt,
      status: AnalysisStatus.captured,
      gpsLatitude: gpsLatitude,
      gpsLongitude: gpsLongitude,
      gpsSource: gpsSource,
    );
    _entries.insert(0, withId);
    notifyListeners();
    return withId;
  }

  /// Update a pending entry with completed analysis result
  Future<void> completeEntry({
    required int entryId,
    required String title,
    required String script,
    String? locationName,
    String? aiModel,
    String? analysisSource,
    String? gpsSource,
    bool wikipediaUsed = false,
    int? analysisDurationMs,
    double? gpsLatitude,
    double? gpsLongitude,
    String? gpsAddress,
    bool aiFallback = false,
    bool ttsFallback = false,
    // #138: the settings actually used for this analysis — record what
    // was used at generation time, independent of whatever Settings holds
    // by the time someone looks at the entry later.
    String? scriptStyle,
    String? outputLanguage,
  }) async {
    // Delete stale audio file if it exists
    final existing = _entries.firstWhere((e) => e.id == entryId,
        orElse: () => HistoryEntry(id: entryId, imagePath: '', title: '',
            script: '', createdAt: DateTime.now()));
    if (existing.audioPath != null) {
      try { await File(existing.audioPath!).delete(); } catch (_) {}
    }
    // #373 (follow-up): this entry's script is about to change (first
    // analysis or a regenerate) — any quiz questions cached against the
    // old script would be stale, so clear them rather than risk asking
    // about a fact the new script no longer contains.
    await _db!.delete('quiz_questions', where: 'historyId = ?', whereArgs: [entryId]);

    await _db!.update(
      'history',
      {
        'title': title,
        'script': script,
        'locationName': locationName,
        'status': AnalysisStatus.complete.name,
        'audioPath': null,
        'ttsModel': null,
        'aiModel': aiModel,
        'analyzedAt': DateTime.now().toIso8601String(),
        'analysisSource': analysisSource,
        'gpsSource': gpsSource,
        'wikipediaUsed': wikipediaUsed ? 1 : 0,
        'wordCount': script.trim().split(RegExp(r'\s+')).length,
        'analysisDurationMs': analysisDurationMs,
        'gpsLatitude': gpsLatitude,
        'gpsLongitude': gpsLongitude,
        'gpsAddress': gpsAddress,
        'aiFallback': aiFallback ? 1 : 0,
        'ttsFallback': ttsFallback ? 1 : 0,
        'scriptStyle': scriptStyle,
        'outputLanguage': outputLanguage,
        'promptVersion': promptSchemaVersion,
      },
      where: 'id = ?',
      whereArgs: [entryId],
    );
    final idx = _entries.indexWhere((e) => e.id == entryId);
    if (idx != -1) {
      _entries[idx] = HistoryEntry(
        id: entryId,
        imagePath: _entries[idx].imagePath,
        title: title,
        script: script,
        locationName: locationName,
        audioPath: null, // cleared — will regenerate on next listen
        createdAt: _entries[idx].createdAt,
        status: AnalysisStatus.complete,
        aiModel: aiModel,
        analyzedAt: DateTime.now(),
        analysisSource: analysisSource,
        gpsSource: gpsSource,
        wikipediaUsed: wikipediaUsed,
        wordCount: script.trim().split(RegExp(r'\s+')).length,
        analysisDurationMs: analysisDurationMs,
        gpsLatitude: gpsLatitude,
        gpsLongitude: gpsLongitude,
        gpsAddress: gpsAddress,
        aiFallback: aiFallback,
        ttsFallback: ttsFallback,
        isFavorite: _entries[idx].isFavorite,
        rotationQuarters: _entries[idx].rotationQuarters,
        scriptStyle: scriptStyle,
        outputLanguage: outputLanguage,
        promptVersion: promptSchemaVersion,
      );
      notifyListeners();
    }
  }

  /// T120: any entry still [AnalysisStatus.pending] when the app starts is
  /// guaranteed orphaned — [init] runs once at process start, before any
  /// analysis can possibly be in flight, so a pending entry at this point
  /// can only be a leftover from a process that died mid-analysis (OS
  /// kill, crash, forced update). Flips it to [AnalysisStatus.failed] so
  /// it surfaces with the existing, already-discoverable "tap to retry"
  /// UI instead of showing a perpetual, indistinguishable-from-active
  /// spinner. Returns the number of entries recovered this way.
  Future<int> failOrphanedPendingEntries() async {
    final orphaned =
        _entries.where((e) => e.status == AnalysisStatus.pending).toList();
    for (final entry in orphaned) {
      await failEntry(
        entry.id!,
        gpsLatitude: entry.gpsLatitude,
        gpsLongitude: entry.gpsLongitude,
        gpsSource: entry.gpsSource,
      );
    }
    return orphaned.length;
  }

  /// Mark a pending entry as failed. [gpsLatitude]/[gpsLongitude]/[gpsSource]
  /// persist whatever location was actually resolved for this attempt
  /// (live GPS, EXIF, or a manually picked map point) so a later retry can
  /// reuse it instead of re-resolving the device's current location from
  /// scratch — same rationale as [addCapturedEntry] (T78), for the case
  /// where the location was known but the analysis itself failed.
  Future<void> failEntry(
    int entryId, {
    double? gpsLatitude,
    double? gpsLongitude,
    String? gpsSource,
  }) async {
    await _db!.update(
      'history',
      {
        'status': AnalysisStatus.failed.name,
        'title': 'Analyse échouée',
        if (gpsLatitude != null) 'gpsLatitude': gpsLatitude,
        if (gpsLongitude != null) 'gpsLongitude': gpsLongitude,
        if (gpsSource != null) 'gpsSource': gpsSource,
      },
      where: 'id = ?',
      whereArgs: [entryId],
    );
    final idx = _entries.indexWhere((e) => e.id == entryId);
    if (idx != -1) {
      _entries[idx] = _entries[idx].copyWith(
        status: AnalysisStatus.failed,
        title: 'Analyse échouée',
        gpsLatitude: gpsLatitude,
        gpsLongitude: gpsLongitude,
        gpsSource: gpsSource,
      );
      notifyListeners();
    }
  }

  Future<HistoryEntry> addEntry({
    required String imagePath,
    required String title,
    required String script,
    String? locationName,
  }) async {
    final permanentPath = await _copyImageToPermanentStorage(imagePath);

    final entry = HistoryEntry(
      imagePath: permanentPath,
      title: title,
      script: script,
      locationName: locationName,
      createdAt: DateTime.now(),
    );

    final id = await _db!.insert('history', entry.toMap());
    final saved = HistoryEntry(
      id: id,
      imagePath: permanentPath,
      title: title,
      script: script,
      locationName: locationName,
      createdAt: entry.createdAt,
    );

    _entries.insert(0, saved);
    notifyListeners();
    return saved;
  }

  /// Save generated audio file path for an entry
  Future<void> saveAudioPath(int entryId, String sourcePath, {String? ttsModel, bool? ttsFallback}) async {
    // Copy WAV to permanent storage
    final dir = await getApplicationDocumentsDirectory();
    final audioDir = Directory('${dir.path}/history_audio');
    if (!await audioDir.exists()) await audioDir.create();

    final fileName = 'audio_$entryId.wav';
    final destPath = '${audioDir.path}/$fileName';
    await _copyFileOrThrowStorageError(File(sourcePath), destPath);

    // Update DB
    await _db!.update(
      'history',
      {
        'audioPath': destPath,
        if (ttsModel != null) 'ttsModel': ttsModel,
        if (ttsFallback != null) 'ttsFallback': ttsFallback ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [entryId],
    );

    // Update in-memory
    final idx = _entries.indexWhere((e) => e.id == entryId);
    if (idx != -1) {
      _entries[idx] = _entries[idx]
          .copyWith(audioPath: destPath, ttsModel: ttsModel, ttsFallback: ttsFallback);
      notifyListeners();
    }
  }

  /// Persists which TTS engine spoke an entry's script when there's no
  /// audio file to go with it (T93) — the native engine speaks live and
  /// never produces a file to cache (see [HistoryEntry.hasLowQualityTts]'s
  /// doc), so [saveAudioPath] — which requires a real file to copy — never
  /// runs for it, leaving `ttsModel` unset ("Inconnu" in the UI) otherwise.
  Future<void> saveTtsModel(int entryId, String ttsModel, {bool? ttsFallback}) async {
    await _db!.update(
      'history',
      {
        'ttsModel': ttsModel,
        if (ttsFallback != null) 'ttsFallback': ttsFallback ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [entryId],
    );
    final idx = _entries.indexWhere((e) => e.id == entryId);
    if (idx != -1) {
      _entries[idx] = _entries[idx].copyWith(ttsModel: ttsModel, ttsFallback: ttsFallback);
      notifyListeners();
    }
  }

  Future<void> deleteEntry(int id) async {
    final entry = _entries.firstWhere((e) => e.id == id);
    try {
      if (await File(entry.imagePath).exists()) {
        await File(entry.imagePath).delete();
      }
      if (entry.audioPath != null && await File(entry.audioPath!).exists()) {
        await File(entry.audioPath!).delete();
      }
    } catch (_) {}

    await _db!.delete('history', where: 'id = ?', whereArgs: [id]);
    await _db!.delete('history_collections', where: 'historyId = ?', whereArgs: [id]);
    await _db!.delete('quiz_questions', where: 'historyId = ?', whereArgs: [id]);
    _entries.removeWhere((e) => e.id == id);
    _entryCollectionIds.remove(id);
    notifyListeners();
  }

  /// #373 (follow-up): pops one previously-generated, not-yet-asked quiz
  /// question cached for [historyId] (oldest first), or null if none are
  /// cached — the caller (QuizScreen) then falls back to a fresh batch
  /// call. The row is deleted as it's taken, so a cached question is only
  /// ever asked once.
  Future<QuizQuestion?> takeCachedQuizQuestion(int historyId) async {
    final rows = await _db!.query(
      'quiz_questions',
      where: 'historyId = ?',
      whereArgs: [historyId],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    await _db!.delete('quiz_questions', where: 'id = ?', whereArgs: [row['id']]);
    return QuizQuestion(
      question: row['question'] as String,
      correctAnswer: row['correctAnswer'] as String,
      wrongAnswers:
          (jsonDecode(row['wrongAnswers'] as String) as List).cast<String>(),
    );
  }

  /// #373 (follow-up): stores [questions] — typically a batch call's
  /// leftovers once one has already been used for the current round — so
  /// a later quiz round landing on the same entry can reuse them via
  /// [takeCachedQuizQuestion] instead of spending another API call.
  /// Invalidated by [completeEntry] (script changed) and [deleteEntry].
  Future<void> cacheQuizQuestions(int historyId, List<QuizQuestion> questions) async {
    if (questions.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    final batch = _db!.batch();
    for (final q in questions) {
      batch.insert('quiz_questions', {
        'historyId': historyId,
        'question': q.question,
        'correctAnswer': q.correctAnswer,
        'wrongAnswers': jsonEncode(q.wrongAnswers),
        'createdAt': now,
      });
    }
    await batch.commit(noResult: true);
  }

  /// T51: toggles a single entry's favorite flag.
  Future<void> toggleFavorite(int entryId) async {
    final idx = _entries.indexWhere((e) => e.id == entryId);
    if (idx == -1) return;
    final newValue = !_entries[idx].isFavorite;
    await _db!.update(
      'history',
      {'isFavorite': newValue ? 1 : 0},
      where: 'id = ?',
      whereArgs: [entryId],
    );
    _entries[idx] = _entries[idx].copyWith(isFavorite: newValue);
    notifyListeners();
  }

  /// Rotates an entry's photo by one quarter turn clockwise (#152).
  ///
  /// Persisted so the correction survives leaving the screen, without
  /// touching the file on disk — see [HistoryEntry.rotationQuarters].
  ///
  /// Updates in-memory state and notifies listeners *before* the DB
  /// write, not after: the rotate control's natural use is several rapid
  /// taps to spin the photo through more than one quarter turn, and
  /// reading `_entries[idx].rotationQuarters` only after a previous
  /// call's `await` resolved meant two taps close together could both
  /// read the same pre-update value and collapse into a single rotation.
  /// Rolled back if the write actually fails, rather than leaving the UI
  /// showing a rotation that was silently never saved.
  Future<void> rotateEntry(int entryId) async {
    final idx = _entries.indexWhere((e) => e.id == entryId);
    if (idx == -1) return;
    final previous = _entries[idx];
    final newValue = (previous.rotationQuarters + 1) % 4;
    _entries[idx] = previous.copyWith(rotationQuarters: newValue);
    notifyListeners();
    try {
      await _db!.update(
        'history',
        {'rotationQuarters': newValue},
        where: 'id = ?',
        whereArgs: [entryId],
      );
    } catch (_) {
      final stillIdx = _entries.indexWhere((e) => e.id == entryId);
      if (stillIdx != -1) _entries[stillIdx] = previous;
      notifyListeners();
      throw const HistoryStorageException(GuideErrorKind.storageRotationFailed);
    }
  }

  /// T51: creates a new named collection (e.g. "Rome trip").
  Future<Collection> createCollection(String name) async {
    final collection = Collection(name: name, createdAt: DateTime.now());
    final id = await _db!.insert('collections', collection.toMap());
    final withId = Collection(id: id, name: name, createdAt: collection.createdAt);
    _collections.add(withId);
    notifyListeners();
    return withId;
  }

  /// T51: deletes a collection and its memberships — entries themselves
  /// are untouched, only the association with this collection is removed.
  Future<void> deleteCollection(int id) async {
    await _db!.delete('history_collections', where: 'collectionId = ?', whereArgs: [id]);
    await _db!.delete('collections', where: 'id = ?', whereArgs: [id]);
    _collections.removeWhere((c) => c.id == id);
    for (final memberships in _entryCollectionIds.values) {
      memberships.remove(id);
    }
    notifyListeners();
  }

  /// T51: adds or removes a single entry from a single collection —
  /// entries can belong to several collections at once.
  Future<void> setEntryInCollection(
      int entryId, int collectionId, bool inCollection) async {
    if (inCollection) {
      await _db!.insert(
        'history_collections',
        {'historyId': entryId, 'collectionId': collectionId},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      (_entryCollectionIds[entryId] ??= <int>{}).add(collectionId);
    } else {
      await _db!.delete(
        'history_collections',
        where: 'historyId = ? AND collectionId = ?',
        whereArgs: [entryId, collectionId],
      );
      _entryCollectionIds[entryId]?.remove(collectionId);
    }
    notifyListeners();
  }

  /// Deletes every entry older than [days] (T95) — same deletion mechanics
  /// as [deleteEntry] (photo/audio files + DB row), just triggered
  /// automatically instead of by a user tap. Meant to be called once per
  /// app startup, only when the user has opted into auto-purge
  /// (SettingsService.autoPurgeEnabled) — manual deletion stays the
  /// default otherwise.
  Future<void> purgeEntriesOlderThan(int days) async {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final expiredIds = _entries
        .where((e) => e.createdAt.isBefore(cutoff))
        .map((e) => e.id!)
        .toList();
    for (final id in expiredIds) {
      await deleteEntry(id);
    }
  }

  // T104: a plain millisecond timestamp collides when two entries are
  // created within the same millisecond (e.g. a share-intent pick and a
  // near-simultaneous manual pick), silently aliasing one entry's photo
  // to another's. `_fileSeq` is incremented synchronously (no `await`
  // before it), so two overlapping calls always get distinct values
  // regardless of how their awaited I/O interleaves afterward.
  static int _fileSeq = 0;

  Future<String> _copyImageToPermanentStorage(String sourcePath) async {
    final seq = _fileSeq++;
    final dir = await getApplicationDocumentsDirectory();
    final historyDir = Directory('${dir.path}/history_images');
    if (!await historyDir.exists()) await historyDir.create();

    final fileName = '${DateTime.now().millisecondsSinceEpoch}_$seq.jpg';
    final destPath = '${historyDir.path}/$fileName';
    await _copyFileOrThrowStorageError(File(sourcePath), destPath);
    return destPath;
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }
}


