import '../l10n/app_localizations.dart';
import '../services/history_service.dart';
import 'guide_error_localizer.dart';

String formatVoiceUpgradeErrorMessage(Object error, AppLocalizations l10n) {
  // T116: surface the specific storage message rather than the generic
  // fallback below.
  if (error is HistoryStorageException) return localizeHistoryStorageException(l10n, error);

  final message = error.toString().toLowerCase();

  if (message.contains('429') ||
      message.contains('too many requests') ||
      message.contains('rate limit')) {
    return l10n.voiceUpgradeErrorRateLimit;
  }

  return l10n.voiceUpgradeErrorGeneric;
}
