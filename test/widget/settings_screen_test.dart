import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:audiolens/screens/settings_screen.dart';
import 'package:audiolens/services/audio_guide_service.dart';
import 'package:audiolens/services/feedback_service.dart';
import 'package:audiolens/services/history_service.dart';
import 'package:audiolens/services/settings_service.dart';
import '../support/service_fakes.dart';

// #315: HistoryService.addPendingEntry/addEntry copy the source image to
// permanent storage via path_provider — needs a mock or MissingPluginException.
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// T105 — first widget-level coverage for SettingsScreen. Deliberately
/// skips tapping "View source code" / "Get a free key" (external
/// url_launcher calls) — out of scope for this pass, avoids adding a
/// url_launcher_platform_interface fake for marginal value.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  late Directory tmpDir;
  late SettingsService settings;
  late AudioGuideService guide;
  late HistoryService history;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('settings_screen_test');
    SharedPreferences.setMockInitialValues({});
    setUpSecureStorageMock();
    PackageInfo.setMockInitialValues(
      appName: 'AudioLens',
      packageName: 'io.nohzoh.audiolens',
      version: '0.1.5',
      buildNumber: '42',
      buildSignature: '',
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return tmpDir.path;
      // #328: imagePathWithExifStripped writes its stripped copy here.
      if (call.method == 'getTemporaryDirectory') return tmpDir.path;
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
    await tmpDir.delete(recursive: true);
  });

  Widget wrapScreen() => wrapWithProviders(
        const SettingsScreen(),
        settings: settings,
        guide: guide,
        history: history,
      );

  testWidgets('renders both provider cards, local AI active-by-default and Gemini API locked',
      (tester) async {
    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    // #253: "IA locale", not the "Gemini Nano" brand name.
    expect(find.text('IA locale'), findsOneWidget);
    expect(find.text('Gemini API'), findsOneWidget);
    // AudioGuideService defaults activeProvider to geminiNano even though
    // nanoAvailable is false for a fresh instance — that's existing app
    // behavior, not something this test changes. Gemini API has no key,
    // so it's the one shown locked.
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  // #278: tapping the locked "Gemini API" card used to do nothing (onTap
  // was null while no key was saved) — the only way to discover the key
  // field existed was to scroll past it by chance. It now scrolls the key
  // section into view and focuses the field instead.
  testWidgets('tapping the locked Gemini API card focuses the API key field',
      (tester) async {
    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    expect(guide.geminiApiKey, anyOf(isNull, isEmpty));
    final apiKeyField = tester.widget<TextField>(find.byType(TextField));
    expect(apiKeyField.focusNode?.hasFocus, isFalse);

    await tester.tap(find.text('Gemini API'));
    await tester.pumpAndSettle();

    final focusedField = tester.widget<TextField>(find.byType(TextField));
    expect(focusedField.focusNode?.hasFocus, isTrue);
  });

  // #283: the "IA locale" card used to show a generic "(non configuré)"
  // suffix regardless of *why* Nano wasn't usable — including when the
  // device simply doesn't support AICore, which isn't something the user
  // configured or can fix. SettingsScreen queries
  // GeminiNanoService.checkDeviceStatus() (over the same platform channel
  // AudioGuideService's real nanoService uses) in initState to show the
  // right reason instead.
  const nanoChannel = MethodChannel('audio_guide/gemini_nano');

  testWidgets('shows a device-support message when Nano is hardware/OS unavailable',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nanoChannel, (call) async {
      if (call.method == 'checkNanoStatus') return 'unavailable';
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nanoChannel, null));

    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    expect(find.textContaining("ne prend pas en charge l'IA locale"), findsOneWidget);
  });

  testWidgets('shows a download-pending message when Nano is downloadable but not yet ready',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nanoChannel, (call) async {
      if (call.method == 'checkNanoStatus') return 'downloadable';
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nanoChannel, null));

    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    expect(find.textContaining('Modèle IA non téléchargé'), findsOneWidget);
  });

  // #325: guide (constructed above, never guide.init()-ed) starts with
  // nanoAvailable false and no other path in this test to change that —
  // proving the card only unlocks because initState() explicitly
  // re-resolves it, not because init() happened to run first.
  testWidgets("unlocks the Local AI card once Nano's availability check "
      'resolves (refreshNanoAvailability)', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nanoChannel, (call) async {
      switch (call.method) {
        case 'checkNanoStatus':
          return 'available';
        case 'isAvailable':
          return true;
        case 'initialize':
          return null;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nanoChannel, null));

    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    final tile = tester.widget<ListTile>(find.ancestor(
      of: find.text('IA locale'),
      matching: find.byType(ListTile),
    ));
    expect(tile.onTap, isNotNull);
    expect(guide.nanoAvailable, isTrue);
  });

  // #294: the feedback button only exists on a build that actually has
  // TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID baked in (a real CI build) —
  // wrapScreen()'s plain FeedbackService() is always unconfigured here,
  // since a `flutter test` run never passes --dart-define.
  testWidgets('hides the feedback button when FeedbackService is not configured',
      (tester) async {
    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    expect(find.text('Envoyer un feedback'), findsNothing);
  });

  group('feedback dialog (#294)', () {
    Widget wrapConfiguredScreen(http.Client client) => wrapWithProviders(
          SettingsScreen(
            feedbackService:
                FeedbackService(botToken: '123:ABC', chatId: '-100999', client: client),
          ),
          settings: settings,
          guide: guide,
          history: history,
        );

    testWidgets('shows an attach-screenshot button (#296)', (tester) async {
      final client = MockClient((request) async => http.Response('{"ok":true}', 200));

      await tester.pumpWidget(wrapConfiguredScreen(client));
      await tester.pumpAndSettle();

      final button = find.text('Envoyer un feedback');
      await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(find.text("Joindre une capture d'écran"), findsOneWidget);
    });

    testWidgets('shows the button, and a successful send closes the dialog '
        'with a confirmation snackbar', (tester) async {
      Map<String, String>? sentFields;
      final client = MockClient((request) async {
        sentFields = request.bodyFields;
        return http.Response('{"ok":true}', 200);
      });

      await tester.pumpWidget(wrapConfiguredScreen(client));
      await tester.pumpAndSettle();

      final button = find.text('Envoyer un feedback');
      await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Ça plante au lancement');
      await tester.tap(find.widgetWithText(FilledButton, 'Envoyer'));
      // Bounded pumps, not pumpAndSettle — the SnackBar has its own timed
      // dismissal, and settling would run straight past its display
      // window (matches this suite's established caution elsewhere about
      // pumpAndSettle racing timed/async UI).
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      await tester.pump();

      expect(sentFields?['text'], contains('Ça plante au lancement'));
      expect(find.text('Feedback envoyé, merci !'), findsOneWidget);
    });

    testWidgets('shows an inline error and keeps the dialog open on failure',
        (tester) async {
      final client = MockClient((request) async => http.Response('error', 500));

      await tester.pumpWidget(wrapConfiguredScreen(client));
      await tester.pumpAndSettle();

      final button = find.text('Envoyer un feedback');
      await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Test');
      await tester.tap(find.widgetWithText(FilledButton, 'Envoyer'));
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      await tester.pump();

      expect(find.text("L'envoi a échoué. Réessayez plus tard."), findsOneWidget);
      // Dialog stayed open — the text field is still there to retry from.
      expect(find.byType(TextField), findsOneWidget);
    });

    // #315
    testWidgets('shows an attach-analysis button, and selecting one from '
        'history attaches its photo, script, and analysis details',
        (tester) async {
      final placeholder = img.Image(width: 4, height: 4);
      img.fill(placeholder, color: img.ColorRgb8(80, 40, 160));
      final imagePath = '${tmpDir.path}/analysis.jpg';
      File(imagePath).writeAsBytesSync(img.encodeJpg(placeholder));

      final entry =
          await tester.runAsync(() => history.addPendingEntry(imagePath: imagePath));
      await tester.runAsync(() => history.completeEntry(
            entryId: entry!.id!,
            title: 'Tour Eiffel',
            script: 'Un monument emblematique construit en 1889.',
            aiModel: 'gemini-3.5-flash',
            analysisSource: 'camera',
          ));

      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"ok":true}', 200);
      });

      await tester.pumpWidget(wrapConfiguredScreen(client));
      await tester.pumpAndSettle();

      final button = find.text('Envoyer un feedback');
      await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(find.text('Joindre une analyse'), findsOneWidget);
      await tester.tap(find.text('Joindre une analyse'));
      await tester.pumpAndSettle();

      expect(find.text('Choisir une analyse'), findsOneWidget);
      await tester.tap(find.text('Tour Eiffel'));
      await tester.pumpAndSettle();

      // Selected — the button relabels and a thumbnail appears.
      expect(find.text("Changer l'analyse"), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Le titre est faux');
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Envoyer'));
        // A multipart send (sendPhoto) resolves through MockClient's
        // streamed response, which needs more turns than the single
        // microtask a plain sendMessage POST does — poll briefly instead
        // of a single Future.delayed(Duration.zero).
        for (var i = 0; i < 20 && requests.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      await tester.pump();

      expect(requests, hasLength(1));
      final request = requests.single as http.Request;
      // Sent via sendPhoto (the entry's own photo), not sendMessage.
      expect(request.url.toString(), contains('/sendPhoto'));
      final body = latin1.decode(request.bodyBytes);
      expect(body, contains('Le titre est faux'));
      expect(body, contains('Analyse jointe : Tour Eiffel'));
      expect(body, contains('gemini-3.5-flash'));
      expect(body, contains('Un monument emblematique'));
    });

    // #328
    testWidgets('strips EXIF metadata from the photo before attaching an '
        'analysis to feedback', (tester) async {
      final placeholder = img.Image(width: 4, height: 4);
      img.fill(placeholder, color: img.ColorRgb8(80, 40, 160));
      // Standin for real GPS EXIF: a distinctive, greppable marker in an
      // arbitrary IFD0 tag proves whether it survived into the uploaded
      // bytes, without needing to hand-craft a real GPS IFD entry.
      placeholder.exif['ifd0'][0x010e] = 'GPS: 48.8584, 2.2945 EXIF_MARKER';
      final imagePath = '${tmpDir.path}/geotagged.jpg';
      File(imagePath).writeAsBytesSync(img.encodeJpg(placeholder));

      final entry =
          await tester.runAsync(() => history.addPendingEntry(imagePath: imagePath));
      await tester.runAsync(() => history.completeEntry(
            entryId: entry!.id!,
            title: 'Tour Eiffel',
            script: 'Un monument emblematique.',
          ));

      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"ok":true}', 200);
      });

      await tester.pumpWidget(wrapConfiguredScreen(client));
      await tester.pumpAndSettle();

      final button = find.text('Envoyer un feedback');
      await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Joindre une analyse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tour Eiffel'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Test EXIF');
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Envoyer'));
        for (var i = 0; i < 20 && requests.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      await tester.pump();

      expect(requests, hasLength(1));
      final request = requests.single as http.Request;
      expect(request.url.toString(), contains('/sendPhoto'));
      final body = latin1.decode(request.bodyBytes);
      expect(body, isNot(contains('EXIF_MARKER')));
    });

    // #319
    testWidgets('shows a specific error and sends nothing when the attached '
        "analysis's photo is missing from disk", (tester) async {
      final placeholder = img.Image(width: 4, height: 4);
      img.fill(placeholder, color: img.ColorRgb8(80, 40, 160));
      final imagePath = '${tmpDir.path}/vanished.jpg';
      File(imagePath).writeAsBytesSync(img.encodeJpg(placeholder));

      final entry =
          await tester.runAsync(() => history.addPendingEntry(imagePath: imagePath));
      await tester.runAsync(() => history.completeEntry(
            entryId: entry!.id!,
            title: 'Tour Eiffel',
            script: 'Un monument emblematique.',
          ));
      // Simulates the file disappearing after the entry was created —
      // external storage cleanup, a manual deletion, anything outside
      // deleteEntry's normal flow. addPendingEntry copies the source photo
      // to its own permanent path, so the file to delete is entry.imagePath,
      // not the original imagePath passed in above.
      File(entry!.imagePath).deleteSync();

      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('{"ok":true}', 200);
      });

      await tester.pumpWidget(wrapConfiguredScreen(client));
      await tester.pumpAndSettle();

      final button = find.text('Envoyer un feedback');
      await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Joindre une analyse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tour Eiffel'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Le titre est faux');
      await tester.tap(find.widgetWithText(FilledButton, 'Envoyer'));
      await tester.pumpAndSettle();

      expect(
        find.text(
            "La photo de l'analyse jointe est introuvable. Retirez-la pour pouvoir envoyer votre feedback."),
        findsOneWidget,
      );
      expect(requests, isEmpty);
      // Dialog stayed open, still showing the attached (now-broken) entry.
      expect(find.text("Changer l'analyse"), findsOneWidget);
    });

    testWidgets("shows an empty state in the picker when history has no entries",
        (tester) async {
      final client = MockClient((request) async => http.Response('{"ok":true}', 200));

      await tester.pumpWidget(wrapConfiguredScreen(client));
      await tester.pumpAndSettle();

      final button = find.text('Envoyer un feedback');
      await tester.scrollUntilVisible(button, 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(button);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Joindre une analyse'));
      await tester.pumpAndSettle();

      expect(find.text('Aucune analyse dans l\'historique'), findsOneWidget);
    });
  });

  testWidgets('entering an API key and tapping Save shows the saved snackbar',
      (tester) async {
    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'AIzaTestKey123');
    // #260: the new "Langue de l'application" section pushed this button
    // below the fold — needs an explicit scroll like the other off-screen
    // finders in this file (ListView only builds children near the
    // viewport, not the whole list).
    final saveButton = find.text('Sauvegarder');
    await tester.scrollUntilVisible(saveButton, 300,
        scrollable: find.byType(Scrollable).first);
    // AudioGuideService.setGeminiApiKey does real SecureKeyStorage I/O —
    // needs tester.runAsync() (see history_screen_test.dart's file doc for
    // why: testWidgets()'s fake-async zone never resolves real async I/O
    // otherwise).
    await tester.runAsync(() async {
      await tester.tap(saveButton);
    });
    await tester.pumpAndSettle();

    expect(find.text('Paramètres sauvegardés'), findsOneWidget);
  });

  testWidgets('toggling auto-generate-audio updates SettingsService', (tester) async {
    expect(settings.autoGenerateAudio, isTrue);

    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    // Well below the fold in this long settings list — the plain
    // ListView doesn't mount offscreen children, so the tap target
    // isn't in the tree until scrolled into view.
    final toggle = find.widgetWithText(SwitchListTile, 'Générer l\'audio automatiquement');
    await tester.scrollUntilVisible(toggle, 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(settings.autoGenerateAudio, isFalse);
  });

  testWidgets('toggling auto-purge updates SettingsService and reveals the day chips',
      (tester) async {
    expect(settings.autoPurgeEnabled, isFalse);

    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    final toggle = find.widgetWithText(SwitchListTile, 'Purger automatiquement l\'historique');
    await tester.scrollUntilVisible(toggle, 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(find.text('30 jours'), findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(settings.autoPurgeEnabled, isTrue);
    expect(find.text('30 jours'), findsOneWidget);
  });

  testWidgets('the version label renders from the mocked PackageInfo', (tester) async {
    await tester.pumpWidget(wrapScreen());
    await tester.pumpAndSettle();

    // #145 pushed this section further down the list — same offscreen-child
    // issue as the toggles above.
    final versionLabel = find.text('Version : 0.1.5 (42)');
    await tester.scrollUntilVisible(versionLabel, 300, scrollable: find.byType(Scrollable).first);

    expect(versionLabel, findsOneWidget);
  });
}
