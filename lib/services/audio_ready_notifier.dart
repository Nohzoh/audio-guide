import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Posts a local notification when a background-eligible analysis
/// finishes (T85) — success ("audio ready") or failure — so a result
/// isn't silently dropped when the user isn't actively watching the app.
/// Best-effort by design, same rationale as [AnalysisForegroundService]:
/// a notification hiccup must never break the actual analysis.
///
/// #230: this can fire from a background/foreground-service context with
/// no active screen at all, so its strings can't go through
/// `AppLocalizations` (needs a `BuildContext`) like the rest of the app's
/// error messages do — resolved directly from the device locale instead,
/// mirroring `SettingsService._resolveAppLanguageDisplayName`'s same
/// fr-or-else-English fallback.
class AudioReadyNotifier {
  static const _channelId = 'analysis_result';
  // #323: was 4202, identical to PlaybackForegroundService.kt's
  // NOTIFICATION_ID (native foreground-service notification with the
  // lock-screen playback controls) — posting this one silently replaced
  // that one whenever both were active at once (a second, earlier-started
  // analysis finishing while a guide was already playing). Also distinct
  // from AnalysisForegroundService.kt's 4201.
  static const _notificationId = 4203;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  bool get _isFrench => ui.PlatformDispatcher.instance.locale.languageCode == 'fr';
  String get _channelName => _isFrench ? 'Résultat de l\'analyse' : 'Analysis result';

  /// Called with the entry ID carried in a "ready" notification's payload
  /// when the user taps it — only set when that entry's playback was
  /// deferred because the app was backgrounded at completion time. The app
  /// process stays alive throughout thanks to the T85 foreground service,
  /// so this plain (foreground) callback is enough — no background isolate
  /// handling needed.
  void Function(int entryId)? onPlayRequested;

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_notification'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final id = int.tryParse(response.payload ?? '');
          if (id != null) onPlayRequested?.call(id);
        },
      );
      _initialized = true;
    } catch (_) {
      // Best-effort — see class doc.
    }
  }

  /// #324: `onDidReceiveNotificationResponse` (wired in [_ensureInitialized])
  /// only fires for a tap received while the plugin is already running —
  /// it never fires for the tap that cold-starts the app (process was
  /// killed while backgrounded, the deferred analysis finished, the
  /// notification posted, and the user's tap is what relaunches the app).
  /// That specific case needs this separate query instead. Returns the
  /// deferred entry ID carried in the notification's payload, or null if
  /// the app wasn't launched this way (the overwhelmingly common case) or
  /// the payload wasn't a valid entry ID (the deliberate "script only",
  /// T16, notification carries none).
  Future<int?> consumeColdStartPayload() async {
    await _ensureInitialized();
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      return int.tryParse(details?.notificationResponse?.payload ?? '');
    } catch (_) {
      // Best-effort — see class doc.
      return null;
    }
  }

  /// Requests the Android 13+ POST_NOTIFICATIONS runtime permission. Safe
  /// to call repeatedly (no-ops once granted or permanently denied) —
  /// intended to be called once, lazily, on the first analysis attempt.
  Future<void> requestPermissionIfNeeded() async {
    await _ensureInitialized();
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Best-effort — see class doc.
    }
  }

  /// [payload], when set, is the ID of a history entry whose playback was
  /// deferred because the app was backgrounded when it finished — tapping
  /// the notification then starts playback for it (see [onPlayRequested]).
  /// Left null for the deliberate "script only" case (T16) — that
  /// notification must not trigger auto-play.
  Future<void> notifyReady({String? payload}) => _show(
        title: 'AudioLens',
        body: payload != null
            ? (_isFrench
                ? 'Votre audioguide est prêt. Touchez pour l\'écouter.'
                : 'Your audio guide is ready. Tap to listen.')
            : (_isFrench ? 'Votre audioguide est prêt.' : 'Your audio guide is ready.'),
        payload: payload,
      );

  Future<void> notifyFailed() => _show(
      title: 'AudioLens', body: _isFrench ? 'L\'analyse a échoué.' : 'The analysis failed.');

  /// Only shows while the user isn't actively looking at the app —
  /// avoids a redundant popup on top of a screen already displaying the
  /// same result.
  Future<void> _show({required String title, required String body, String? payload}) async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    await _ensureInitialized();
    try {
      await _plugin.show(
        id: _notificationId,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: payload,
      );
    } catch (_) {
      // Best-effort — see class doc.
    }
  }
}
