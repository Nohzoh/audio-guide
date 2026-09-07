import 'dart:io';
import '../constants/output_languages.dart';
import '../utils/app_logger.dart';
import '../utils/cancel_token.dart';
import '../utils/error_sanitizer.dart';
import '../models/guide_error.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/widgets.dart';
import 'ai_provider_manager.dart';
import 'ai_service.dart';
import 'analysis_foreground_service.dart';
import 'audio_ready_notifier.dart';
import 'gemini_api_service.dart';
import 'gemini_nano_service.dart';
import 'native_tts_service.dart';
import 'gemini_tts_service.dart';
import 'location_service.dart';
import 'remote_config_service.dart';
import 'guide_preferences_store.dart';
import 'guide_progress_estimator.dart';
import 'location_context_resolver.dart';
import 'tts_orchestrator.dart';

export 'ai_provider_manager.dart' show AIProvider;

enum GuideState { idle, locating, analyzing, synthesizing, speaking, paused, cancelling, error, scriptReady }

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
  AudioGuideService({
    NativeTtsService? nativeTtsService,
    GeminiTtsService? geminiTtsService,
    GeminiApiService? geminiApiService,
    GeminiNanoService? nanoService,
    GuidePreferencesStore? preferencesStore,
    LocationContextResolver? locationResolver,
    AnalysisForegroundService? foregroundService,
    AudioReadyNotifier? audioReadyNotifier,
  })  : _nativeTtsService = nativeTtsService ?? NativeTtsService(),
        _preferencesStore = preferencesStore ?? GuidePreferencesStore(),
        _locationResolver = locationResolver ?? LocationContextResolver(),
        _foregroundService = foregroundService ?? AnalysisForegroundService(),
        _audioReadyNotifier = audioReadyNotifier ?? AudioReadyNotifier() {
    _ttsOrchestrator = TtsOrchestrator(nativeTts: _nativeTtsService);
    _providerManager = AiProviderManager(
      preferencesStore: _preferencesStore,
      nanoService: nanoService,
      geminiApiService: geminiApiService,
      geminiTtsService: geminiTtsService,
    );
  }

  final AnalysisForegroundService _foregroundService;
  final AudioReadyNotifier _audioReadyNotifier;

  final NativeTtsService _nativeTtsService;
  NativeTtsService get nativeTtsService => _nativeTtsService;
  final GuidePreferencesStore _preferencesStore;
  final LocationContextResolver _locationResolver;
  late final TtsOrchestrator _ttsOrchestrator;
  // #136: owns AI provider selection (Nano vs. API), the API key, and the
  // Gemini API/TTS service instances that depend on it — see
  // AiProviderManager's own doc for why this was split out.
  late final AiProviderManager _providerManager;
  GuideProgressEstimator _progressEstimator = GuideProgressEstimator();
  GeminiTtsService? get geminiTtsService => _providerManager.geminiTtsService;
  // #283: lets Settings query NanoDeviceStatus (hardware/OS support, not
  // just the collapsed nanoAvailable bool) without AudioGuideService
  // having to proxy every GeminiNanoService method individually.
  GeminiNanoService get nanoService => _providerManager.nanoService;
  String? _lastAudioPath;
  String? get lastAudioPath => _lastAudioPath;
  String _lastTtsModel = "native-tts";
  String get lastTtsModel => _lastTtsModel;
  String _ttsVoiceGender = 'female';
  String get ttsVoiceGender => _ttsVoiceGender;
  double _playbackSpeed = 1.0;
  double get playbackSpeed => _playbackSpeed;
  String? _lastAiModel;
  String? get lastAiModel => _lastAiModel;
  String? _lastGpsSource;
  String? get lastGpsSource => _lastGpsSource;
  bool _lastWikipediaUsed = false;
  bool get lastWikipediaUsed => _lastWikipediaUsed;
  int? _lastAnalysisDurationMs;
  int? get lastAnalysisDurationMs => _lastAnalysisDurationMs;
  double? _lastGpsLatitude;
  double? get lastGpsLatitude => _lastGpsLatitude;
  double? _lastGpsLongitude;
  double? get lastGpsLongitude => _lastGpsLongitude;
  String? _lastGpsAddress;
  String? get lastGpsAddress => _lastGpsAddress;
  // T132: whether *this specific* analysis fell back from the cloud API to
  // on-device Nano — reset at the start of every analyzeAndPlay() call, so
  // it never leaks stale state from a previous run. Deliberately separate
  // from the active provider, which is no longer mutated by a fallback (see
  // the catch block below) — a transient cloud hiccup must not silently
  // and permanently downgrade every later analysis in the session.
  bool _lastProviderFallbackToNano = false;
  // Fallback info
  bool get aiModelWasFallback {
    if (_lastProviderFallbackToNano) return true;
    final svc = _providerManager.currentService;
    if (svc is GeminiApiService) {
      final used = svc.lastUsedModel;
      final cfg = RemoteConfigService.current;
      return used != null && used != cfg.geminiModel;
    }
    return false;
  }
  String? get actualAiModel {
    if (_lastProviderFallbackToNano) return _lastAiModel;
    final svc = _providerManager.currentService;
    if (svc is GeminiApiService) return svc.lastUsedModel;
    return _lastAiModel;
  }
  bool get ttsWasFallback =>
      _lastTtsModel == 'native-tts' && _providerManager.geminiTtsService != null;
  bool get ttsFallbackWasRateLimit => _ttsOrchestrator.wasRateLimited;

  GuideState _state = GuideState.idle;
  AudioGuideResult? _lastResult;
  GuideError? _lastGuideError;
  File? _lastImageFile;
  LocationPermissionStatus _lastLocationStatus = LocationPermissionStatus.granted;

  // Cancellation support. Not final: #322 — a fresh instance is created for
  // every analyzeAndPlay()/generateAudioForScript() call (see there) rather
  // than reusing+resetting one shared token, so an old, still-running
  // invocation that was cancelled can never have its own cancellation
  // silently undone by a newer call resetting the same shared instance.
  CancelToken _cancelToken = CancelToken();
  CancelToken get cancelToken => _cancelToken;

  AIProvider get activeProvider => _providerManager.activeProvider;
  bool get nanoAvailable => _providerManager.nanoAvailable;
  String? get geminiApiKey => _providerManager.geminiApiKey;

  /// #325: re-checks on-device Nano availability — [init] only resolves
  /// it once at startup, so a device where Nano finishes downloading
  /// mid-session would otherwise stay locked out of picking it as long
  /// as the app keeps running. Called from Settings alongside its own
  /// (purely cosmetic) device-status display check.
  Future<void> refreshNanoAvailability() async {
    await _providerManager.refreshNanoAvailability();
    notifyListeners();
  }

  int _currentStep = 0;
  bool _analysisInProgress = false;

  GuideState get state => _state;
  /// #174: whether [analyzeAndPlay]/[generateAudioForScript] is actively
  /// running right now — mirrors the same `_analysisInProgress` guard
  /// those methods already check internally, exposed so entry points
  /// (capture, gallery pick, share-intent, retry) can disable themselves
  /// instead of letting a second attempt fire and immediately hit that
  /// guard's "already in progress" error. Deliberately not "state !=
  /// idle": `speaking`/`paused`/`scriptReady` are legitimate resting
  /// states after a *finished* analysis, not reasons to block a new one.
  bool get isBusy => _analysisInProgress;
  AudioGuideResult? get lastResult => _lastResult;
  /// #230: the *code* for the last failure (localize via
  /// `localizeGuideError` at display time), not raw prose.
  GuideError? get lastGuideError => _lastGuideError;
  String get providerName => _providerManager.providerName;
  File? get lastImageFile => _lastImageFile;
  /// #298: used by main.dart's routing to decide Onboarding vs Home —
  /// was hardcoded `true` since the multi-provider refactor (Nano/Gemini
  /// API/Anthropic) introduced `_providerManager` and nothing recomputed
  /// this against it, which silently made `OnboardingScreen`
  /// unreachable for everyone (the routing condition
  /// `guide.isReady || settings.isOnboardingComplete` was always true).
  /// Now reflects whether an AI provider is actually usable: local
  /// (Nano, if the device supports it) or a configured cloud API key —
  /// either makes the app functional without onboarding.
  bool get isReady => _providerManager.nanoAvailable || (_providerManager.geminiApiKey?.isNotEmpty ?? false);
  LocationPermissionStatus get lastLocationStatus => _lastLocationStatus;

  PipelineProgress get progress => PipelineProgress(
    state: _state,
    stepProgress: _progressEstimator.stepProgress,
    currentStep: _currentStep,
    estimatedSecondsRemaining: _estimateRemaining(),
  );

  double? _estimateRemaining() {
    if (_state == GuideState.locating) return _progressEstimator.estimateWhileLocating;
    if (_state == GuideState.analyzing) return _progressEstimator.estimateWhileAnalyzing;
    return null;
  }

  Future<void> init() async {
    await _loadPreferences();
    await _providerManager.init();

    _nativeTtsService.onComplete = () {
      _state = GuideState.idle;
      _progressEstimator.stepProgress = 0.0;
      notifyListeners();
    };

    notifyListeners();
  }

  Future<void> setActiveProvider(AIProvider provider) async {
    await _providerManager.setActiveProvider(provider);
    notifyListeners();
  }

  /// Throws [SecureStorageUnavailableException] if the key can't be
  /// persisted securely — nothing is changed in-memory in that case
  /// either, so the app's active provider/key state always matches what's
  /// actually on disk.
  Future<void> setGeminiApiKey(String key) async {
    await _providerManager.setGeminiApiKey(key);
    notifyListeners();
  }

  Future<void> _loadPreferences() async {
    final timings = await _preferencesStore.loadTimings();
    _progressEstimator = GuideProgressEstimator(
      gpsDurations: timings.gpsDurations,
      analyzeDurations: timings.analyzeDurations,
    );
    // Plain field assignment (no platform I/O) — the voice itself is
    // applied lazily on first real use of the native engine, matching
    // its existing lazy-initialization pattern.
    _ttsVoiceGender = await _preferencesStore.loadTtsVoiceGender();
    _nativeTtsService.preferredGender = _ttsVoiceGender;
    _playbackSpeed = await _preferencesStore.loadPlaybackSpeed();
  }

  /// Changes the preferred native TTS voice's gender ('female' or 'male',
  /// T89) and re-applies it immediately so a subsequent preview/speak
  /// reflects the change without waiting for a fresh app start.
  Future<void> setTtsVoiceGender(String gender) async {
    _ttsVoiceGender = gender;
    _nativeTtsService.preferredGender = gender;
    await _preferencesStore.saveTtsVoiceGender(gender);
    await _nativeTtsService.applyPreferredVoice();
    notifyListeners();
  }

  /// Changes the narration playback speed multiplier (T15, 1.0 = normal).
  /// Applies to both TTS engines; no live re-apply needed since it's
  /// threaded through as a parameter at the next play, not cached engine
  /// state (see [NativeTtsService.speak]/[GeminiTtsService.speak]).
  Future<void> setPlaybackSpeed(double speed) async {
    _playbackSpeed = speed;
    await _preferencesStore.savePlaybackSpeed(speed);
    notifyListeners();
  }

  /// #130: resolves [language] (a display name from `outputLanguageLocales`,
  /// e.g. from `SettingsService.outputLanguage`) to a BCP-47 locale code and
  /// applies it to the native TTS fallback engine — kept out of the UI
  /// layer so callers never need to know about `outputLanguageLocales`
  /// themselves. Unlike [preferredGender], not cached: language can differ
  /// per analysis, so this is re-applied at every use rather than once.
  void _prepareNativeTtsLanguage(String? language) {
    _nativeTtsService.preferredLanguageLocale =
        outputLanguageLocales[language] ?? outputLanguageLocales[defaultOutputLanguage]!;
  }

  /// Public wrapper for the one call site outside this class that speaks
  /// via [nativeTtsService] directly rather than through
  /// [_synthesizeAndPlay] — replaying a history entry whose last known
  /// voice was already the native fallback (see history_screen.dart's
  /// `_toggleAudio`, the `hasLowQualityTts` branch).
  void prepareNativeTtsLanguageForReplay(String? language) =>
      _prepareNativeTtsLanguage(language);

  /// Analyzes [imageFile] and, unless [generateAudio] is false (T16),
  /// synthesizes and plays the resulting script. When [generateAudio] is
  /// false, the pipeline stops after analysis with state
  /// [GuideState.scriptReady] — audio can be generated later via
  /// [generateAudioForScript].
  ///
  /// [knownCoordinates] resolves location from already-known coordinates
  /// (T78 — a deferred capture's saved GPS fix) instead of re-reading GPS
  /// from [imageFile]; use this to launch the analysis for a captured
  /// entry using the location it was captured at, not the device's
  /// current location.
  Future<AudioGuideResult?> analyzeAndPlay(
    File imageFile, {
    bool generateAudio = true,
    ({double lat, double lon, String source})? knownCoordinates,
    String? style,
    String? language,
    int? entryId,
  }) async {
    if (_analysisInProgress || _state == GuideState.cancelling) {
      _lastGuideError = const GuideError(GuideErrorKind.busyAnalysis);
      _state = GuideState.error;
      notifyListeners();
      return null;
    }

    final service = _providerManager.currentService;
    if (service == null) {
      _state = GuideState.error;
      _lastGuideError = const GuideError(GuideErrorKind.aiNoProviderConfigured);
      notifyListeners();
      return null;
    }

    _analysisInProgress = true;
    // #322: a fresh token for this invocation specifically — see the field
    // doc. Every check/pass-through below uses this local capture, not
    // _cancelToken directly, so a later overlapping call reassigning
    // _cancelToken can't affect this one.
    _cancelToken = CancelToken();
    final cancelToken = _cancelToken;
    await _foregroundService.start();
    await _audioReadyNotifier.requestPermissionIfNeeded();

    try {
      _lastResult = null;
      _lastProviderFallbackToNano = false;
      _state = GuideState.locating;
      _currentStep = 0;
      _progressEstimator.stepProgress = 0.0;
      _lastImageFile = imageFile;
      _lastGuideError = null;
      notifyListeners();

      // Check for cancellation before starting
      if (cancelToken.isCancelled) {
        _state = GuideState.idle;
        _analysisInProgress = false;
        notifyListeners();
        return null;
      }

      final gpsStart = DateTime.now();
      final locationContext = knownCoordinates != null
          ? await _locationResolver.resolveFromCoordinates(
              lat: knownCoordinates.lat,
              lon: knownCoordinates.lon,
              source: knownCoordinates.source,
            )
          : await _locationResolver.resolve(imageFile);
      _lastGpsSource = locationContext.source;
      _lastGpsLatitude = locationContext.latitude;
      _lastGpsLongitude = locationContext.longitude;
      _lastGpsAddress = locationContext.address;
      _lastLocationStatus = locationContext.status;
      _lastWikipediaUsed = locationContext.wikipediaUsed;
      _progressEstimator.recordGpsDuration(
          DateTime.now().difference(gpsStart).inMilliseconds / 1000.0);

      // Check cancellation before AI analysis
      if (cancelToken.isCancelled) {
        _state = GuideState.idle;
        _analysisInProgress = false;
        notifyListeners();
        return null;
      }

      _state = GuideState.analyzing;
      _currentStep = 1;
      _progressEstimator.stepProgress = 0.0;
      notifyListeners();

      _progressEstimator.simulate(
        expectedDuration: _progressEstimator.averageAnalyzeDuration,
        onTick: notifyListeners,
      );

      _lastAiModel = _providerManager.providerName; // will be refined after analysis
      final analyzeStart = DateTime.now();
      try {
        _lastResult = await service.analyzeImage(
          imageFile,
          locationContext: locationContext.promptContext,
          cancelToken: cancelToken,
          style: style,
          language: language,
        );
      } catch (analysisError) {
        // A cancellation must abort outright, not trigger the local-model
        // fallback below (T70) — the user asked to stop, not to keep
        // burning time on a slower on-device retry.
        if (analysisError is CancelledException) rethrow;
        // Gemini Nano inference is an OS-enforced foreground-only
        // operation (unlike the cloud API) — if the app was backgrounded
        // mid-analysis, the native call fails outright and there's no
        // retry that fixes it here. No auto-fallback to the cloud API
        // either: the user chose on-device processing, often for privacy
        // (see PRIVACY.md), so silently sending their photo to Gemini API
        // instead would be a real overstep — just report it clearly.
        if (analysisError is GeminiNanoBackgroundRestrictedException) {
          throw const GuideError(GuideErrorKind.aiBackgroundRestricted);
        }
        final message = sanitizeError(analysisError.toString());
        if (_providerManager.activeProvider == AIProvider.geminiApi &&
            _providerManager.nanoAvailable) {
          AppLogger.error('Cloud analysis failed, trying local fallback: $message');
          // T132: deliberately does NOT touch the active provider — this is a
          // one-off fallback for *this* analysis only. Permanently
          // switching the active provider here used to silently and
          // invisibly strand every later analysis on Nano for the rest of
          // the app session, even after the cloud API recovered, with no
          // fallback log/UI indication on those later runs (nothing had
          // actually failed *this* time, from the code's point of view).
          try {
            _lastResult = await _providerManager.nanoService.analyzeImage(
              imageFile,
              locationContext: locationContext.promptContext,
              cancelToken: cancelToken,
              style: style,
              language: language,
            );
            _lastProviderFallbackToNano = true;
            _lastAiModel = 'Gemini Nano';
          } on GeminiNanoBackgroundRestrictedException {
            throw const GuideError(GuideErrorKind.aiFallbackBackgroundRestricted);
          }
        } else {
          // #230: a GuideError thrown by the provider service itself (e.g.
          // GeminiApiService's granular quota/model/service/network kind)
          // is propagated as-is, preserving its specific kind — only a
          // truly generic exception gets wrapped with the catch-all kind.
          throw analysisError is GuideError
              ? analysisError
              : GuideError(GuideErrorKind.aiGeneric, message);
        }
      }
      final analysisDuration = DateTime.now().difference(analyzeStart).inMilliseconds;
      _lastAnalysisDurationMs = analysisDuration;
      _progressEstimator.recordAnalyzeDuration(analysisDuration / 1000.0);
      _progressEstimator.stop();

      if (locationContext.city != null && _lastResult != null) {
        _lastResult = AudioGuideResult(
          title: _lastResult!.title,
          script: _lastResult!.script,
          locationName: locationContext.city,
        );
      }

      // Check cancellation before TTS synthesis
      if (cancelToken.isCancelled) {
        _state = GuideState.idle;
        _analysisInProgress = false;
        notifyListeners();
        return null;
      }

      // Skip auto-play if the app was backgrounded while analysis ran — the
      // user may be doing something else by the time it finishes, so
      // starting audio unprompted would be disruptive. The script is kept
      // ready instead, and the "ready" notification below carries the
      // entry ID so tapping it starts playback deliberately. `null`
      // lifecycleState (never set — the case in every test that doesn't
      // simulate backgrounding) is treated as foreground, not backgrounded.
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final isBackgrounded = lifecycle != null && lifecycle != AppLifecycleState.resumed;
      var deferredForBackground = false;

      if (generateAudio && isBackgrounded) {
        deferredForBackground = true;
        await _synthesizeOnlyForBackground(_lastResult!.script, cancelToken: cancelToken);
      } else if (generateAudio) {
        await _synthesizeAndPlay(_lastResult!.script,
            language: language, cancelToken: cancelToken);
      } else {
        _lastAudioPath = null;
        _state = GuideState.scriptReady;
        _progressEstimator.stepProgress = 1.0;
        notifyListeners();
      }

      await _preferencesStore.saveTimings(
        _progressEstimator.gpsDurations,
        _progressEstimator.analyzeDurations,
      );

      await _audioReadyNotifier.notifyReady(
        payload: deferredForBackground ? entryId?.toString() : null,
      );
      return _lastResult;
    } catch (e) {
      _progressEstimator.stop();
      // A real cancellation (T70) lands here too now that cloud calls can
      // actually be aborted mid-flight — treat it like the cooperative
      // isCancelled checks above (back to idle), not a failure. The user
      // asked to stop, so unlike a genuine error (below), this isn't worth
      // a "failed" notification (T85).
      if (e is CancelledException) {
        _state = GuideState.idle;
        _analysisInProgress = false;
        notifyListeners();
        return null;
      }
      _state = GuideState.error;
      _lastGuideError =
          e is GuideError ? e : GuideError(GuideErrorKind.unknown, sanitizeError(e.toString()));
      notifyListeners();
      await _audioReadyNotifier.notifyFailed();
      return null;
    } finally {
      _analysisInProgress = false;
      await _foregroundService.stop();
    }
  }

  /// Synthesizes [script] (cloud TTS with native TTS fallback) and plays
  /// it, driving the synthesizing -> speaking state transition.
  ///
  /// [language] (#130) is applied to the native TTS fallback engine before
  /// speaking — Gemini TTS needs no such hint, it reads the language off
  /// [script]'s own text.
  Future<void> _synthesizeAndPlay(
    String script, {
    String? language,
    required CancelToken cancelToken,
  }) async {
    _prepareNativeTtsLanguage(language);
    _state = GuideState.synthesizing;
    _currentStep = 2;
    _progressEstimator.stepProgress = -1.0;
    notifyListeners();

    // T76's speakChunked() is parked for now (2026-08-16): splitting a
    // script into several Gemini TTS calls reliably hits rate limiting on
    // real accounts, and the fallback-to-native-mid-script it causes is a
    // worse experience than the plain wait speak() gives every user. Back
    // to one call for the whole script until chunking is revisited.
    // speakChunked() and its tests are untouched, ready to swap back in.
    _lastTtsModel = await _ttsOrchestrator.speak(
      script,
      cancelToken: cancelToken,
      geminiTts: _providerManager.geminiTtsForCurrentProvider,
      speed: _playbackSpeed,
    );

    // Cache the generated audio for replay without re-generating — only
    // meaningful when Gemini TTS actually spoke this time. _getLastWavPath()
    // merely checks whether the shared gemini_tts_output.wav file exists on
    // disk, which can be a stale leftover from an *earlier* Gemini TTS call
    // if this one used native TTS instead (e.g. after switching the active
    // provider to local AI) — without this gate, that stale cloud file got
    // wrongly cached as this entry's own audio (#288).
    _lastAudioPath = _lastTtsModel == 'gemini-tts' ? await _getLastWavPath() : null;

    _state = GuideState.speaking;
    _progressEstimator.stepProgress = 1.0;
    notifyListeners();
  }

  /// Synthesizes [script] via Gemini TTS without playing it — used instead
  /// of [_synthesizeAndPlay] when the app is backgrounded at completion
  /// time, so the notification's tap can start playback instantly from the
  /// cached file rather than re-synthesizing from scratch. Only Gemini TTS
  /// is worth pre-generating this way: the native engine synthesizes and
  /// speaks in one live step with no separate "render to file" mode, and
  /// its replay is instant/free anyway (see [_getLastWavPath]'s doc), so
  /// there's nothing to pre-generate for it — the script is simply left
  /// ready, and native TTS will speak it live whenever the user does ask.
  /// Best-effort: a synthesis failure (rate limit, network) just leaves the
  /// script audio-less, same as if Gemini TTS wasn't configured at all.
  ///
  /// #253: gated on the active provider too, same as [_synthesizeAndPlay]
  /// — nothing to pre-generate here when Nano is active either, native
  /// TTS will speak it live on demand just like the foreground path.
  Future<void> _synthesizeOnlyForBackground(
    String script, {
    required CancelToken cancelToken,
  }) async {
    _state = GuideState.synthesizing;
    _progressEstimator.stepProgress = -1.0;
    notifyListeners();

    final geminiTts = _providerManager.geminiTtsForCurrentProvider;
    if (geminiTts != null) {
      try {
        final path = await _getGeminiWavPath();
        await geminiTts.synthesizeToFile(script, path, cancelToken: cancelToken);
        _lastAudioPath = path;
        _lastTtsModel = 'gemini-tts';
      } catch (e) {
        if (e is CancelledException) rethrow;
        AppLogger.error('Background pre-synthesis failed, deferring to on-demand: '
            '${sanitizeError(e.toString())}');
        _lastAudioPath = null;
      }
    } else {
      _lastAudioPath = null;
    }

    _state = GuideState.scriptReady;
    _progressEstimator.stepProgress = 1.0;
    notifyListeners();
  }

  /// Generates and plays audio for an already-analyzed script (T16) —
  /// e.g. an entry created with [analyzeAndPlay]'s `generateAudio: false`,
  /// or any other script-only history entry. Skips GPS/Wikipedia/AI
  /// entirely; only runs the TTS step.
  ///
  /// [language] (#130): history entries don't persist which output
  /// language they were generated with (same as [style] — see
  /// `analysis_runner.dart`), so callers pass the *current* Settings value;
  /// only matters for the native TTS fallback (see [_synthesizeAndPlay]).
  Future<AudioGuideResult?> generateAudioForScript({
    required String title,
    required String script,
    String? locationName,
    String? language,
  }) async {
    if (_analysisInProgress || _state == GuideState.cancelling) {
      _lastGuideError = const GuideError(GuideErrorKind.busyOperation);
      _state = GuideState.error;
      notifyListeners();
      return null;
    }

    _analysisInProgress = true;
    // #322: see the field doc on _cancelToken.
    _cancelToken = CancelToken();
    final cancelToken = _cancelToken;
    await _foregroundService.start();
    await _audioReadyNotifier.requestPermissionIfNeeded();

    try {
      _lastResult = AudioGuideResult(title: title, script: script, locationName: locationName);
      _lastGuideError = null;
      notifyListeners();

      await _synthesizeAndPlay(script, language: language, cancelToken: cancelToken);

      await _audioReadyNotifier.notifyReady();
      return _lastResult;
    } catch (e) {
      if (e is CancelledException) {
        _state = GuideState.idle;
        notifyListeners();
        return null;
      }
      _state = GuideState.error;
      _lastGuideError =
          e is GuideError ? e : GuideError(GuideErrorKind.unknown, sanitizeError(e.toString()));
      notifyListeners();
      await _audioReadyNotifier.notifyFailed();
      return null;
    } finally {
      _analysisInProgress = false;
      await _foregroundService.stop();
    }
  }

  Future<void> togglePause() async {
    // Which engine is actually playing must be checked via lastTtsModel,
    // not just "is Gemini TTS configured" (_geminiTtsService != null) — a
    // configured Gemini TTS can still have fallen back to the native
    // engine for this particular playback (rate limit, network error).
    final geminiIsPlaying =
        _lastTtsModel == 'gemini-tts' && _providerManager.geminiTtsService != null;
    if (_state == GuideState.speaking) {
      if (geminiIsPlaying) {
        await _providerManager.geminiTtsService!.pause();
      } else {
        await _nativeTtsService.pause();
      }
      _state = GuideState.paused;
    } else if (_state == GuideState.paused) {
      if (geminiIsPlaying) {
        // #329: resume() (not a raw channel poke, like before) also
        // resumes GeminiTtsService's own progress estimate.
        await _providerManager.geminiTtsService!.resume();
      } else {
        await _nativeTtsService.resume();
      }
      _state = GuideState.speaking;
    }
    notifyListeners();
  }

  /// T118/T21 — whether skip ±10s is meaningful right now: only true for
  /// the Gemini/cached-WAV engine (see [togglePause]'s same check), since
  /// native TTS's live synthesis has no seekable position. The UI uses
  /// this to hide the skip buttons entirely for native playback rather
  /// than showing a control that would silently do nothing.
  bool get canSkip =>
      (_state == GuideState.speaking || _state == GuideState.paused) &&
      _lastTtsModel == 'gemini-tts' &&
      _providerManager.geminiTtsService != null;

  Future<void> skipForward() async {
    if (!canSkip) return;
    await _providerManager.geminiTtsService!.skipForward();
  }

  Future<void> skipBack() async {
    if (!canSkip) return;
    await _providerManager.geminiTtsService!.skipBack();
  }

  Future<void> cancelCurrentAction() async {
    _progressEstimator.stop();
    _lastGuideError = null;

    // Cancel all ongoing operations. #322: deliberately NOT resetting
    // _analysisInProgress here (it used to be) — analyzeAndPlay()/
    // generateAudioForScript() each clear their own flag in a `finally`
    // once they actually observe the cancellation and return, however
    // long their current await (location resolution, an in-flight AI
    // call...) takes to unwind. Clearing it early let a brand-new
    // analysis start while the old one was still running in the
    // background against the same shared mutable state (_lastResult,
    // _state, _progressEstimator...) — a real race, not just a stale
    // read. isBusy staying true a little longer after Cancel is a safe
    // trade: worst case a new analysis is briefly refused, never two
    // running at once. Same reasoning for not resetting _cancelToken
    // below — each of those methods now creates its own fresh instance
    // per call instead of reusing+resetting this shared field.
    _cancelToken.cancel();

    _state = GuideState.cancelling;
    notifyListeners();

    // Try to stop TTS with a timeout to prevent hanging. Native TTS
    // manages its own playback internally (not the shared
    // audio_guide/audio_player channel Gemini TTS's WAV playback uses),
    // so both need stopping regardless of which one actually played.
    try {
      await Future.wait([
        _nativeTtsService.stop(),
        if (_providerManager.geminiTtsService != null) _providerManager.geminiTtsService!.stop(),
      ]).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Timeout reached, TTS is still running in background but we can proceed
    }

    _state = GuideState.idle;
    notifyListeners();
  }

  Future<void> stop() async {
    await cancelCurrentAction();
  }

  /// Returns the last Gemini-TTS-generated WAV file for caching, if any.
  /// The native engine (T89) plays directly via the device's own TTS
  /// pipeline and doesn't produce a file to cache — its entries are just
  /// re-synthesized on replay, which is fine since it's instant and free,
  /// unlike Gemini TTS's quota-limited cloud calls.
  Future<String?> _getLastWavPath() async {
    try {
      final geminiWav = File(await _getGeminiWavPath());
      if (await geminiWav.exists()) return geminiWav.path;
    } catch (_) {}
    return null;
  }

  /// The conventional path Gemini TTS synthesis writes to, shared by
  /// [_synthesizeAndPlay] (via [GeminiTtsService.speak]/[_getLastWavPath])
  /// and [_synthesizeOnlyForBackground] (via
  /// [GeminiTtsService.synthesizeToFile]) so both land on the same file.
  Future<String> _getGeminiWavPath() async {
    final tmpDir = await getTemporaryDirectory();
    return '${tmpDir.path}/gemini_tts_output.wav';
  }

  @override
  void dispose() {
    _progressEstimator.stop();
    _analysisInProgress = false;
    super.dispose();
  }
}
