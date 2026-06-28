import 'dart:io';
import 'package:flutter/foundation.dart';
import 'anthropic_service.dart';
import 'tts_service.dart';
import 'ai_service.dart';

enum GuideState { idle, analyzing, speaking, paused, error }

class AudioGuideService extends ChangeNotifier {
  AnthropicService? _aiService;
  final TtsService _ttsService = TtsService();

  GuideState _state = GuideState.idle;
  AudioGuideResult? _lastResult;
  String? _errorMessage;

  GuideState get state => _state;
  AudioGuideResult? get lastResult => _lastResult;
  String? get errorMessage => _errorMessage;
  bool get isReady => _aiService != null;

  void setApiKey(String apiKey) {
    _aiService = AnthropicService(apiKey: apiKey);
    _ttsService.onComplete = () {
      _state = GuideState.idle;
      notifyListeners();
    };
    notifyListeners();
  }

  Future<void> analyzeAndPlay(File imageFile) async {
    final service = _aiService;
    if (service == null) {
      _state = GuideState.error;
      _errorMessage = 'Clé API non configurée';
      notifyListeners();
      return;
    }

    try {
      _state = GuideState.analyzing;
      _errorMessage = null;
      notifyListeners();

      _lastResult = await service.analyzeImage(imageFile);

      _state = GuideState.speaking;
      notifyListeners();

      await _ttsService.speak(_lastResult!.script);
    } catch (e) {
      _state = GuideState.error;
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
    }
  }

  Future<void> togglePause() async {
    if (_state == GuideState.speaking) {
      await _ttsService.pause();
      _state = GuideState.paused;
    } else if (_state == GuideState.paused) {
      await _ttsService.speak(_lastResult?.script ?? '');
      _state = GuideState.speaking;
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _ttsService.stop();
    _state = GuideState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _ttsService.dispose();
    super.dispose();
  }
}
