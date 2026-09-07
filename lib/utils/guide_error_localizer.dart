import '../l10n/app_localizations.dart';
import '../models/guide_error.dart';
import '../services/history_service.dart';

/// #230: maps a [GuideErrorKind] to a localized, user-facing message — the
/// only place in the whole error chain that actually has a `BuildContext`
/// to call this from. [detail] is a sanitized diagnostic embedded verbatim
/// (not itself translated) for kinds whose message needs one — see each
/// [GuideErrorKind] value's doc for which ones do.
String localizeGuideErrorKind(
  AppLocalizations l10n,
  GuideErrorKind kind, [
  String? detail,
]) {
  switch (kind) {
    case GuideErrorKind.busyAnalysis:
      return l10n.guideErrorBusyAnalysis;
    case GuideErrorKind.busyOperation:
      return l10n.guideErrorBusyOperation;
    case GuideErrorKind.aiNoProviderConfigured:
      return l10n.guideErrorAiNoProviderConfigured;
    case GuideErrorKind.aiBackgroundRestricted:
      return l10n.guideErrorAiBackgroundRestricted;
    case GuideErrorKind.aiFallbackBackgroundRestricted:
      return l10n.guideErrorAiFallbackBackgroundRestricted;
    case GuideErrorKind.aiQuotaExceeded:
      return l10n.guideErrorAiQuotaExceeded;
    case GuideErrorKind.aiModelUnavailable:
      return l10n.guideErrorAiModelUnavailable;
    case GuideErrorKind.aiServiceUnavailable:
      return l10n.guideErrorAiServiceUnavailable;
    case GuideErrorKind.aiUnusableResponse:
      return l10n.guideErrorAiUnusableResponse;
    case GuideErrorKind.aiNoModelConfigured:
      return l10n.guideErrorAiNoModelConfigured;
    case GuideErrorKind.network:
      return l10n.guideErrorNetwork;
    case GuideErrorKind.aiGeneric:
      return l10n.guideErrorAiGeneric(detail ?? '');
    case GuideErrorKind.tts:
      return l10n.guideErrorTts(detail ?? '');
    case GuideErrorKind.storageDiskFull:
      return l10n.guideErrorStorageDiskFull;
    case GuideErrorKind.storageWriteFailed:
      return l10n.guideErrorStorageWriteFailed(detail ?? '');
    case GuideErrorKind.storageRotationFailed:
      return l10n.guideErrorStorageRotationFailed;
    case GuideErrorKind.unknown:
      // No fixed template for a truly unknown failure — the sanitized
      // diagnostic (already the whole message pre-#230) stands alone.
      return detail ?? l10n.playerUnknownError;
  }
}

String localizeGuideError(AppLocalizations l10n, GuideError error) =>
    localizeGuideErrorKind(l10n, error.kind, error.detail);

String localizeHistoryStorageException(
        AppLocalizations l10n, HistoryStorageException error) =>
    localizeGuideErrorKind(l10n, error.kind, error.detail);
