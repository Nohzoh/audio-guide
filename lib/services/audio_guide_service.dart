import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';
import 'gemini_nano_service.dart';
import 'anthropic_service.dart';
import 'tts_service.dart';
import 'location_service.dart';

enum GuideState { idle, locating, analyzing, synthesizing, speaking, paused, error }

class StepTiming {
  final String key;
  final List<double> durations;

  StepTiming(this.key, this.durations);

  double get average => durations.isEmpty ? 0 : durations.reduce((a, b) => a + b) / durations.length;
  bool get hasData => durations.isNotEmpty;
}

class PipelineProgress {
  final GuideState state;
  final double stepProgress; // 0.0 to 1.0 within current step
  final int currentStep;    // 0=GPS, 1=Analyze, 2=TTS
  final double? estimatedSecondsRemaining;

  const PipelineProgress({
    required this.state,
    this.stepProgress = 0.0,
    this.currentStep = 0,
    this.estimatedSecondsRemaining,
  });
}

class AudioGuideService extends ChangeNotifier {
  AIService? _aiService;
  final TtsService _ttsService = TtsService();
  final GeminiNanoService _nanoService = GeminiNanoService();

  GuideState _state = GuideState.idle;
  AudioGuideResult? _lastResult;
  String? _errorMessage;
  String _providerName = '';
  File? _lastImageFile;
  LocationPermissionStatus _lastLocationStatus = LocationPermissionStatus.granted;

  // Timing history
  List<double> _gpsDurations = [];
  List<double> _analyzeDurations = [];
  List<double> _ttsDurations = [];

  // Current step progress for animated indicator
  double _stepProgress = 0.0;
  int _currentStep = 0;

  GuideState get state => _state;
  AudioGuideResult? get lastResult => _lastResult;
  String? get errorMessage => _errorMessage;
  String get providerName => _providerName;
  File? get lastImageFile => _lastImageFile;
  bool get isReady => _aiService != null;
  LocationPermissionStatus get lastLocationStatus => _lastLocationStatus;

  PipelineProgress get progress => PipelineProgress(
    state: _state,
    stepProgress: _stepProgress,
    currentStep: _currentStep,
    estimatedSecondsRemaining: _estimateRemaining(),
  );

  double? _estimateRemaining() {
    if (_state == GuideState.locating) {
      final gpsAvg = _gpsDurations.isNotEmpty
          ? _gpsDurations.reduce((a, b) => a + b) / _gpsDurations.length : 1.5;
      final analyzeAvg = _analyzeDurations.isNotEmpty
          ? _analyzeDurations.reduce((a, b) => a + b) / _analyzeDurations.length : 10.0;
      final ttsAvg = _ttsDurations.isNotEmpty
          ? _ttsDurations.reduce((a, b) => a + b) / _ttsDurations.length : 5.0;
      return gpsAvg + analyzeAvg + ttsAvg;
    }
    if (_state == GuideState.analyzing) {
      final analyzeAvg = _analyzeDurations.isNotEmpty
          ? _analyzeDurations.reduce((a, b) => a + b) / _analyzeDurations.length : 10.0;
      final ttsAvg = _ttsDurations.isNotEmpty
          ? _ttsDurations.reduce((a, b) => a + b) / _ttsDurations.length : 5.0;
      return analyzeAvg * (1 - _stepProgress) + ttsAvg;
    }
    if (_state == GuideState.synthesizing) {
      final ttsAvg = _ttsDurations.isNotEmpty
          ? _ttsDurations.reduce((a, b) => a + b) / _ttsDurations.length : 5.0;
      return ttsAvg * (1 - _stepProgress);
    }
    return null;
  }

  Future<void> init(String? anthropicApiKey) async {
    await _loadTimings();

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

    if (_aiService == null && anthropicApiKey != null && anthropicApiKey.isNotEmpty) {
      _aiService = AnthropicService(apiKey: anthropicApiKey);
      _providerName = 'Claude (cloud)';
    }

    _ttsService.onComplete = () {
      _state = GuideState.idle;
      _stepProgress = 0.0;
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
      // Step 1: GPS
      _state = GuideState.locating;
      _currentStep = 0;
      _stepProgress = 0.0;
      _lastImageFile = imageFile;
      _errorMessage = null;
      notifyListeners();

      final gpsStart = DateTime.now();
      final locationResult = await LocationService.getCurrentLocation();
      _gpsDurations.add(DateTime.now().difference(gpsStart).inMilliseconds / 1000.0);
      if (_gpsDurations.length > 5) _gpsDurations.removeAt(0);
      _lastLocationStatus = locationResult.status;

      // Step 2: Analyze
      _state = GuideState.analyzing;
      _currentStep = 1;
      _stepProgress = 0.0;
      notifyListeners();

      // Simulate progress during analysis (we don't have real progress events)
      _startProgressSimulation(expectedDuration: _analyzeDurations.isNotEmpty
          ? _analyzeDurations.reduce((a, b) => a + b) / _analyzeDurations.length
          : 10.0);

      final analyzeStart = DateTime.now();
      _lastResult = await service.analyzeImage(
        imageFile,
        locationContext: locationResult.info?.contextForPrompt,
      );
      final analyzeDuration = DateTime.now().difference(analyzeStart).inMilliseconds / 1000.0;
      _analyzeDurations.add(analyzeDuration);
      if (_analyzeDurations.length > 5) _analyzeDurations.removeAt(0);
      _stopProgressSimulation();

      if (locationResult.info?.city != null && _lastResult != null) {
        _lastResult = AudioGuideResult(
          title: _lastResult!.title,
          script: _lastResult!.script,
          locationName: locationResult.info!.city,
        );
      }

      // Step 3: TTS synthesis
      _state = GuideState.synthesizing;
      _currentStep = 2;
      _stepProgress = 0.0;
      notifyListeners();

      _startProgressSimulation(expectedDuration: _ttsDurations.isNotEmpty
          ? _ttsDurations.reduce((a, b) => a + b) / _ttsDurations.length
          : 5.0);

      final ttsStart = DateTime.now();
      await _ttsService.speak(_lastResult!.script);
      final ttsDuration = DateTime.now().difference(ttsStart).inMilliseconds / 1000.0;
      _ttsDurations.add(ttsDuration);
      if (_ttsDurations.length > 5) _ttsDurations.removeAt(0);
      _stopProgressSimulation();

      await _saveTimings();

      _state = GuideState.speaking;
      _stepProgress = 1.0;
      notifyListeners();

      return _lastResult;
    } catch (e) {
      _stopProgressSimulation();
      _state = GuideState.error;
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
      return null;
    }
  }

  // Simulate smooth progress during steps that don't report progress
  bool _simulating = false;
  Future<void> _startProgressSimulation(double expectedDuration) async {
    _simulating = true;
    _stepProgress = 0.0;
    final startTime = DateTime.now();
    while (_simulating && _stepProgress < 0.95) {
      await Future.delayed(const Duration(milliseconds: 100));
      final elapsed = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
      // Asymptotic progress that never quite reaches 1.0
      _stepProgress = 1.0 - (1.0 / (1.0 + elapsed / expectedDuration * 2));
      notifyListeners();
    }
  }

  void _stopProgressSimulation() {
    _simulating = false;
    _stepProgress = 1.0;
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
    _stopProgressSimulation();
    await _ttsService.stop();
    _state = GuideState.idle;
    notifyListeners();
  }

  Future<void> _saveTimings() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setStringList('timing_gps', _gpsDurations.map((d) => d.toString()).toList());
    prefs.setStringList('timing_analyze', _analyzeDurations.map((d) => d.toString()).toList());
    prefs.setStringList('timing_tts', _ttsDurations.map((d) => d.toString()).toList());
  }

  Future<void> _loadTimings() async {
    final prefs = await SharedPreferences.getInstance();
    _gpsDurations = (prefs.getStringList('timing_gps') ?? []).map(double.parse).toList();
    _analyzeDurations = (prefs.getStringList('timing_analyze') ?? []).map(double.parse).toList();
    _ttsDurations = (prefs.getStringList('timing_tts') ?? []).map(double.parse).toList();
  }

  @override
  void dispose() {
    _simulating = false;
    _ttsService.dispose();
    super.dispose();
  }
}
