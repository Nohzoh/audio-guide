import 'package:flutter_test/flutter_test.dart';
import 'package:audiolens/models/guide_error.dart';

void main() {
  test('GuideError preserves its kind and detail', () {
    const error = GuideError(GuideErrorKind.network);
    expect(error.kind, GuideErrorKind.network);
    expect(error.detail, isNull);
  });

  // #230: every kind that's actually thrown/set somewhere in the app,
  // one enum value per distinct user-facing failure reason.
  test('GuideErrorKind values cover every failure family currently thrown',
      () {
    expect(GuideErrorKind.values, containsAll([
      GuideErrorKind.busyAnalysis,
      GuideErrorKind.busyOperation,
      GuideErrorKind.aiNoProviderConfigured,
      GuideErrorKind.aiBackgroundRestricted,
      GuideErrorKind.aiFallbackBackgroundRestricted,
      GuideErrorKind.aiQuotaExceeded,
      GuideErrorKind.aiModelUnavailable,
      GuideErrorKind.aiServiceUnavailable,
      GuideErrorKind.aiUnusableResponse,
      GuideErrorKind.aiNoModelConfigured,
      GuideErrorKind.network,
      GuideErrorKind.aiGeneric,
      GuideErrorKind.tts,
      GuideErrorKind.storageDiskFull,
      GuideErrorKind.storageWriteFailed,
      GuideErrorKind.storageRotationFailed,
      GuideErrorKind.unknown,
    ]));
  });
}
