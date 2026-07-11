import 'dart:io';
import 'package:flutter/services.dart';
import 'ai_service.dart';

const _channel = MethodChannel('com.audioguide/gemini_nano');

class GeminiNanoService implements AIService {
  bool _initialized = false;

  @override
  String get displayName => 'Gemini Nano (on-device)';

  @override
  Future<bool> isAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await _channel.invokeMethod('initialize');
    _initialized = true;
  }

  @override
  Future<AudioGuideResult> analyzeImage(File imageFile,
      {String? locationContext}) async {
    if (!_initialized) await initialize();

    try {
      final args = {'imagePath': imageFile.path};
      if (locationContext != null) args['locationContext'] = locationContext;

      final description = await _channel.invokeMethod<String>(
        'describeImage',
        args,
      );

      final text = description ?? '';
      final title = _extractTitle(text);

      return AudioGuideResult(title: title, script: text);
    } on PlatformException catch (e) {
      throw Exception('Gemini Nano: ${e.message}');
    }
  }

  String _extractTitle(String description) {
    final first = description.split('.').first.trim();
    return first.length > 50 ? '${first.substring(0, 50)}...' : first;
  }

  @override
  void dispose() {
    _initialized = false;
  }
}
