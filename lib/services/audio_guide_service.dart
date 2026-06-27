import 'dart:io';
import 'package:flutter/foundation.dart';
import 'ai_service.dart';
import 'mediapipe_service.dart';
import 'tts_service.dart';

enum GuideState { idle, analyzing, speaking, paused, error }

class AudioGuideService extends ChangeNotifier {
  final MediaPipeService _aiService = MediaPipeService();
  final TtsService _ttsService = TtsService();

  GuideState _state = GuideState.idle;
  AudioGuideResult? _lastResult;
  String? _errorMessage;
  bool _modelDownloaded = false;
  double _downloadProgress = 0;
  String _downloadStatus = '';

  GuideState get state => _state;
  AudioGuideResult? get lastResult => _lastResult;
  String? get errorMessage => _errorMessage;
  bool get modelDownloaded => _modelDownloaded;
  double get downloadProgress => _downloadProgress;
  String get downloadStatus => _downloadStatus;

  Future<void> init() async {
    _modelDownloaded = await _aiService.isModelDownloaded();
    _ttsService.onComplete = () {
      _state = GuideState.idle;
      notifyListeners();
    };
    notifyListeners();
  }

  Future<void> downloadModel() async {
    await _aiService.downloadModel(
      onProgress: (progress, status) {
        _downloadProgress = progress;
        _downloadStatus = status;
        notifyListeners();
      },
    );
    _modelDownloaded = true;
    notifyListeners();
  }

  Future<void> analyzeAndPlay(File imageFile) async {
    try {
      _state = GuideState.analyzing;
      _errorMessage = null;
      notifyListeners();

      await _aiService.initialize();
      _lastResult = await _aiService.analyzeImage(imageFile);

      _state = GuideState.speaking;
      notifyListeners();

      await _ttsService.speak(_lastResult!.script);
    } catch (e) {
      _state = GuideState.error;
      _errorMessage = e.toString();
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
    _aiService.dispose();
    _ttsService.dispose();
    super.dispose();
  }
}
