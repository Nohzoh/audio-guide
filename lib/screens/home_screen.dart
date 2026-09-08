import 'dart:async';
import 'dart:io';
import '../utils/analysis_runner.dart';
import '../services/exif_location_service.dart';
import '../l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/app_update_service.dart';
import '../services/audio_guide_service.dart';
import '../services/history_service.dart';
import '../services/location_service.dart';
import '../services/remote_config_service.dart';
import '../services/quick_capture_service.dart';
import '../services/settings_service.dart';
import '../services/share_intent_service.dart';
import '../utils/app_logger.dart';
import '../utils/error_sanitizer.dart';
import '../utils/guide_error_localizer.dart';
import '../utils/whats_new_parser.dart';
import '../widgets/kofi_button.dart';
import 'history_screen.dart';
import 'map_picker_screen.dart';
import 'quiz_screen.dart';
import 'settings_screen.dart';

/// #309 — one entry in the round-robin startup tips list. [isKofi] marks
/// the one slot that promotes Ko-fi support instead of a feature —
/// skipped (not shown at all) if the user has hidden the Ko-fi button
/// elsewhere in Settings, since promoting it in a tip would contradict
/// that choice.
class _StartupTip {
  final String Function(AppLocalizations) text;
  final bool isKofi;
  const _StartupTip(this.text, {this.isKofi = false});
}

final List<_StartupTip> _startupTips = [
  _StartupTip((l10n) => l10n.startupTipLocalAi),
  _StartupTip((l10n) => l10n.startupTipScriptStyle),
  _StartupTip((l10n) => l10n.startupTipFeedbackAnalysis),
  _StartupTip((l10n) => l10n.startupTipSkip),
  _StartupTip((l10n) => l10n.startupTipOutputLanguage),
  _StartupTip((l10n) => l10n.startupTipKofi, isKofi: true),
  _StartupTip((l10n) => l10n.startupTipAutoPurge),
  _StartupTip((l10n) => l10n.startupTipPhotoMode),
  _StartupTip((l10n) => l10n.startupTipHistory),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  LocationPermissionStatus _permissionStatus = LocationPermissionStatus.granted;
  StreamSubscription<String>? _shareIntentSubscription;
  StreamSubscription<void>? _quickCaptureSubscription;
  final _appUpdateService = AppUpdateService();
  bool _updateReady = false;

  // #127: lets a cached narration be paused/resumed directly from a
  // "Recently visited" tile, without opening the detail screen. Scoped
  // to entries with cached audio only (HistoryEntry.hasAudio) — no TTS
  // regeneration risk — and kept local to this grid rather than synced
  // with HistoryDetailScreen's own separate playback state, which has a
  // much larger state machine (live synthesis, native-TTS fallback,
  // skip support) that a 1-2h fix shouldn't take on. The two can't be
  // played at once regardless: AudioPlayerPlugin's MediaPlayer is a
  // single native singleton, so opening the detail screen for any entry
  // stops whatever the grid was playing (see its own dispose()).
  static const _audioPlayerChannel = MethodChannel('audio_guide/audio_player');
  int? _gridPlayingEntryId;
  bool _gridIsPlaying = false;

  Future<void> _stopGridPlaybackIfActive() async {
    if (_gridPlayingEntryId == null) return;
    await _audioPlayerChannel.invokeMethod('stop');
    if (mounted) {
      setState(() {
        _gridPlayingEntryId = null;
        _gridIsPlaying = false;
      });
    }
  }

  Future<void> _toggleGridPlayback(HistoryEntry entry) async {
    if (entry.audioPath == null) return;

    if (_gridPlayingEntryId == entry.id) {
      // Same entry: toggle pause/resume in place.
      await _audioPlayerChannel.invokeMethod(_gridIsPlaying ? 'pause' : 'play');
      if (!mounted) return;
      setState(() => _gridIsPlaying = !_gridIsPlaying);
      return;
    }

    // A different entry (or nothing) was playing — start this one fresh.
    setState(() {
      _gridPlayingEntryId = entry.id;
      _gridIsPlaying = true;
    });
    // Fire-and-forget: this Future only completes once playback finishes
    // (or is stopped), so awaiting it here would block the toggle itself
    // (same non-blocking pattern as HistoryDetailScreen._playCachedAudio).
    _audioPlayerChannel
        .invokeMethod('playWav', {'path': entry.audioPath}).then((_) {
      if (!mounted || _gridPlayingEntryId != entry.id) return;
      setState(() {
        _gridPlayingEntryId = null;
        _gridIsPlaying = false;
      });
    });
  }

  @override
  void initState() {
    super.initState();
    AppLogger.nav('HomeScreen opened');
    WidgetsBinding.instance.addObserver(this);
    _checkLocationPermission();
    _initShareIntentHandling();
    _initQuickCaptureHandling();
    _appUpdateService.onReadyToInstall = () {
      if (mounted) setState(() => _updateReady = true);
    };
    _appUpdateService.checkAndStartUpdate();
    // #299: only reachable post-onboarding (OnboardingScreen owns first
    // launch), so this never fires for a brand-new install's very first
    // session — exactly the "don't show what's-new right after
    // onboarding already explained the app" behavior wanted. Deferred to
    // a post-frame callback since showing a dialog needs a fully built
    // context, not one still inside initState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runStartupAnnouncements());
  }

  /// #309 — the startup tip is a lower-priority announcement than
  /// what's-new: only shown when what's-new didn't already claim this
  /// launch's attention, so the two never stack on top of each other.
  /// The launch counter itself still advances on every launch regardless
  /// (see [SettingsService.incrementLaunchCount]'s own doc), so the ~1-
  /// in-10 cadence tracks real usage frequency rather than "launches
  /// where a tip was possible".
  Future<void> _runStartupAnnouncements() async {
    final settings = context.read<SettingsService>();
    await settings.incrementLaunchCount();
    final showedWhatsNew = await _checkWhatsNew();
    if (!showedWhatsNew && mounted) {
      _checkStartupTip();
    }
  }

  /// #299 — shows what changed since the last version this device saw,
  /// once, never again until the next version bump. Reuses
  /// `distribution/whatsnew/whatsnew-{fr-FR,en-US}` (bundled as assets —
  /// see pubspec.yaml) rather than a separate in-app content source:
  /// those are already hand-written at ship time (the `ship` skill) for
  /// the Play Store listing, capped at 500 chars, user-facing tone.
  ///
  /// `lastSeenVersion == null` is NOT treated as "fresh install, nothing
  /// to show" — a bug caught live (#303) the first time this shipped: a
  /// pre-#299 install updating in has `lastSeenVersion` null too, for a
  /// completely different reason (never recorded, since the feature
  /// didn't exist yet), and that user *should* see it. What actually
  /// distinguishes a genuinely fresh install is that `OnboardingScreen`
  /// stamps `lastSeenVersion` to the version it installed with right as
  /// onboarding completes — so by the time any fresh install reaches
  /// HomeScreen, `lastSeenVersion` already equals `currentVersion` and
  /// this whole method is a no-op for it. Null here can therefore only
  /// mean "this device predates the feature", which warrants showing it.
  /// Returns whether the dialog was actually shown this launch — #309's
  /// startup tip checks this to avoid stacking on top of it.
  Future<bool> _checkWhatsNew() async {
    AppLogger.info('Whats-new: check starting');
    final info = await PackageInfo.fromPlatform();
    if (!mounted) {
      AppLogger.info('Whats-new: unmounted before check could run');
      return false;
    }
    final settings = context.read<SettingsService>();
    final currentVersion = info.version;

    // #312 diagnostic: settings.whatsNewShownVersion/whatsNewDismissedVersion
    // are persisted (unlike AppLogger's in-memory buffer, which never
    // survives the process restart #312 keeps implicating) specifically so
    // a dialog that was shown then lost before the user could dismiss it
    // leaves durable evidence visible in the *next* session's own log.
    final shown = settings.whatsNewShownVersion;
    final dismissed = settings.whatsNewDismissedVersion;
    if (shown != null && shown != dismissed) {
      AppLogger.info(
          'Whats-new: #312 evidence — dialog for $shown was shown in a '
          'previous session but never recorded as dismissed (dismissed: '
          '$dismissed)');
    }

    final lastSeen = settings.lastSeenVersion;
    if (lastSeen == currentVersion) {
      AppLogger.info('Whats-new: already seen $currentVersion, skipping');
      return false;
    }

    final locale = Localizations.localeOf(context).languageCode;
    final assetPath = locale == 'fr'
        ? 'distribution/whatsnew/whatsnew-fr-FR'
        : 'distribution/whatsnew/whatsnew-en-US';
    String? text;
    try {
      text = (await rootBundle.loadString(assetPath)).trim();
    } catch (e) {
      AppLogger.error('Failed to load whats-new asset: ${sanitizeError(e.toString())}');
    }

    if (!mounted || text == null || text.isEmpty) {
      // Nothing was actually shown here — either the asset is missing/
      // corrupt (shouldn't leave the device re-checking, and failing,
      // forever) or the screen went away before the check finished. Only
      // this branch marks the version seen; the success path below defers
      // that to the user actually dismissing the dialog (see #312 below).
      await settings.recordSeenVersion(currentVersion);
      AppLogger.info(
          'Whats-new: not showing for $currentVersion (previously $lastSeen) — text empty or unmounted');
      return false;
    }

    AppLogger.info('Whats-new: showing dialog for $currentVersion (previously $lastSeen)');
    // #312 diagnostic — recorded right before showDialog, not after: if
    // the dialog is shown then lost before the user dismisses it, this
    // is the only trace of that ever having happened (see the check at
    // the top of this method).
    await settings.recordWhatsNewShown(currentVersion);
    if (!mounted) return false;
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      // #306: barrierDismissible defaults to true — a stray tap right as
      // the dialog renders (e.g. the residual touch-up from tapping
      // "Open"/the update notification that just relaunched the app)
      // lands on the barrier and dismisses it before the user can read
      // anything, looking exactly like the dialog "erasing itself".
      // Require an explicit OK instead.
      barrierDismissible: false,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        final sections = parseWhatsNewSections(text!);
        return AlertDialog(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🎧', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.whatsNewTitle),
                    Text(
                      l10n.whatsNewVersionSubtitle(currentVersion),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final section in sections) ...[
                  if (section.label.isNotEmpty) ...[
                    Row(
                      children: [
                        if (section.icon.isNotEmpty) ...[
                          Text(section.icon),
                          const SizedBox(width: 6),
                        ],
                        Text(section.label,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(section.content),
                  if (section != sections.last) const SizedBox(height: 12),
                ],
              ],
            ),
          ),
          actions: [
          TextButton(
            onPressed: () {
              settings.recordWhatsNewDismissed(currentVersion);
              // #312 root cause: this used to be called unconditionally
              // before the dialog ever showed, right after the asset
              // loaded. If the dialog was shown then lost before the user
              // could dismiss it (splashscreen/startup timing race — see
              // this method's own doc history), the version was already
              // marked seen, so every later launch's `lastSeen ==
              // currentVersion` check above skipped retrying forever —
              // the user could never actually see it. Recording seen only
              // here, alongside dismissed, makes the app keep offering
              // the dialog on every launch until the user truly
              // acknowledges it.
              settings.recordSeenVersion(currentVersion);
              Navigator.of(dialogContext).pop();
            },
            child: Text(l10n.commonOk),
          ),
        ],
        );
      },
    );
    return true;
  }

  /// #309 — a discreet startup tip shown roughly every 10th launch,
  /// cycling through [_startupTips] in order (no repeats until the whole
  /// list has cycled). Never shown the same launch as the what's-new
  /// dialog (see [_runStartupAnnouncements]) and entirely opt-out via
  /// [SettingsService.tipsEnabled].
  void _checkStartupTip() {
    final settings = context.read<SettingsService>();
    if (!settings.tipsEnabled) return;
    if (settings.launchCount % 10 != 0) return;

    var index = settings.tipIndex % _startupTips.length;
    var skipped = 0;
    while (_startupTips[index].isKofi &&
        !settings.showKofiButton &&
        skipped < _startupTips.length) {
      index = (index + 1) % _startupTips.length;
      skipped++;
    }
    if (skipped >= _startupTips.length) return;

    final tip = _startupTips[index];
    settings.setTipIndex((index + 1) % _startupTips.length);

    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF3D3418),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.amber.withValues(alpha: 0.4)),
        ),
        // #363: clears the 64dp "Take a photo" CTA (24dp outer padding
        // + its own height) sitting at the very bottom of this screen —
        // 84 landed right on top of it, overlapping on a 3-line tip.
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 100),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('💡', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(child: Text(tip.text(l10n))),
          ],
        ),
        duration: const Duration(seconds: 6),
        action: tip.isKofi
            ? SnackBarAction(
                label: l10n.startupTipKofiAction,
                onPressed: () => launchUrl(
                  Uri.parse('https://ko-fi.com/tarnaud'),
                  mode: LaunchMode.externalApplication,
                ),
              )
            : null,
      ),
    );
  }

  /// #343: gates on the same eligibility [QuizScreen] itself computes
  /// (`hasEnoughQuizEntries`) — checked here too so tapping the icon with
  /// too little history explains why instead of opening an empty/broken
  /// quiz.
  void _openQuiz(BuildContext context, HistoryService history) {
    final l10n = AppLocalizations.of(context)!;
    if (!hasEnoughQuizEntries(history)) {
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.quizNotEnoughEntriesTitle),
          content: Text(l10n.quizNotEnoughEntriesBody(quizMinimumEntries)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.commonOk),
            ),
          ],
        ),
      );
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => const QuizScreen()));
  }

  @override
  void dispose() {
    AppLogger.nav('HomeScreen closed');
    WidgetsBinding.instance.removeObserver(this);
    _shareIntentSubscription?.cancel();
    _quickCaptureSubscription?.cancel();
    _appUpdateService.dispose();
    if (_gridPlayingEntryId != null) {
      _audioPlayerChannel.invokeMethod('stop');
    }
    super.dispose();
  }

  /// T97: picks up a photo shared to AudioLens from another app, both for
  /// a cold start (app launched directly by the share) and a warm start
  /// (app was already running when the share arrived).
  Future<void> _initShareIntentHandling() async {
    final initialPath = await ShareIntentService.getInitialSharedImage();
    if (initialPath != null) await _handleSharedImage(initialPath);
    _shareIntentSubscription =
        ShareIntentService.sharedImageStream.listen(_handleSharedImage);
  }

  Future<void> _handleSharedImage(String path) async {
    if (!mounted) return;
    final imageFile = File(path);
    if (!imageFile.existsSync()) return;
    await _processImageForAnalysis(imageFile, analysisSource: 'share');
  }

  /// Picks up a tap on the home-screen quick-capture widget, both for a
  /// cold start (app launched directly by the widget) and a warm start
  /// (app was already running when it was tapped) — jumps straight to
  /// the camera, same as the "Take a photo" button.
  Future<void> _initQuickCaptureHandling() async {
    final pending = await QuickCaptureService.consumePendingCapture();
    if (pending) await _handleQuickCapture();
    _quickCaptureSubscription =
        QuickCaptureService.captureStream.listen((_) => _handleQuickCapture());
  }

  Future<void> _handleQuickCapture() async {
    if (!mounted) return;
    await _pickImage(ImageSource.camera);
  }

  // Re-check permission when user comes back from settings
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkLocationPermission();
    }
  }

  Future<void> _checkLocationPermission() async {
    final status = await LocationService.checkPermission();
    if (mounted) setState(() => _permissionStatus = status);
  }

  Future<void> _pickImage(ImageSource source, {bool analyzeNow = true}) async {
    final picker = ImagePicker();
    final cfg = RemoteConfigService.current;
    final xFile = await picker.pickImage(
      source: source,
      imageQuality: cfg.imageQuality,
      maxWidth: cfg.imageMaxWidth.toDouble(),
    );
    if (xFile == null || !mounted) return;

    final imageFile = File(xFile.path);

    if (!analyzeNow) {
      await _captureOnly(imageFile);
      return;
    }

    await _processImageForAnalysis(
      imageFile,
      analysisSource: source == ImageSource.camera ? 'camera' : 'gallery',
    );
  }

  /// Processes an image file as an analysis input — shared by the gallery/
  /// camera picker (_pickImage) and incoming shared photos (T97), both of
  /// which need the same "check EXIF, offer the map picker if there's
  /// none, save as a pending entry, launch analysis" flow.
  // T113: a truly pathological file (corrupt, or someone sharing something
  // that isn't really a phone photo) shouldn't be read into memory for
  // EXIF parsing at all — the upload path downscales, but EXIF reading
  // doesn't. 50MB is generously above any real phone camera output.
  static const _maxImageBytes = 50 * 1024 * 1024;

  Future<void> _processImageForAnalysis(
    File imageFile, {
    required String analysisSource, // 'camera' | 'gallery' | 'share'
  }) async {
    final tooLarge = await imageFile.length() > _maxImageBytes;
    if (!mounted) return;
    if (tooLarge) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context)!.homeImageTooLarge)),
      );
      return;
    }
    final history = context.read<HistoryService>();

    // A gallery/shared photo could be old, or from anywhere — unlike a
    // fresh camera capture, falling back to the device's current position
    // when there's no EXIF GPS would be misleading. Offer picking the
    // real spot on a map instead (T87); if declined, behavior is
    // unchanged (LocationContextResolver falls back to real-time GPS).
    ({double lat, double lon, String source})? knownCoordinates;
    if (analysisSource != 'camera') {
      final exifCoords = await ExifLocationService.readGpsFromImage(imageFile);
      if (exifCoords == null && mounted) {
        final picked = await Navigator.push<LatLng>(
          context,
          MaterialPageRoute(builder: (_) => const MapPickerScreen()),
        );
        if (picked != null) {
          knownCoordinates =
              (lat: picked.latitude, lon: picked.longitude, source: 'map');
        }
      }
    }
    if (!mounted) return;

    final HistoryEntry pendingEntry;
    try {
      pendingEntry = await history.addPendingEntry(imagePath: imageFile.path);
    } on HistoryStorageException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                localizeHistoryStorageException(AppLocalizations.of(context)!, e))));
      }
      return;
    }
    await _runAnalysis(
      imageFile: imageFile,
      entryId: pendingEntry.id!,
      source: analysisSource,
      knownCoordinates: knownCoordinates,
      // imageFile is a temp file (image_picker's own capture, or a copy
      // extracted from a share intent) — addPendingEntry already copied
      // it to permanent history storage, so once PlayerScreen is done
      // with it (display + "save to gallery"), it's just an orphaned
      // temp file (T45).
      isTempImage: true,
    );
  }

  /// Saves the photo + raw GPS only — no reverse geocoding, Wikipedia, AI,
  /// or TTS — so the whole capture stays offline (T78). The analysis can
  /// be launched later (e.g. once back on wifi) from the history entry.
  Future<void> _captureOnly(File imageFile) async {
    final history = context.read<HistoryService>();

    final exifCoords = await ExifLocationService.readGpsFromImage(imageFile);
    double? lat = exifCoords?.lat;
    double? lon = exifCoords?.lon;
    var gpsSource = exifCoords != null ? 'exif' : 'none';

    if (exifCoords == null) {
      final raw = await LocationService.getCurrentRawCoordinates();
      if (raw != null) {
        lat = raw.lat;
        lon = raw.lon;
        gpsSource = 'realtime';
      }
      // #327: getCurrentRawCoordinates() collapses every failure reason
      // (permission denied, timeout, no fix) into a plain null, so a
      // denial here otherwise leaves the permission badge showing
      // whatever it last happened to say instead of reflecting reality.
      await _checkLocationPermission();
    }

    try {
      await history.addCapturedEntry(
        imagePath: imageFile.path,
        gpsLatitude: lat,
        gpsLongitude: lon,
        gpsSource: gpsSource,
      );
    } on HistoryStorageException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                localizeHistoryStorageException(AppLocalizations.of(context)!, e))));
      }
      return;
    }

    // imageFile is image_picker's own temp capture — addCapturedEntry
    // already copied it to permanent history storage, and unlike the
    // analyze-now flow, nothing else needs it after this point (T45).
    try {
      if (imageFile.existsSync()) imageFile.deleteSync();
    } catch (_) {}

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.homeCapturedSnackbar),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _showLocationDeniedForeverDialog() {
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.homeLocationDisabledTitle),
        content: Text(l10n.homeLocationDisabledContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.homeLater),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              LocationService.openSettings();
            },
            child: Text(l10n.homeOpenSettings),
          ),
        ],
      ),
    );
  }

  /// Retries a failed analysis, reusing whatever location was resolved for
  /// the original attempt (live GPS, EXIF, or a manually picked map point)
  /// instead of re-resolving the device's current position from scratch —
  /// see HistoryService.failEntry's doc.
  Future<void> _retryAnalysis(HistoryEntry entry) async {
    final imageFile = File(entry.imagePath);
    if (!imageFile.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context)!.homeImageNotFound)),
      );
      return;
    }

    final knownCoordinates =
        await resolveKnownCoordinatesForRelaunch(context, entry);
    if (!mounted) return;
    await _runAnalysis(
      imageFile: imageFile,
      entryId: entry.id!,
      source: 'retry',
      knownCoordinates: knownCoordinates,
    );
  }

  /// Launches the analysis for a captured entry (T78), using the raw GPS
  /// saved at capture time rather than the device's current location.
  Future<void> _launchAnalysisForCaptured(HistoryEntry entry) async {
    final imageFile = File(entry.imagePath);
    if (!imageFile.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context)!.homeImageNotFound)),
      );
      return;
    }

    final knownCoordinates =
        await resolveKnownCoordinatesForRelaunch(context, entry);
    if (!mounted) return;
    await _runAnalysis(
      imageFile: imageFile,
      entryId: entry.id!,
      source: 'captured',
      knownCoordinates: knownCoordinates,
    );
  }

  Future<void> _runAnalysis({
    required File imageFile,
    required int entryId,
    required String source,
    ({double lat, double lon, String source})? knownCoordinates,
    bool isTempImage = false,
  }) async {
    await runAnalysisAndNavigate(
      context: context,
      imageFile: imageFile,
      entryId: entryId,
      source: source,
      knownCoordinates: knownCoordinates,
      deleteImageOnDispose: isTempImage,
    );
    if (mounted) {
      final guide = context.read<AudioGuideService>();
      setState(() => _permissionStatus = guide.lastLocationStatus);
    }
  }

  Future<void> _showImageSourceDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final choice =
        await showModalBottomSheet<({ImageSource source, bool analyzeNow})>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: Text(l10n.homeTakePhoto),
              onTap: () => Navigator.pop(
                  context, (source: ImageSource.camera, analyzeNow: true)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: Text(l10n.homeChooseFromGallery),
              onTap: () => Navigator.pop(
                  context, (source: ImageSource.gallery, analyzeNow: true)),
            ),
            const Divider(height: 24),
            ListTile(
              leading: const Icon(Icons.cloud_off_outlined),
              title: Text(l10n.homeCaptureOnly),
              subtitle: Text(l10n.homeCaptureOnlySubtitle),
              onTap: () => Navigator.pop(
                  context, (source: ImageSource.camera, analyzeNow: false)),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (choice != null) {
      _pickImage(choice.source, analyzeNow: choice.analyzeNow);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    // #236: an explicit style, matching what main.dart's now-removed
    // global AnnotatedRegion used to compute for this screen — needed
    // now that each screen owns its own (see main.dart's `themeMode:`
    // comment for why the shared mechanism was removed).
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: theme.brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                theme.colorScheme.surface,
                theme.colorScheme.surfaceContainerHigh,
              ],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        '🎧 AudioLens',
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Consumer<SettingsService>(
                        // T86: the default grey (Colors.grey[600], chosen to
                        // read as subtly de-emphasized against the plain
                        // AppBars on the other screens) has too little
                        // contrast against this screen's surface gradient —
                        // reported as visibly more washed out than the
                        // history/settings icons right next to it. Matching
                        // their color keeps it readable here without
                        // affecting the other 5 screens.
                        builder: (context, settings, _) => KofiButton(
                          show: settings.showKofiButton,
                          iconColor: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      // #343
                      Consumer<HistoryService>(
                        builder: (context, history, _) => IconButton(
                          icon: const Icon(Icons.quiz_outlined),
                          tooltip: AppLocalizations.of(context)!.quizIconTooltip,
                          onPressed: () => _openQuiz(context, history),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.history),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const HistoryScreen()),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const SettingsScreen()),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // T128: discreet, non-blocking banner shown once a
                  // background-downloaded Play Store update is ready to
                  // install — never a dialog, dismissible, doesn't gate
                  // any other action on this screen.
                  if (_updateReady) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondaryContainer
                            .withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.system_update,
                              size: 18,
                              color: theme.colorScheme.onSecondaryContainer),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              l10n.homeUpdateReadyBanner,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          TextButton(
                            onPressed: () => _appUpdateService.completeUpdate(),
                            child: Text(l10n.homeUpdateRestart),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () =>
                                setState(() => _updateReady = false),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Provider + location status row
                  Row(
                    children: [
                      Consumer<AudioGuideService>(
                        builder: (context, guide, _) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer
                                .withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                guide.activeProvider == AIProvider.geminiNano
                                    ? Icons.phone_android
                                    : Icons.cloud_outlined,
                                size: 14,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                // #253: matches the Settings screen's
                                // provider card label — "IA locale", not
                                // the raw providerName debug string, now
                                // that this option also always guarantees
                                // native (not cloud) TTS.
                                guide.providerName.isEmpty
                                    ? l10n.homeInitializing
                                    : guide.activeProvider ==
                                            AIProvider.geminiNano
                                        ? l10n.settingsLocalAiName
                                        : guide.providerName,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Location status badge
                      if (_permissionStatus ==
                          LocationPermissionStatus.deniedForever)
                        GestureDetector(
                          onTap: _showLocationDeniedForeverDialog,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.location_off,
                                    size: 14, color: Colors.orange),
                                const SizedBox(width: 4),
                                Text(l10n.homeGpsDisabled,
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.orange)),
                              ],
                            ),
                          ),
                        )
                      else if (_permissionStatus ==
                          LocationPermissionStatus.denied)
                        GestureDetector(
                          onTap: () async {
                            await _checkLocationPermission();
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.location_off,
                                    size: 14, color: Colors.orange),
                                const SizedBox(width: 4),
                                Text(l10n.homeGpsAllow,
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.orange)),
                              ],
                            ),
                          ),
                        )
                      else if (_permissionStatus ==
                          LocationPermissionStatus.granted)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.location_on,
                                  size: 14, color: Colors.green),
                              const SizedBox(width: 4),
                              Text(l10n.homeGpsActive,
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.green)),
                            ],
                          ),
                        ),
                    ],
                  ),

                  // History preview
                  Consumer<HistoryService>(
                    builder: (context, history, _) {
                      if (history.entries.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  l10n.homeRecentlyVisited,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.38),
                                  ),
                                ),
                                const Spacer(),
                                GestureDetector(
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => const HistoryScreen()),
                                  ),
                                  child: Text(
                                    l10n.homeSeeAll,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            GridView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                                childAspectRatio: 1.0,
                              ),
                              itemCount: history.entries.take(6).length,
                              itemBuilder: (context, i) {
                                final entry = history.entries[i];
                                final isPending = entry.isPending;
                                final isFailed =
                                    entry.status == AnalysisStatus.failed;
                                final isCaptured = entry.isCaptured;
                                final isDimmed =
                                    isPending || isFailed || isCaptured;
                                return GestureDetector(
                                  key: ValueKey(entry.id),
                                  onTap: () {
                                    if (isPending || isFailed) {
                                      // Retry analysis
                                      _retryAnalysis(entry);
                                    } else if (isCaptured) {
                                      _launchAnalysisForCaptured(entry);
                                    } else {
                                      _stopGridPlaybackIfActive();
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              HistoryDetailScreen(entry: entry),
                                        ),
                                      );
                                    }
                                  },
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        // Image — greyed if pending/failed/captured
                                        ColorFiltered(
                                          colorFilter: isDimmed
                                              ? const ColorFilter.matrix([
                                                  0.2126,
                                                  0.7152,
                                                  0.0722,
                                                  0,
                                                  0,
                                                  0.2126,
                                                  0.7152,
                                                  0.0722,
                                                  0,
                                                  0,
                                                  0.2126,
                                                  0.7152,
                                                  0.0722,
                                                  0,
                                                  0,
                                                  0,
                                                  0,
                                                  0,
                                                  1,
                                                  0,
                                                ])
                                              : const ColorFilter.mode(
                                                  Colors.transparent,
                                                  BlendMode.multiply),
                                          child: File(entry.imagePath)
                                                  .existsSync()
                                              // Square grid cell (childAspectRatio: 1.0
                                              // above), so RotatedBox's width/height
                                              // swap for an odd quarter turn is a no-op.
                                              ? RotatedBox(
                                                  quarterTurns:
                                                      entry.rotationQuarters,
                                                  child: Image.file(
                                                      File(entry.imagePath),
                                                      fit: BoxFit.cover),
                                                )
                                              : Container(
                                                  color: theme.colorScheme
                                                      .surfaceContainerHigh),
                                        ),
                                        // #145: colors below stay hardcoded
                                        // white/black — this overlay sits on
                                        // a photo thumbnail, not themed
                                        // chrome, same as background_photo.dart's
                                        // own scrims.
                                        // Status overlay
                                        if (isPending)
                                          const Center(
                                              child: SizedBox(
                                                  width: 24,
                                                  height: 24,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color:
                                                              Colors.white70)))
                                        else if (isFailed)
                                          const Center(
                                              child: Icon(Icons.refresh,
                                                  color: Colors.white,
                                                  size: 28))
                                        else if (isCaptured)
                                          const Center(
                                              child: Icon(
                                                  Icons.cloud_off_outlined,
                                                  color: Colors.white70,
                                                  size: 28)),
                                        // #127: play/pause the cached
                                        // narration in place — only where
                                        // there's a cached file to play
                                        // without re-triggering TTS.
                                        if (!isDimmed &&
                                            entry.audioPath != null)
                                          Positioned(
                                            top: 2,
                                            right: 2,
                                            child: Tooltip(
                                              message: _gridPlayingEntryId ==
                                                          entry.id &&
                                                      _gridIsPlaying
                                                  ? l10n.homeGridPauseTooltip
                                                  : l10n.homeGridPlayTooltip,
                                              child: GestureDetector(
                                                onTap: () =>
                                                    _toggleGridPlayback(entry),
                                                // #128: bumped from a 22px hit area toward
                                                // the 48x48 touch-target guideline — kept
                                                // below 48 since this is a small badge
                                                // overlaid on a grid thumbnail, not a
                                                // standalone control.
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.all(9),
                                                  decoration:
                                                      const BoxDecoration(
                                                    color: Colors.black45,
                                                    shape: BoxShape.circle,
                                                  ),
                                                  child: Icon(
                                                    _gridPlayingEntryId ==
                                                                entry.id &&
                                                            _gridIsPlaying
                                                        ? Icons.pause
                                                        : Icons.play_arrow,
                                                    color: Colors.white,
                                                    size: 18,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        // Title at bottom
                                        Positioned(
                                          bottom: 0,
                                          left: 0,
                                          right: 0,
                                          child: Container(
                                            padding: const EdgeInsets.all(4),
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.bottomCenter,
                                                end: Alignment.topCenter,
                                                colors: [
                                                  Colors.black
                                                      .withValues(alpha: 0.7),
                                                  Colors.transparent
                                                ],
                                              ),
                                            ),
                                            child: Text(
                                              isFailed
                                                  ? l10n.homeTapToRetry
                                                  : isCaptured
                                                      ? l10n.homeTapToAnalyze
                                                      : entry.title,
                                              style: TextStyle(
                                                color: isFailed
                                                    ? Colors.orangeAccent
                                                    : isCaptured
                                                        ? Colors.white70
                                                        : Colors.white,
                                                fontSize: 9,
                                                height: 1.2,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.camera_alt_outlined,
                              size: 80,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.12)),
                          const SizedBox(height: 16),
                          Text(
                            l10n.homeEmptyStateHint,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.38),
                                fontSize: 15,
                                height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // #174: scoped to just this button (not a top-level
                  // watch) so the rest of the screen — including the
                  // "Recently visited" grid — doesn't rebuild on every
                  // AudioGuideService change. Disabled while an analysis
                  // is already running: nothing here blocked a second
                  // capture from being triggered before, which always
                  // pushed its own PlayerScreen straight into the
                  // service's existing "already in progress" guard.
                  Consumer<AudioGuideService>(
                    builder: (context, guide, _) => FilledButton.icon(
                      onPressed: guide.isBusy ? null : _showImageSourceDialog,
                      icon: const Icon(Icons.camera_alt, size: 24),
                      label: Text(l10n.homeTakePhoto,
                          style: const TextStyle(fontSize: 18)),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 64),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                      ),
                    ),
                  ).animate().scale(delay: 200.ms),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
