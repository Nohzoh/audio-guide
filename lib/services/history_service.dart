import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class HistoryEntry {
  final int? id;
  final String imagePath;
  final String title;
  final String script;
  final String? locationName;
  final DateTime createdAt;

  const HistoryEntry({
    this.id,
    required this.imagePath,
    required this.title,
    required this.script,
    this.locationName,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'imagePath': imagePath,
    'title': title,
    'script': script,
    'locationName': locationName,
    'createdAt': createdAt.toIso8601String(),
  };

  factory HistoryEntry.fromMap(Map<String, dynamic> map) => HistoryEntry(
    id: map['id'] as int?,
    imagePath: map['imagePath'] as String,
    title: map['title'] as String,
    script: map['script'] as String,
    locationName: map['locationName'] as String?,
    createdAt: DateTime.parse(map['createdAt'] as String),
  );
}

class HistoryService extends ChangeNotifier {
  Database? _db;
  List<HistoryEntry> _entries = [];

  List<HistoryEntry> get entries => _entries;

  Future<void> init() async {
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      join(dbPath, 'audio_guide_history.db'),
      version: 1,
      onCreate: (db, version) {
        return db.execute('''
          CREATE TABLE history(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            imagePath TEXT NOT NULL,
            title TEXT NOT NULL,
            script TEXT NOT NULL,
            locationName TEXT,
            createdAt TEXT NOT NULL
          )
        ''');
      },
    );
    await _loadEntries();
  }

  Future<void> _loadEntries() async {
    final maps = await _db!.query(
      'history',
      orderBy: 'createdAt DESC',
    );
    _entries = maps.map(HistoryEntry.fromMap).toList();
    notifyListeners();
  }

  Future<HistoryEntry> addEntry({
    required String imagePath,
    required String title,
    required String script,
    String? locationName,
  }) async {
    // Copy image to permanent storage
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

  Future<void> deleteEntry(int id) async {
    final entry = _entries.firstWhere((e) => e.id == id);
    // Delete image file
    try {
      final file = File(entry.imagePath);
      if (await file.exists()) await file.delete();
    } catch (_) {}

    await _db!.delete('history', where: 'id = ?', whereArgs: [id]);
    _entries.removeWhere((e) => e.id == id);
    notifyListeners();
  }

  Future<String> _copyImageToPermanentStorage(String sourcePath) async {
    final dir = await getApplicationDocumentsDirectory();
    final historyDir = Directory('${dir.path}/history_images');
    if (!await historyDir.exists()) await historyDir.create();

    final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
    final destPath = '${historyDir.path}/$fileName';
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }
}
