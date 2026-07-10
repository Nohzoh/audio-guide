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
  Future<AudioGuideResult> analyzeImage(File imageFile) async {
    if (!_initialized) await initialize();

    try {
      final description = await _channel.invokeMethod<String>(
        'describeImage',
        {'imagePath': imageFile.path},
      );

      final text = description ?? '';

      // Build a guide script from the raw description
      final script = _buildGuideScript(text);
      final title = _extractTitle(text);

      return AudioGuideResult(title: title, script: script);
    } on PlatformException catch (e) {
      throw Exception('Gemini Nano: ${e.message}');
    }
  }

  String _buildGuideScript(String description) {
    if (description.isEmpty) return 'Je ne parviens pas à analyser cette image.';
    // Gemini Nano returns a raw description — wrap it in guide style
    return description;
  }

  String _extractTitle(String description) {
    final words = description.split(' ').take(5).join(' ');
    return words.length > 40 ? '${words.substring(0, 40)}...' : words;
  }

  @override
  void dispose() {
    _initialized = false;
  }
}
