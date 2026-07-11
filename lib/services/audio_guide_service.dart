import 'dart:io';
import 'package:flutter/foundation.dart';
import 'ai_service.dart';
import 'gemini_nano_service.dart';
import 'anthropic_service.dart';
import 'tts_service.dart';
import 'location_service.dart';

enum GuideState { idle, locating, analyzing, speaking, paused, error }

class AudioGuideService extends ChangeNotifier {
  AIService? _aiService;
  final TtsService _ttsService = TtsService();
  final GeminiNanoService _nanoService = GeminiNanoService();

  GuideState _state = GuideState.idle;
  AudioGuideResult? _lastResult;
  String? _errorMessage;
  String _providerName = '';
  File? _lastImageFile;

  GuideState get state => _state;
  AudioGuideResult? get lastResult => _lastResult;
  String? get errorMessage => _errorMessage;
  String get providerName => _providerName;
  File? get lastImageFile => _lastImageFile;
  bool get isReady => _aiService != null;

  Future<void> init(String? anthropicApiKey) async {
    final nanoAvailable = await _nanoService.isAvailable();
    if (nanoAvailable) {
      try {
        await _nanoService.initialize();
        _aiService = _nanoService;
        _providerName = 'Gemini Nano';
      } catch (e) {
        debugPrint('Gemini Nano init failed: $e');
      }
    }

    if (_aiService == null &&
        anthropicApiKey != null &&
        anthropicApiKey.isNotEmpty) {
      _aiService = AnthropicService(apiKey: anthropicApiKey);
      _providerName = 'Claude (cloud)';
    }

    _ttsService.onComplete = () {
      _state = GuideState.idle;
      notifyListeners();
    };

    notifyListeners();
  }

  void setApiKey(String apiKey) {
    _aiService = AnthropicService(apiKey: apiKey);
    _providerName = 'Claude (cloud)';
    _ttsService.onComplete = () {
      _state = GuideState.idle;
      notifyListeners();
    };
    notifyListeners();
  }

  Future<AudioGuideResult?> analyzeAndPlay(File imageFile) async {
    final service = _aiService;
    if (service == null) {
      _state = GuideState.error;
      _errorMessage = 'Aucun service IA disponible';
      notifyListeners();
      return null;
    }

    try {
      // Step 1: Get GPS location
      _state = GuideState.locating;
      _lastImageFile = imageFile;
      _errorMessage = null;
      notifyListeners();

      final location = await LocationService.getCurrentLocation();
      final locationContext = location?.contextForPrompt;

      if (locationContext != null) {
        debugPrint('Location context: $locationContext');
      }

      // Step 2: Analyze image with location context
      _state = GuideState.analyzing;
      notifyListeners();

      _lastResult = await service.analyzeImage(
        imageFile,
        locationContext: locationContext,
      );

      // Store location name in result if available
      if (location?.city != null && _lastResult != null) {
        _lastResult = AudioGuideResult(
          title: _lastResult!.title,
          script: _lastResult!.script,
          locationName: location!.city,
        );
      }

      // Step 3: Speak
      _state = GuideState.speaking;
      notifyListeners();

      await _ttsService.speak(_lastResult!.script);
      return _lastResult;
    } catch (e) {
      _state = GuideState.error;
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
      return null;
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
