import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audiolens/services/ai_service.dart';
import 'package:audiolens/services/audio_guide_service.dart';
import 'package:audiolens/services/gemini_api_service.dart';
import 'package:audiolens/services/gemini_nano_service.dart';
import 'package:audiolens/services/gemini_tts_service.dart';
import 'package:audiolens/services/native_tts_service.dart';
import 'package:audiolens/models/guide_error.dart';
import 'package:audiolens/utils/cancel_token.dart';
import 'support/fake_dio_adapter.dart';
import 'support/service_fakes.dart' show setUpSecureStorageMock, tearDownSecureStorageMock;

class _FakeNativeTts extends NativeTtsService {
  bool speakCalled = false;

  @override
  Future<void> speak(String text, {CancelToken? cancelToken, double speed = 1.0}) async {
    speakCalled = true;
    onComplete?.call();
  }
}

class _FakeGeminiTts extends GeminiTtsService {
  _FakeGeminiTts({required this.fail}) : super(apiKey: 'test-key');

  final bool fail;
  bool speakCalled = false;

  @override
  Future<void> speak(String text, {CancelToken? cancelToken, double speed = 1.0}) async {
    speakCalled = true;
    if (fail) {
      throw Exception('Gemini TTS 429');
    }
  }
}

class _FakeNano extends GeminiNanoService {
  _FakeNano({required this.available, this.throwBackgroundRestricted = false});

  final bool available;
  final bool throwBackgroundRestricted;
  bool analyzeCalled = false;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> initialize() async {}

  @override
  Future<AudioGuideResult> analyzeImage(
    File imageFile, {
    String? locationContext,
    CancelToken? cancelToken,
    String? style,
    String? language,
  }) async {
    analyzeCalled = true;
    if (throwBackgroundRestricted) {
      throw const GeminiNanoBackgroundRestrictedException();
    }
    return const AudioGuideResult(
      title: 'Nano',
      script: 'Script local de secours.',
    );
  }
}

String _successJson() => jsonEncode({
  'candidates': [
    {
      'content': {
        'parts': [
          {
            'text':
                '{"title": "La Joconde", "script": "Bienvenue devant ce chef-d\'oeuvre."}',
          },
        ],
      },
    },
  ],
});

GeminiApiService _successApi() => GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((_) async => (statusCode: 200, body: _successJson())),
    );

GeminiApiService _failingApi() => GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio(
        (_) async => (statusCode: 429, body: jsonEncode({'error': {'message': 'quota'}})),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmpDir = Directory.systemTemp.createTempSync('fallback-orchestration');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  File tempImage() {
    final f = File('${tmpDir.path}/photo.jpg');
    f.writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
    return f;
  }

  test('Gemini TTS failure -> falls back to native TTS and flags ttsWasFallback', () async {
    final native = _FakeNativeTts();
    final geminiTts = _FakeGeminiTts(fail: true);
    final service = AudioGuideService(
      nativeTtsService: native,
      geminiTtsService: geminiTts,
      geminiApiService: _successApi(),
    );
    await service.setActiveProvider(AIProvider.geminiApi);

    final result = await service.analyzeAndPlay(tempImage());

    expect(result, isNotNull);
    expect(geminiTts.speakCalled, isTrue);
    expect(native.speakCalled, isTrue);
    expect(service.lastTtsModel, 'native-tts');
    expect(service.ttsWasFallback, isTrue);
    expect(service.state, GuideState.speaking);
  });

  test('Gemini TTS success -> no fallback, ttsWasFallback false', () async {
    final native = _FakeNativeTts();
    final geminiTts = _FakeGeminiTts(fail: false);
    final service = AudioGuideService(
      nativeTtsService: native,
      geminiTtsService: geminiTts,
      geminiApiService: _successApi(),
    );
    await service.setActiveProvider(AIProvider.geminiApi);

    await service.analyzeAndPlay(tempImage());

    expect(geminiTts.speakCalled, isTrue);
    expect(native.speakCalled, isFalse);
    expect(service.lastTtsModel, 'gemini-tts');
    expect(service.ttsWasFallback, isFalse);
  });

  test('Cloud AI failure -> falls back to local Gemini Nano', () async {
    final nano = _FakeNano(available: true);
    final service = AudioGuideService(
      geminiTtsService: _FakeGeminiTts(fail: false),
      geminiApiService: _failingApi(),
      nanoService: nano,
    );
    await service.init();
    await service.setActiveProvider(AIProvider.geminiApi);

    final result = await service.analyzeAndPlay(tempImage());

    expect(result, isNotNull);
    expect(nano.analyzeCalled, isTrue);
    expect(result!.script, 'Script local de secours.');
    // T132: this fallback is per-analysis only — the active provider must
    // NOT permanently switch, or every later analysis in the session would
    // silently and invisibly get stuck on Nano even after the cloud API
    // recovers.
    expect(service.activeProvider, AIProvider.geminiApi);
    expect(service.aiModelWasFallback, isTrue);
    expect(service.actualAiModel, 'Gemini Nano');
  });

  test('Cloud AI failure -> Nano fallback, then a later analysis retries the '
      'same session\'s cloud API fresh instead of staying stuck on Nano '
      '(T132)', () async {
    // Fails every model on the first analysis (exhausting GeminiApiService's
    // own internal per-model fallback list, so it throws up to
    // AudioGuideService and triggers the Nano fallback), succeeds on the
    // second — simulates a transient cloud hiccup that clears up before
    // the next analysis.
    var callCount = 0;
    const modelsPerAttempt = 3; // matches RemoteConfigService's default fallback list
    final api = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((_) async {
        callCount++;
        if (callCount <= modelsPerAttempt) {
          return (statusCode: 429, body: jsonEncode({'error': {'message': 'quota'}}));
        }
        return (statusCode: 200, body: _successJson());
      }),
    );
    final nano = _FakeNano(available: true);
    final service = AudioGuideService(
      geminiTtsService: _FakeGeminiTts(fail: false),
      geminiApiService: api,
      nanoService: nano,
    );
    await service.init();
    await service.setActiveProvider(AIProvider.geminiApi);

    final first = await service.analyzeAndPlay(tempImage());
    expect(first, isNotNull);
    expect(nano.analyzeCalled, isTrue);
    expect(service.aiModelWasFallback, isTrue);
    expect(service.activeProvider, AIProvider.geminiApi);

    nano.analyzeCalled = false;
    final second = await service.analyzeAndPlay(tempImage());

    expect(second, isNotNull);
    // The second analysis must go straight back to the cloud API — not
    // silently reuse Nano just because the first call happened to fall
    // back to it.
    expect(nano.analyzeCalled, isFalse);
    expect(service.aiModelWasFallback, isFalse);
  });

  test('GPS refused -> analysis still completes with gpsSource none', () async {
    final service = AudioGuideService(
      geminiTtsService: _FakeGeminiTts(fail: false),
      geminiApiService: _successApi(),
    );
    await service.setActiveProvider(AIProvider.geminiApi);

    final result = await service.analyzeAndPlay(tempImage());

    expect(result, isNotNull);
    expect(service.lastGpsSource, 'none');
    expect(service.lastGpsLatitude, isNull);
    expect(service.lastGpsLongitude, isNull);
    expect(service.state, GuideState.speaking);
  });

  test('Gemini Nano rejects background usage -> clear, actionable error message',
      () async {
    final nano = _FakeNano(available: true, throwBackgroundRestricted: true);
    final service = AudioGuideService(
      geminiTtsService: _FakeGeminiTts(fail: false),
      nanoService: nano,
    );
    await service.init();
    await service.setActiveProvider(AIProvider.geminiNano);

    final result = await service.analyzeAndPlay(tempImage());

    expect(result, isNull);
    expect(service.state, GuideState.error);
    expect(service.lastGuideError?.kind, GuideErrorKind.aiBackgroundRestricted);
  });

  test(
      'Cloud AI failure -> Nano fallback also rejects background usage -> '
      'clear error, not the raw native message', () async {
    final nano = _FakeNano(available: true, throwBackgroundRestricted: true);
    final service = AudioGuideService(
      geminiTtsService: _FakeGeminiTts(fail: false),
      geminiApiService: _failingApi(),
      nanoService: nano,
    );
    await service.init();
    await service.setActiveProvider(AIProvider.geminiApi);

    final result = await service.analyzeAndPlay(tempImage());

    expect(result, isNull);
    expect(nano.analyzeCalled, isTrue);
    expect(service.state, GuideState.error);
    expect(service.lastGuideError?.kind, GuideErrorKind.aiFallbackBackgroundRestricted);
  });

  test('No AI service available -> clear error, no crash', () async {
    final service = AudioGuideService(
      geminiTtsService: _FakeGeminiTts(fail: false),
    );
    await service.setActiveProvider(AIProvider.geminiApi);

    final result = await service.analyzeAndPlay(tempImage());

    expect(result, isNull);
    expect(service.state, GuideState.error);
    expect(service.lastGuideError?.kind, GuideErrorKind.aiNoProviderConfigured);
  });

  // #253 — reported live: picking Nano specifically to keep everything
  // on-device still silently spoke through the cloud whenever an API key
  // happened to be configured too (e.g. left over from trying the cloud
  // provider earlier). TTS must follow the active provider, not just "is
  // a Gemini TTS instance configured at all".
  test('Nano active with a Gemini API key configured -> speaks via native TTS, '
      'not the cloud', () async {
    final native = _FakeNativeTts();
    final geminiTts = _FakeGeminiTts(fail: false);
    final nano = _FakeNano(available: true);
    final service = AudioGuideService(
      nativeTtsService: native,
      geminiTtsService: geminiTts,
      geminiApiService: _successApi(),
      nanoService: nano,
    );
    await service.init(); // resolves Nano availability
    await service.setActiveProvider(AIProvider.geminiNano);

    final result = await service.analyzeAndPlay(tempImage());

    expect(result, isNotNull);
    expect(nano.analyzeCalled, isTrue);
    expect(native.speakCalled, isTrue);
    expect(geminiTts.speakCalled, isFalse);
    expect(service.lastTtsModel, 'native-tts');
  });

  // #298: isReady used to be hardcoded `true`, which silently made
  // main.dart's onboarding routing dead code (the condition
  // `guide.isReady || settings.isOnboardingComplete` was always true) —
  // it now reflects whether an AI provider is actually usable.
  group('isReady (#298)', () {
    setUp(setUpSecureStorageMock);
    tearDown(tearDownSecureStorageMock);

    test('false when neither Nano nor a Gemini API key is available', () async {
      final service = AudioGuideService(nanoService: _FakeNano(available: false));
      await service.init();

      expect(service.isReady, isFalse);
    });

    test('true when Nano is available, even with no API key', () async {
      final service = AudioGuideService(nanoService: _FakeNano(available: true));
      await service.init();

      expect(service.isReady, isTrue);
    });

    test('true when a Gemini API key is configured, even without Nano', () async {
      final service = AudioGuideService(nanoService: _FakeNano(available: false));
      await service.init();
      expect(service.isReady, isFalse);

      await service.setGeminiApiKey('AIza-test-key');

      expect(service.isReady, isTrue);
    });
  });
}
