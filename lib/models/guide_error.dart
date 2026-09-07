/// #230: a code identifying *why* an analysis/playback/storage operation
/// failed — services throw/set one of these instead of hardcoded prose, so
/// the UI layer (the only place with a `BuildContext`/`AppLocalizations`)
/// can localize it at display time. See `lib/utils/guide_error_localizer.dart`.
enum GuideErrorKind {
  /// analyzeAndPlay() was called while one was already running.
  busyAnalysis,

  /// generateAudioForScript() was called while an operation was already
  /// running.
  busyOperation,

  /// No AI provider configured at all (no API key, no Nano).
  aiNoProviderConfigured,

  /// Gemini Nano requires the app in the foreground; analysis was
  /// attempted directly on Nano (not as a cloud fallback) while
  /// backgrounded.
  aiBackgroundRestricted,

  /// Cloud analysis failed and the on-device Nano fallback also needed
  /// the app in the foreground.
  aiFallbackBackgroundRestricted,

  /// Gemini API: request quota exceeded.
  aiQuotaExceeded,

  /// Gemini API: the configured model is no longer available.
  aiModelUnavailable,

  /// Gemini API: the service is temporarily down.
  aiServiceUnavailable,

  /// Gemini API: every model attempt returned an unusable response.
  aiUnusableResponse,

  /// Gemini API: no model configured to attempt at all.
  aiNoModelConfigured,

  /// Couldn't reach an AI/TTS backend at all (connectivity, timeout).
  network,

  /// Analysis failed for a reason not covered above — [GuideError.detail]
  /// carries a sanitized diagnostic.
  aiGeneric,

  /// Both TTS engines failed — [GuideError.detail] carries a sanitized
  /// diagnostic.
  tts,

  /// Ran out of disk space while saving a photo/audio file.
  storageDiskFull,

  /// A file couldn't be saved for some other reason — [GuideError.detail]
  /// carries a sanitized diagnostic.
  storageWriteFailed,

  /// Saving a manual photo rotation failed.
  storageRotationFailed,

  /// Any other, truly unexpected exception — [GuideError.detail] carries a
  /// sanitized diagnostic.
  unknown,
}

class GuideError implements Exception {
  final GuideErrorKind kind;

  /// Sanitized diagnostic text to interpolate into the localized message
  /// for kinds that need one (see each [GuideErrorKind] value's doc). Null
  /// for fully static kinds.
  final String? detail;

  const GuideError(this.kind, [this.detail]);

  @override
  String toString() => detail == null ? kind.name : '${kind.name}: $detail';
}
