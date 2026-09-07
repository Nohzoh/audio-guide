import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:audiolens/screens/home_screen.dart';
import 'package:audiolens/services/audio_guide_service.dart';
import 'package:audiolens/services/history_service.dart';
import 'package:audiolens/services/settings_service.dart';
import 'package:audiolens/utils/whats_new_parser.dart';
import '../support/service_fakes.dart';

/// T105 — smoke-level coverage only for HomeScreen: it's by far the
/// heaviest screen (camera/location/share-intent/T128 update banner),
/// so full interaction coverage is left for a later pass (would need
/// image_picker/geolocator channel mocking beyond this pass's budget).
/// This guards the one thing that matters most for a screen this size:
/// it renders without throwing, with its main CTA visible.
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
const _audioPlayerChannel = MethodChannel('audio_guide/audio_player');
// HomeScreen.initState() subscribes to both of these (share-intent/quick-
// capture warm-start streams) unconditionally — without a stream handler,
// cancelling the subscription at teardown throws MissingPluginException,
// which (being async) surfaces during whichever test runs next rather
// than the one that actually triggered it.
const _shareIntentStreamChannel = EventChannel('audio_guide/share_intent_stream');
const _quickCaptureStreamChannel = EventChannel('audio_guide/quick_capture_stream');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  // Registered once for the whole file, not per-test: these are trivial,
  // stateless no-op handlers, and re-registering them in every setUp/
  // tearDown left a window where a previous test's still-in-flight
  // EventChannel listen/cancel (both async) could fire while no handler
  // was registered, throwing MissingPluginException that got attributed
  // to whichever test happened to be running at that moment.
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(_shareIntentStreamChannel,
            MockStreamHandler.inline(onListen: (_, __) {}, onCancel: (_) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(_quickCaptureStreamChannel,
            MockStreamHandler.inline(onListen: (_, __) {}, onCancel: (_) {}));
  });

  late Directory tmpDir;
  late SettingsService settings;
  late AudioGuideService guide;
  late HistoryService history;
  late List<MethodCall> audioPlayerCalls;
  late Completer<dynamic> playWavCompleter;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('home_screen_test');
    audioPlayerCalls = [];
    playWavCompleter = Completer<dynamic>();
    SharedPreferences.setMockInitialValues({});
    setUpSecureStorageMock();
    // #299: HomeScreen's whats-new check calls PackageInfo.fromPlatform()
    // in a post-frame callback — needs a value or it throws
    // MissingPluginException even for tests that don't care about it.
    PackageInfo.setMockInitialValues(
      appName: 'AudioLens',
      packageName: 'io.nohzoh.audiolens',
      version: '9.9.9',
      buildNumber: '1',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return tmpDir.path;
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_audioPlayerChannel, (call) async {
      audioPlayerCalls.add(call);
      // playWav's real native call only resolves once playback actually
      // finishes (or is stopped) — resolving it immediately here would
      // race HomeScreen's own "played to completion" reset against the
      // test's "now playing" assertions. Never completes on its own;
      // tests that care can resolve it via _completePlayWav().
      if (call.method == 'playWav') return playWavCompleter.future;
      return null;
    });

    settings = SettingsService();
    await settings.init();
    guide = AudioGuideService(nativeTtsService: FakeNativeTts());
    history = HistoryService();
    await history.init(dbPath: '${tmpDir.path}/history.db');
  });

  tearDown(() async {
    tearDownSecureStorageMock();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_audioPlayerChannel, null);
    await tmpDir.delete(recursive: true);
  });

  testWidgets('renders without throwing and shows the "take a photo" CTA',
      (tester) async {
    await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
          const HomeScreen(),
          settings: settings,
          guide: guide,
          history: history,
        )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Prendre une photo'), findsOneWidget);
  });

  // #127 — a "Recently visited" tile with cached audio gets a small
  // play/pause control so its narration can be replayed/paused without
  // opening the detail screen.
  group('play/pause on a "Recently visited" tile with cached audio (#127)', () {
    Future<void> pumpWithCachedAudioEntry(WidgetTester tester) async {
      // Default test surface (800x600) is too short once the grid has a
      // real entry: home_screen.dart's "empty state" hint below the grid
      // is unconditional (not gated on history.entries.isEmpty), and on
      // a viewport this cramped that combination overflows — pre-existing,
      // unrelated to #127, and out of scope here; a taller surface avoids
      // tripping it so this test can focus on play/pause.
      addTearDown(() => tester.view.resetPhysicalSize());
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;

      final placeholder = img.Image(width: 4, height: 4);
      img.fill(placeholder, color: img.ColorRgb8(80, 40, 160));
      final imagePath = '${tmpDir.path}/source.jpg';
      File(imagePath).writeAsBytesSync(img.encodeJpg(placeholder));
      final audioSourcePath = '${tmpDir.path}/source.wav';
      File(audioSourcePath).writeAsBytesSync([0, 1, 2, 3]);

      final entry = await tester.runAsync(() => history.addEntry(
            imagePath: imagePath,
            title: 'Tour Eiffel',
            script: 'Un monument emblematique.',
          ));
      await tester.runAsync(
        () => history.saveAudioPath(entry!.id!, audioSourcePath),
      );

      // #303: these tests don't exercise the whats-new dialog — pre-stamp
      // lastSeenVersion to the mocked PackageInfo version (see setUp) so
      // it doesn't pop up over the play/pause tile these tests tap.
      await settings.recordSeenVersion('9.9.9');

      await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
            const HomeScreen(),
            settings: settings,
            guide: guide,
            history: history,
          )));
      await tester.pumpAndSettle();
    }

    testWidgets('shows a play icon, and tapping it starts cached playback',
        (tester) async {
      await pumpWithCachedAudioEntry(tester);

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();

      expect(audioPlayerCalls.map((c) => c.method), contains('playWav'));
      expect(find.byIcon(Icons.pause), findsOneWidget);
    });

    testWidgets('tapping again while playing pauses instead of restarting',
        (tester) async {
      await pumpWithCachedAudioEntry(tester);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
      audioPlayerCalls.clear();

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();

      expect(audioPlayerCalls.map((c) => c.method), ['pause']);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('tapping the play icon does not navigate to the detail screen',
        (tester) async {
      await pumpWithCachedAudioEntry(tester);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();

      expect(find.text('Prendre une photo'), findsOneWidget);
    });

    // #326 — investigated as a possible bug (icon stuck on "playing" if
    // playback is stopped by something other than tapping this tile, e.g.
    // HistoryDetailScreen.dispose()'s unconditional stop() while browsing
    // history via the app-bar icon rather than this tile). Traced into
    // AudioPlayerPlugin.kt: its "stop" handler always calls
    // resolvePendingPlay() (added for T76), resolving *whichever* playWav
    // call is currently pending regardless of who started it or who calls
    // stop — which is exactly what completes this tile's own .then()
    // callback and resets its state. Confirmed here rather than assumed:
    // the shared setUp() mock doesn't replicate that native resolution on
    // its own, so completing the same completer any other "stop" source
    // would resolve is enough to prove the existing .then() correctly
    // notices and resets, with no code change needed.
    testWidgets('resets correctly when playback is stopped by something '
        'other than the tile itself', (tester) async {
      await pumpWithCachedAudioEntry(tester);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
      expect(find.byIcon(Icons.pause), findsOneWidget);

      await tester.runAsync(() async {
        playWavCompleter.complete(null);
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      await tester.pump();

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });
  });

  // #299
  group('"what\'s new" dialog', () {
    final whatsNewText = File('distribution/whatsnew/whatsnew-fr-FR').readAsStringSync().trim();

    Future<void> pumpHome(WidgetTester tester) async {
      await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
            const HomeScreen(),
            settings: settings,
            guide: guide,
            history: history,
          )));
      await tester.pump();
      // Bounded pumps, not pumpAndSettle — matches this suite's established
      // caution about pumpAndSettle racing an async post-frame callback
      // (PackageInfo.fromPlatform + rootBundle.loadString here) that a full
      // settle can run straight past.
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
    }

    // #303: a bug caught live the first time this shipped — lastSeenVersion
    // being null does NOT by itself mean "fresh install, nothing to show".
    // A fresh install has it stamped by OnboardingScreen on completion
    // (simulated here via recordSeenVersion, since this test bypasses
    // onboarding and goes straight to HomeScreen); an *existing* install
    // updating in from a pre-#299 version also has it null, but for the
    // opposite reason (never recorded — the feature didn't exist yet), and
    // should see the dialog.
    testWidgets('not shown on a fresh install (lastSeenVersion already '
        'stamped to the current version, as OnboardingScreen now does)',
        (tester) async {
      await settings.recordSeenVersion('9.9.9');

      await pumpHome(tester);

      expect(find.text('Nouveautés'), findsNothing);
    });

    testWidgets('shown on a pre-#299 install upgrading in — lastSeenVersion '
        'null because it was never recorded, not because there\'s nothing '
        'to show', (tester) async {
      expect(settings.lastSeenVersion, isNull);

      await pumpHome(tester);

      expect(find.text('Nouveautés'), findsWidgets);
      // #312: lastSeenVersion isn't recorded until the dialog is actually
      // dismissed (see the next test) — it must still be null right after
      // showing, not stamped the moment the dialog goes up.
      expect(settings.lastSeenVersion, isNull);

      await tester.tap(find.text('OK'));
      await tester.pump();
      expect(settings.lastSeenVersion, '9.9.9');
    });

    testWidgets('shown once when the stored last-seen version differs from '
        'the current one, then records the current version only once '
        'dismissed', (tester) async {
      await settings.recordSeenVersion('0.0.1');

      await pumpHome(tester);

      expect(find.text('Nouveautés'), findsWidgets);
      // #(rendering improvement): the dialog now renders each labeled
      // section (Nouveautés/Corrections/Améliorations) as its own Text
      // widget instead of dumping the whole file as one flat paragraph —
      // check each section's content individually rather than the raw
      // whatsNewText string as a single widget.
      for (final section in parseWhatsNewSections(whatsNewText)) {
        expect(find.text(section.content), findsOneWidget);
      }
      // #312 root cause: lastSeenVersion used to be stamped the moment the
      // asset loaded, before the dialog could even show — if the dialog
      // was then lost before the user dismissed it (the actual bug),
      // every later launch's "already seen" check skipped retrying
      // forever, and the user could never actually see it. It must stay
      // at the previous version until dismissal actually happens.
      expect(settings.lastSeenVersion, '0.0.1');
      // #312 diagnostic breadcrumb: recorded as shown as soon as the
      // dialog goes up, dismissed only once OK is actually tapped.
      expect(settings.whatsNewShownVersion, '9.9.9');
      expect(settings.whatsNewDismissedVersion, isNull);

      await tester.tap(find.text('OK'));
      await tester.pump();
      expect(find.text('Nouveautés'), findsNothing);
      expect(settings.whatsNewDismissedVersion, '9.9.9');
      expect(settings.lastSeenVersion, '9.9.9');
    });

    // #312: this is the actual bug — the dialog getting lost/rebuilt away
    // before the user could tap OK (e.g. the startup-timing race with
    // Android's flexible-update restart) used to permanently mark the
    // version "seen" anyway, so the user could never see it again. Now
    // that lastSeenVersion is only recorded on dismissal, a launch that
    // never reaches the dismiss handler must retry on the next one.
    testWidgets('if the dialog never gets dismissed (lost before the user '
        'could tap OK), the next launch shows it again instead of giving '
        'up forever', (tester) async {
      await settings.recordSeenVersion('0.0.1');

      await pumpHome(tester);
      expect(find.text('Nouveautés'), findsWidgets);
      // Simulates the dialog being lost mid-startup — no OK tap, straight
      // to the next launch.

      await pumpHome(tester);

      expect(find.text('Nouveautés'), findsWidgets);
    });

    testWidgets('not shown again once the stored version already matches '
        'the current one', (tester) async {
      await settings.recordSeenVersion('9.9.9');

      await pumpHome(tester);

      expect(find.text('Nouveautés'), findsNothing);
    });

    // #312: a stale "shown but never dismissed" breadcrumb from a
    // different version is purely diagnostic (logged) — it doesn't gate
    // anything, so a genuinely new version still shows normally.
    testWidgets('a leftover undismissed breadcrumb from another version '
        "doesn't block the dialog for the current one", (tester) async {
      await settings.recordSeenVersion('0.0.1');
      await settings.recordWhatsNewShown('0.0.1');
      // Deliberately no recordWhatsNewDismissed('0.0.1') call — simulates
      // #312 itself (shown last time, never confirmed dismissed).

      await pumpHome(tester);

      expect(find.text('Nouveautés'), findsWidgets);
      expect(settings.whatsNewShownVersion, '9.9.9');
    });
  });

  // #309
  group('startup tip', () {
    const firstTipText =
        'Astuce : passez en IA locale dans Réglages pour analyser vos photos '
        'hors connexion, avec une confidentialité maximale.';
    const kofiTipText = 'Si AudioLens vous est utile, un petit coup de pouce '
        'sur Ko-fi aide à faire vivre le projet.';
    const autoPurgeTipText = 'Astuce : activez la purge automatique de '
        "l'historique dans Réglages pour libérer de l'espace.";

    Future<void> pumpHome(WidgetTester tester) async {
      await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
            const HomeScreen(),
            settings: settings,
            guide: guide,
            history: history,
          )));
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('shows the next tip on the 10th launch', (tester) async {
      // Suppresses the whats-new dialog so it doesn't stack with the tip.
      await settings.recordSeenVersion('9.9.9');
      for (var i = 0; i < 9; i++) {
        await settings.incrementLaunchCount();
      }

      await pumpHome(tester);

      expect(find.text(firstTipText), findsOneWidget);
      expect(settings.tipIndex, 1);
    });

    testWidgets('does not show a tip before the 10th launch', (tester) async {
      await settings.recordSeenVersion('9.9.9');
      for (var i = 0; i < 8; i++) {
        await settings.incrementLaunchCount();
      }

      await pumpHome(tester);

      expect(find.text(firstTipText), findsNothing);
    });

    testWidgets('shows nothing when tipsEnabled is false', (tester) async {
      await settings.recordSeenVersion('9.9.9');
      await settings.setTipsEnabled(false);
      for (var i = 0; i < 9; i++) {
        await settings.incrementLaunchCount();
      }

      await pumpHome(tester);

      expect(find.text(firstTipText), findsNothing);
    });

    testWidgets('does not show a tip the same launch as the whats-new dialog',
        (tester) async {
      // lastSeenVersion differs from the mocked current version ('9.9.9'),
      // so the whats-new dialog claims this launch instead.
      await settings.recordSeenVersion('0.0.1');
      for (var i = 0; i < 9; i++) {
        await settings.incrementLaunchCount();
      }

      await pumpHome(tester);

      expect(find.text('Nouveautés'), findsWidgets);
      expect(find.text(firstTipText), findsNothing);
    });

    testWidgets('skips the Ko-fi tip when the Ko-fi button is hidden, '
        'advancing past it to the next one', (tester) async {
      await settings.recordSeenVersion('9.9.9');
      await settings.setShowKofiButton(false);
      await settings.setTipIndex(5); // the Ko-fi slot in _startupTips
      for (var i = 0; i < 9; i++) {
        await settings.incrementLaunchCount();
      }

      await pumpHome(tester);

      expect(find.text(kofiTipText), findsNothing);
      expect(find.text(autoPurgeTipText), findsOneWidget);
      expect(settings.tipIndex, 7);
    });
  });
}
