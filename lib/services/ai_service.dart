import 'dart:io';

class AudioGuideResult {
  final String title;
  final String script;
  final String? locationName;

  const AudioGuideResult({
    required this.title,
    required this.script,
    this.locationName,
  });
}

abstract class AIService {
  String get displayName;
  Future<bool> isAvailable();
  Future<void> initialize();
  Future<AudioGuideResult> analyzeImage(File imageFile, {String? locationContext});
  void dispose();
}
