import 'dart:io';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../screens/map_picker_screen.dart';
import '../screens/player_screen.dart';
import '../services/audio_guide_service.dart';
import '../services/history_service.dart';
import '../services/settings_service.dart';
import 'app_logger.dart';
import 'guide_error_localizer.dart';

/// Runs the full analysis pipeline for [imageFile], persists the result to
/// the [entryId] history entry, and navigates to [PlayerScreen] to show
/// progress. Shared between home_screen.dart (new photo, retry) and
/// history_screen.dart (retry, launching the analysis for a captured
/// entry — T78) so this isn't duplicated per call site.
Future<void> runAnalysisAndNavigate({
  required BuildContext context,
  required File imageFile,
  required int entryId,
  required String source,
  ({double lat, double lon, String source})? knownCoordinates,
  bool deleteImageOnDispose = false,
}) async {
  final guide = context.read<AudioGuideService>();
  final history = context.read<HistoryService>();
  final settings = context.read<SettingsService>();

  // #174: without this, a second attempt always got its own fresh
  // PlayerScreen pushed onto the stack unconditionally — which then
  // immediately hit AudioGuideService's own "already in progress" guard
  // and showed an error, while the *first*, legitimately-in-progress
  // PlayerScreen (still on the stack, still listening to the same
  // shared service instance) also rebuilt on that guard's notifyListeners
  // and could flip to showing the same error, even though its own
  // analysis was still running underneath. Checking here means the
  // second attempt never gets a screen or touches the service at all —
  // entry points are also expected to disable themselves based on
  // guide.isBusy (see home_screen.dart/history_screen.dart), so this is
  // a backstop for whatever slips through (e.g. a fast double-tap before
  // a button's own disabled state has rebuilt).
  if (guide.isBusy) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.guideErrorBusyAnalysis)),
      );
    }
    return;
  }

  // #152/#183: carry over a prior manual rotation (a retry/captured-
  // launch relaunches an existing entry, which may already have one) —
  // absent for a genuinely new capture, where no entry exists yet.
  HistoryEntry? existingEntry;
  for (final e in history.entries) {
    if (e.id == entryId) {
      existingEntry = e;
      break;
    }
  }

  Navigator.push(context, MaterialPageRoute(
    builder: (_) => PlayerScreen(
      imageFile: imageFile,
      deleteImageOnDispose: deleteImageOnDispose,
      rotationQuarters: existingEntry?.rotationQuarters ?? 0,
    ),
  ));

  final result = await guide.analyzeAndPlay(
    imageFile,
    generateAudio: settings.autoGenerateAudio,
    knownCoordinates: knownCoordinates,
    style: settings.scriptStyle,
    language: settings.outputLanguage,
    entryId: entryId,
  );

  AppLogger.info('result: ${result?.title}');
  AppLogger.info('aiModel: ${guide.actualAiModel} / ${guide.lastAiModel}');
  AppLogger.info('gpsSource: ${guide.lastGpsSource}');
  // log-hygiene-ok: this logs only whether GPS resolved (a bool), never
  // the coordinate itself — see T102/T124.
  AppLogger.info('gpsResolved: ${guide.lastGpsLatitude != null}');
  AppLogger.info('wikipedia: ${guide.lastWikipediaUsed}');
  AppLogger.info('duration: ${guide.lastAnalysisDurationMs}');

  if (result != null) {
    await history.completeEntry(
      entryId: entryId,
      title: result.title,
      script: result.script,
      locationName: result.locationName,
      aiModel: guide.actualAiModel ?? guide.lastAiModel,
      analysisSource: source,
      gpsSource: guide.lastGpsSource,
      wikipediaUsed: guide.lastWikipediaUsed,
      analysisDurationMs: guide.lastAnalysisDurationMs,
      gpsLatitude: guide.lastGpsLatitude,
      gpsLongitude: guide.lastGpsLongitude,
      gpsAddress: guide.lastGpsAddress,
      aiFallback: guide.aiModelWasFallback,
      ttsFallback: guide.ttsWasFallback,
      scriptStyle: settings.scriptStyle,
      outputLanguage: settings.outputLanguage,
    );
    final audioPath = guide.lastAudioPath;
    if (audioPath != null) {
      try {
        await history.saveAudioPath(entryId, audioPath, ttsModel: guide.lastTtsModel);
      } on HistoryStorageException catch (e) {
        // The script/title above already saved fine — only the audio
        // cache write failed (T116), so surface it without blocking the
        // rest of the flow.
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  localizeHistoryStorageException(AppLocalizations.of(context)!, e))));
        }
      }
    } else if (guide.state == GuideState.speaking) {
      // TTS actually ran for this entry (native engine, which never
      // produces a cacheable file — see HistoryService.saveTtsModel's doc)
      // — persist which model spoke it even without an audio file (T93).
      // Guarded on GuideState.speaking so a script-only entry (T16) or one
      // deferred while backgrounded (T85) — where TTS never ran at all —
      // doesn't get a stale ttsModel carried over from a previous entry.
      await history.saveTtsModel(entryId, guide.lastTtsModel, ttsFallback: guide.ttsWasFallback);
    }
  } else {
    // Persist whatever location was actually resolved for this attempt
    // (even though the analysis itself failed) so a retry can reuse it —
    // see HistoryService.failEntry's doc.
    await history.failEntry(
      entryId,
      gpsLatitude: guide.lastGpsLatitude,
      gpsLongitude: guide.lastGpsLongitude,
      gpsSource: guide.lastGpsSource,
    );
  }
}

/// Builds [AudioGuideService.analyzeAndPlay]'s `knownCoordinates` param
/// from a history entry's saved GPS fields, if any — shared by every
/// retry/re-launch flow (T78 captured entries, a failed analysis retry) so
/// a previously resolved location (live GPS, EXIF, or a manually picked
/// map point) is reused instead of re-resolving the device's current
/// position from scratch.
({double lat, double lon, String source})? knownCoordinatesFromEntry(HistoryEntry entry) {
  if (entry.gpsLatitude == null || entry.gpsLongitude == null) return null;
  return (
    lat: entry.gpsLatitude!,
    lon: entry.gpsLongitude!,
    source: entry.gpsSource ?? 'realtime',
  );
}

/// Same as [knownCoordinatesFromEntry], but when [entry] has no saved GPS
/// (never resolved at capture time, or the original attempt's own GPS
/// resolution failed — see HistoryService.failEntry's doc), offers
/// picking the real spot on a map instead of silently falling through to
/// the device's *current* real-time position — which could be a
/// different place entirely if time has passed since the original
/// capture/attempt (same rationale as T87's gallery/share map-picker
/// fallback in home_screen.dart, extended here to retry and deferred
/// "captured" launches). Declining the map picker preserves today's
/// behavior: falls through to a fresh real-time GPS resolution.
Future<({double lat, double lon, String source})?> resolveKnownCoordinatesForRelaunch(
  BuildContext context,
  HistoryEntry entry,
) async {
  final known = knownCoordinatesFromEntry(entry);
  if (known != null) return known;
  if (!context.mounted) return null;
  final picked = await Navigator.push<LatLng>(
    context,
    MaterialPageRoute(builder: (_) => const MapPickerScreen()),
  );
  if (picked == null) return null;
  return (lat: picked.latitude, lon: picked.longitude, source: 'map');
}
