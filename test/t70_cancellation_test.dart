import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audiolens/services/audio_guide_service.dart';
import 'package:audiolens/services/gemini_api_service.dart';
import 'package:audiolens/utils/cancel_token.dart';
import 'support/fake_dio_adapter.dart';

/// T70 — the old `http` client + `Future.timeout()` combo stopped the
/// *caller* from waiting on a cancelled request, but left the request
/// itself running in the background to completion. dio's CancelToken
/// actually aborts it. This asserts the abort is real, not just that the
/// caller stops waiting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmpDir = Directory.systemTemp.createTempSync('t70-cancel');
  });
  tearDown(() => tmpDir.deleteSync(recursive: true));

  File tempImage() {
    final f = File('${tmpDir.path}/photo.jpg');
    f.writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
    return f;
  }

  test('cancelling mid-request aborts the call instead of running it to completion',
      () async {
    var requestStarted = false;
    var requestRanToCompletion = false;
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((_) async {
        requestStarted = true;
        await Future.delayed(const Duration(seconds: 5));
        requestRanToCompletion = true; // should never be reached once cancelled
        return (statusCode: 200, body: '{}');
      }),
    );
    final cancelToken = CancelToken();

    final future = service.analyzeImage(tempImage(), cancelToken: cancelToken);
    while (!requestStarted) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
    cancelToken.cancel();

    await expectLater(future, throwsA(isA<CancelledException>()));
    expect(requestRanToCompletion, isFalse);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test(
      'AudioGuideService.cancelCurrentAction() aborts an in-flight analysis '
      '(ends idle, not error)', () async {
    var requestStarted = false;
    final geminiApi = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((_) async {
        requestStarted = true;
        await Future.delayed(const Duration(seconds: 5));
        return (statusCode: 200, body: '{}');
      }),
    );
    final service = AudioGuideService(geminiApiService: geminiApi);
    await service.setActiveProvider(AIProvider.geminiApi);

    final future = service.analyzeAndPlay(tempImage());
    while (!requestStarted) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
    await service.cancelCurrentAction();

    final result = await future;
    expect(result, isNull);
    expect(service.state, GuideState.idle);
    expect(service.lastGuideError, isNull);
  }, timeout: const Timeout(Duration(seconds: 10)));
}
