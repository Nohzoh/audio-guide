import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';
import 'gemini_nano_service.dart';
import 'gemini_api_service.dart';
import 'anthropic_service.dart';
import 'tts_service.dart';
import 'gemini_tts_service.dart';
import 'location_service.dart';
import 'exif_location_service.dart';
import 'wikipedia_service.dart';
import 'history_service.dart';

enum GuideState { idle, locating, analyzing, synthesizing, speaking, paused, error }
enum AIProvider { geminiNano, geminiApi, anthropic }

class PipelineProgress {
  final GuideState state;
  final double stepProgress;
  final int currentStep;
  final double? estimatedSecondsRemaining;

  const PipelineProgress({
    required this.state,
    this.stepProgress = 0.0,
    this.currentStep = 0,
    this.estimatedSecondsRemaining,
  });
}

class AudioGuideService extends ChangeNotifier {
  final TtsService _ttsService = TtsService();
  TtsService get ttsService => _ttsService;
  GeminiTtsService? _geminiTtsService;
  GeminiTtsService? get geminiTtsService => _geminiTtsService;
  String? _lastAudioPath;
  String? get lastAudioPath => _lastAudioPath;
  String _lastTtsModel = "piper";
  String get lastTtsModel => _lastTtsModel;

  final GeminiNanoService _nanoService = GeminiNanoService();

  GuideState _state = GuideState.idle;
  AudioGuideResult? _lastResult;
  String? _errorMessage;
  String _providerName = '';
  File? _lastImageFile;
  LocationPermissionStatus _lastLocationStatus = LocationPermissionStatus.granted;

  // Provider management
  AIProvider _activeProvider = AIProvider.geminiNano;
  bool _nanoAvailable = false;
  String? _geminiApiKey;

  AIProvider get activeProvider => _activeProvider;
  bool get nanoAvailable => _nanoAvailable;
  String? get geminiApiKey => _geminiApiKey;

  // Timing history
  List<double> _gpsDurations = [];
  List<double> _analyzeDurations = [];

  double _stepProgress = 0.0;
  int _currentStep = 0;
  bool _simulating = false;

  GuideState get state => _state;
  AudioGuideResult? get lastResult => _lastResult;
  String? get errorMessage => _errorMessage;
  String get providerName => _providerName;
  File? get lastImageFile => _lastImageFile;
  bool get isReady => true;
  LocationPermissionStatus get lastLocationStatus => _lastLocationStatus;

  PipelineProgress get progress => PipelineProgress(
    state: _state,
    stepProgress: _stepProgress,
    currentStep: _currentStep,
    estimatedSecondsRemaining: _estimateRemaining(),
  );

  double? _estimateRemaining() {
    final analyzeAvg = _analyzeDurations.isNotEmpty
        ? _analyzeDurations.reduce((a, b) => a + b) / _analyzeDurations.length
        : 10.0;
    final gpsAvg = _gpsDurations.isNotEmpty
        ? _gpsDurations.reduce((a, b) => a + b) / _gpsDurations.length
        : 1.5;

    if (_state == GuideState.locating) return gpsAvg + analyzeAvg + 5.0;
    if (_state == GuideState.analyzing) return analyzeAvg * (1 - _stepProgress) + 5.0;
    if (_state == GuideState.synthesizing) return null;
    return null;
  }

  Future<void> init(String? anthropicApiKey) async {
    await _loadPreferences();

    _nanoAvailable = await _nanoService.isAvailable();
    if (_nanoAvailable) {
      try {
        await _nanoService.initialize();
      } catch (e) {
        debugPrint('Gemini Nano init failed: $e');
        _nanoAvailable = false;
      }
    }

    // Determine active provider
    if (_activeProvider == AIProvider.geminiNano && !_nanoAvailable) {
      if (_geminiApiKey?.isNotEmpty == true) {
        _activeProvider = AIProvider.geminiApi;
      } else if (anthropicApiKey?.isNotEmpty == true) {
        _activeProvider = AIProvider.anthropic;
      }
    }

    _updateProviderName();

    _ttsService.onComplete = () {
      _state = GuideState.idle;
      _stepProgress = 0.0;
      notifyListeners();
    };

    notifyListeners();
  }

  void _updateProviderName() {
    switch (_activeProvider) {
      case AIProvider.geminiNano:
        _providerName = 'Gemini Nano';
      case AIProvider.geminiApi:
        _providerName = 'Gemini API';
      case AIProvider.anthropic:
        _providerName = 'Claude (cloud)';
    }
  }

  AIService? get _currentService {
    switch (_activeProvider) {
      case AIProvider.geminiNano:
        return _nanoAvailable ? _nanoService : null;
      case AIProvider.geminiApi:
        final key = _geminiApiKey;
        if (key?.isNotEmpty == true) return GeminiApiService(apiKey: key!);
        return null;
      case AIProvider.anthropic:
        return null;
    }
  }

  Future<void> setActiveProvider(AIProvider provider) async {
    _activeProvider = provider;
    _updateProviderName();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_provider', provider.name);
    notifyListeners();
  }

  Future<void> setGeminiApiKey(String key) async {
    _geminiApiKey = key.isEmpty ? null : key;
    _geminiTtsService = key.isNotEmpty ? GeminiTtsService(apiKey: key) : null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', key);
    // Auto-switch to Gemini API if key provided
    if (key.isNotEmpty) {
      await setActiveProvider(AIProvider.geminiApi);
    } else if (_nanoAvailable) {
      await setActiveProvider(AIProvider.geminiNano);
    }
    notifyListeners();
  }

  void setApiKey(String apiKey) {
    // Legacy: Anthropic key
    notifyListeners();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _geminiApiKey = prefs.getString('gemini_api_key');
    if (_geminiApiKey?.isNotEmpty == true) {
      _geminiTtsService = GeminiTtsService(apiKey: _geminiApiKey!);
    }
    final providerName = prefs.getString('active_provider');
    if (providerName != null) {
      _activeProvider = AIProvider.values.firstWhere(
        (p) => p.name == providerName,
        orElse: () => AIProvider.geminiNano,
      );
    }
    _gpsDurations = (prefs.getStringList('timing_gps') ?? []).map(double.parse).toList();
    _analyzeDurations = (prefs.getStringList('timing_analyze') ?? []).map(double.parse).toList();
  }

  Future<AudioGuideResult?> analyzeAndPlay(File imageFile) async {
    final service = _currentService;
    if (service == null) {
      _state = GuideState.error;
      _errorMessage = 'Aucun service IA disponible. Configurez une clé API dans les paramètres.';
      notifyListeners();
      return null;
    }

    try {
      _lastResult = null;
      _state = GuideState.locating;
      _currentStep = 0;
      _stepProgress = 0.0;
      _lastImageFile = imageFile;
      _errorMessage = null;
      notifyListeners();

      final gpsStart = DateTime.now();
      // Check EXIF GPS first — if image has coordinates, use those
      LocationResult locationResult;
      final exifCoords = await ExifLocationService.readGpsFromImage(imageFile);
      if (exifCoords != null) {
        locationResult = await LocationService.fromCoordinates(
            exifCoords.lat, exifCoords.lon);
      } else {
        locationResult = await LocationService.getCurrentLocation();
      }
      _gpsDurations.add(DateTime.now().difference(gpsStart).inMilliseconds / 1000.0);
      if (_gpsDurations.length > 5) _gpsDurations.removeAt(0);
      _lastLocationStatus = locationResult.status;

      // Wikipedia enrichment
      String? wikiContext;
      if (locationResult.info != null) {
        final wikiResults = await WikipediaService.searchNearby(
          lat: locationResult.info!.latitude,
          lon: locationResult.info!.longitude,
        );
        if (wikiResults.isNotEmpty) {
          wikiContext = WikipediaService.buildContext(wikiResults);
        }
      }

      final fullContext = [
        locationResult.info?.contextForPrompt,
        wikiContext,
      ].where((s) => s != null && s.isNotEmpty).join('\n\n');

      _state = GuideState.analyzing;
      _currentStep = 1;
      _stepProgress = 0.0;
      notifyListeners();

      _startProgressSimulation(expectedDuration: _analyzeDurations.isNotEmpty
          ? _analyzeDurations.reduce((a, b) => a + b) / _analyzeDurations.length
          : 10.0);

      final analyzeStart = DateTime.now();
      _lastResult = await service.analyzeImage(
        imageFile,
        locationContext: fullContext.isNotEmpty ? fullContext : null,
      );
      _analyzeDurations.add(DateTime.now().difference(analyzeStart).inMilliseconds / 1000.0);
      if (_analyzeDurations.length > 5) _analyzeDurations.removeAt(0);
      _stopProgressSimulation();

      if (locationResult.info?.city != null && _lastResult != null) {
        _lastResult = AudioGuideResult(
          title: _lastResult!.title,
          script: _lastResult!.script,
          locationName: locationResult.info!.city,
        );
      }

      _state = GuideState.synthesizing;
      _currentStep = 2;
      _stepProgress = -1.0;
      notifyListeners();

      final geminiTts = _geminiTtsService;
      if (geminiTts != null) {
        try {
          geminiTts.onComplete = _ttsService.onComplete;
          await geminiTts.speak(_lastResult!.script);
        } catch (ttsError) {
          // Gemini TTS failed — fall back to Piper
          debugPrint('Gemini TTS failed, falling back to Piper: \$ttsError');
          await _ttsService.speak(_lastResult!.script);
        }
      } else {
        await _ttsService.speak(_lastResult!.script);
      }
      // Cache the generated audio for replay without re-generating
      _lastAudioPath = await _getLastWavPath();

      final prefs = await SharedPreferences.getInstance();
      prefs.setStringList('timing_gps', _gpsDurations.map((d) => d.toString()).toList());
      prefs.setStringList('timing_analyze', _analyzeDurations.map((d) => d.toString()).toList());

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

  Future<void> _startProgressSimulation({required double expectedDuration}) async {
    _simulating = true;
    _stepProgress = 0.0;
    final startTime = DateTime.now();
    while (_simulating && _stepProgress < 0.95) {
      await Future.delayed(const Duration(milliseconds: 150));
      final elapsed = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
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

  Future<String?> _getLastWavPath() async {
    try {
      final tmpDir = await getTemporaryDirectory();
      final geminiWav = File('${tmpDir.path}/gemini_tts_output.wav');
      if (await geminiWav.exists()) return geminiWav.path;
      final piperWav = File('${tmpDir.path}/tts_output.wav');
      if (await piperWav.exists()) return piperWav.path;
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    _simulating = false;
    _ttsService.dispose();
    super.dispose();
  }
}
