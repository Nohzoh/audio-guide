import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _isPlaying = false;
  Function()? onComplete;

  Future<void> initialize() async {
    if (_initialized) return;
    await _tts.setLanguage('fr-FR');
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    _tts.setCompletionHandler(() {
      _isPlaying = false;
      onComplete?.call();
    });
    _initialized = true;
  }

  bool get isPlaying => _isPlaying;

  Future<void> speak(String text) async {
    await initialize();
    _isPlaying = true;
    await _tts.speak(text);
  }

  Future<void> pause() async {
    await _tts.pause();
    _isPlaying = false;
  }

  Future<void> resume() async {
    await _tts.speak('');
    _isPlaying = true;
  }

  Future<void> stop() async {
    await _tts.stop();
    _isPlaying = false;
  }

  void dispose() {
    _tts.stop();
  }
}
