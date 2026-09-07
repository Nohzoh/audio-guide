import 'package:flutter_test/flutter_test.dart';
import 'package:audiolens/l10n/app_localizations_fr.dart';
import 'package:audiolens/l10n/app_localizations_en.dart';
import 'package:audiolens/models/guide_error.dart';
import 'package:audiolens/services/history_service.dart';
import 'package:audiolens/utils/guide_error_localizer.dart';

/// #230: services throw/set a [GuideErrorKind] code, not prose — this is
/// the one place that maps every kind to an actual user-facing message,
/// so it's the one place that needs to cover every kind explicitly (a
/// forgotten `case` would otherwise only surface as a blank/wrong message
/// in the app itself, not a build failure — the enum's `switch` is
/// exhaustive, but the *content* of each branch isn't checked by the
/// compiler).
void main() {
  final fr = AppLocalizationsFr();
  final en = AppLocalizationsEn();

  test('every fully static kind localizes to a non-empty, distinct message '
      'in both languages', () {
    const staticKinds = [
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
      GuideErrorKind.storageDiskFull,
      GuideErrorKind.storageRotationFailed,
    ];

    final seenFr = <String>{};
    for (final kind in staticKinds) {
      final frMessage = localizeGuideErrorKind(fr, kind);
      final enMessage = localizeGuideErrorKind(en, kind);
      expect(frMessage, isNotEmpty, reason: '$kind (fr)');
      expect(enMessage, isNotEmpty, reason: '$kind (en)');
      expect(frMessage, isNot(enMessage), reason: '$kind should actually translate');
      expect(seenFr.add(frMessage), isTrue,
          reason: '$kind produced a message already used by another kind');
    }
  });

  test('aiGeneric/tts/storageWriteFailed embed the raw detail verbatim', () {
    expect(localizeGuideErrorKind(fr, GuideErrorKind.aiGeneric, 'boom'),
        contains('boom'));
    expect(localizeGuideErrorKind(fr, GuideErrorKind.tts, 'boom'), contains('boom'));
    expect(localizeGuideErrorKind(fr, GuideErrorKind.storageWriteFailed, 'boom'),
        contains('boom'));
  });

  test('unknown returns the detail verbatim, with no fixed template', () {
    expect(localizeGuideErrorKind(fr, GuideErrorKind.unknown, 'raw diagnostic'),
        'raw diagnostic');
  });

  test('unknown with no detail falls back to the generic unknown-error string', () {
    expect(localizeGuideErrorKind(fr, GuideErrorKind.unknown), fr.playerUnknownError);
  });

  test('localizeGuideError delegates to the GuideError\'s own kind/detail', () {
    const error = GuideError(GuideErrorKind.tts, 'timeout');
    expect(localizeGuideError(fr, error), contains('timeout'));
    expect(localizeGuideError(fr, error), fr.guideErrorTts('timeout'));
  });

  test('localizeHistoryStorageException delegates to its own kind/detail', () {
    const error = HistoryStorageException(GuideErrorKind.storageDiskFull);
    expect(
        localizeHistoryStorageException(fr, error), fr.guideErrorStorageDiskFull);
  });
}
