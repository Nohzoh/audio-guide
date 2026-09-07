import 'package:flutter_test/flutter_test.dart';
import 'package:audiolens/l10n/app_localizations_fr.dart';
import 'package:audiolens/models/guide_error.dart';
import 'package:audiolens/services/history_service.dart';
import 'package:audiolens/utils/user_message_utils.dart';

void main() {
  final l10n = AppLocalizationsFr();

  // #230
  test('surfaces a HistoryStorageException\'s own localized message rather '
      'than the generic fallback', () {
    final message = formatVoiceUpgradeErrorMessage(
      const HistoryStorageException(GuideErrorKind.storageDiskFull),
      l10n,
    );

    expect(message, l10n.guideErrorStorageDiskFull);
  });

  test('formats Gemini 429 errors into a clear user-facing message', () {
    final message = formatVoiceUpgradeErrorMessage(
      Exception(
          'La synthèse vocale a échoué (429). Veuillez réessayer plus tard.'),
      l10n,
    );

    expect(message, contains('temporairement'));
    expect(message.toLowerCase(), contains('réessayez'));
  });

  test('falls back to a generic message for other errors', () {
    final message = formatVoiceUpgradeErrorMessage(Exception('boom'), l10n);

    expect(message, contains('La mise à jour de la voix a échoué'));
  });
}
