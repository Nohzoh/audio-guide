import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:audiolens/screens/quiz_screen.dart';
import 'package:audiolens/services/audio_guide_service.dart';
import 'package:audiolens/services/gemini_api_service.dart';
import 'package:audiolens/services/history_service.dart';
import 'package:audiolens/services/settings_service.dart';
import '../support/fake_dio_adapter.dart';
import '../support/service_fakes.dart';

/// #343
const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;

  late Directory tmpDir;
  late SettingsService settings;
  late HistoryService history;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('quiz_screen_test');
    SharedPreferences.setMockInitialValues({});
    setUpSecureStorageMock();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return tmpDir.path;
      return null;
    });
    settings = SettingsService();
    await settings.init();
    history = HistoryService();
    await history.init(dbPath: '${tmpDir.path}/history.db');
  });

  tearDown(() async {
    tearDownSecureStorageMock();
    await tmpDir.delete(recursive: true);
  });

  // [tester], when provided, routes the real sqflite FFI I/O through
  // WidgetTester.runAsync — required whenever this runs inside a
  // testWidgets body (matches the established pattern in
  // settings_screen_test.dart's history-seeding tests): real async I/O
  // left unwrapped there never gets a chance to complete against
  // TestWidgetsFlutterBinding's fake async clock, hanging the test
  // indefinitely rather than failing outright. Not needed for the plain
  // test() "quiz eligibility" group below, which runs in a real Dart
  // zone with no such binding involved.
  Future<void> seedEntries(int count, {WidgetTester? tester}) async {
    final placeholder = img.Image(width: 4, height: 4);
    img.fill(placeholder, color: img.ColorRgb8(80, 40, 160));
    Future<void> seedOne(int i) async {
      final imagePath = '${tmpDir.path}/photo_$i.jpg';
      File(imagePath).writeAsBytesSync(img.encodeJpg(placeholder));
      final entry = await history.addPendingEntry(imagePath: imagePath);
      await history.completeEntry(
        entryId: entry.id!,
        title: 'Monument $i',
        script: 'Ceci est le monument numéro $i, construit il y a longtemps.',
        locationName: 'Ville $i',
      );
    }

    for (var i = 0; i < count; i++) {
      if (tester != null) {
        await tester.runAsync(() => seedOne(i));
      } else {
        await seedOne(i);
      }
    }
  }

  group('quiz eligibility', () {
    test('not enough entries below the minimum distinct-title count',
        () async {
      await seedEntries(2);

      expect(hasEnoughQuizEntries(history), isFalse);
    });

    test('enough entries once the minimum distinct-title count is reached',
        () async {
      await seedEntries(quizMinimumEntries);

      expect(hasEnoughQuizEntries(history), isTrue);
      expect(eligibleQuizEntries(history), hasLength(quizMinimumEntries));
    });

    test('pending/captured/failed entries never count towards eligibility',
        () async {
      await seedEntries(quizMinimumEntries - 1);
      final placeholder = img.Image(width: 4, height: 4);
      img.fill(placeholder, color: img.ColorRgb8(80, 40, 160));
      final imagePath = '${tmpDir.path}/still_pending.jpg';
      File(imagePath).writeAsBytesSync(img.encodeJpg(placeholder));
      await history.addPendingEntry(imagePath: imagePath);

      expect(hasEnoughQuizEntries(history), isFalse);
    });
  });

  group('QuizScreen', () {
    testWidgets('without a Gemini API key, asks to guess the place and '
        'reveals feedback on tap', (tester) async {
      await seedEntries(5, tester: tester);
      final guide = AudioGuideService(nativeTtsService: FakeNativeTts());

      await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
            const QuizScreen(),
            settings: settings,
            guide: guide,
            history: history,
          )));
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();

      expect(find.text('Où était-ce ?'), findsOneWidget);
      final optionFinder = find.byType(OutlinedButton);
      expect(optionFinder, findsNWidgets(4));

      // Tapping any option (correct or not) reveals feedback and the
      // Next button — which of the 4 is correct varies with the random
      // entry picked this round, so this doesn't assert on "Bien joué"
      // specifically (see the next test for the wrong-answer path).
      await tester.ensureVisible(optionFinder.first);
      await tester.pump();
      await tester.tap(optionFinder.first);
      await tester.pump();

      expect(find.textContaining('bonnes réponses'), findsOneWidget);
      expect(find.text('Suivant'), findsOneWidget);
    });

    testWidgets('the score counter starts at 0/0 and its total increments '
        'after answering', (tester) async {
      await seedEntries(5, tester: tester);
      final guide = AudioGuideService(nativeTtsService: FakeNativeTts());

      await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
            const QuizScreen(),
            settings: settings,
            guide: guide,
            history: history,
          )));
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();

      expect(find.text('0 / 0 bonnes réponses'), findsOneWidget);

      final optionFinder = find.byType(OutlinedButton).first;
      await tester.ensureVisible(optionFinder);
      await tester.pump();
      await tester.tap(optionFinder);
      await tester.pump();

      expect(find.text('0 / 0 bonnes réponses'), findsNothing);
      // Depending on whether the tapped option happened to be correct
      // for this round's randomly picked entry — but the total always
      // increments to 1 either way.
      final scoreIsZeroOfOne = find.text('0 / 1 bonnes réponses').evaluate().isNotEmpty;
      final scoreIsOneOfOne = find.text('1 / 1 bonnes réponses').evaluate().isNotEmpty;
      expect(scoreIsZeroOfOne || scoreIsOneOfOne, isTrue);
      expect(find.text('Suivant'), findsOneWidget);
    });

    testWidgets('tapping Next loads a fresh, unanswered question',
        (tester) async {
      await seedEntries(5, tester: tester);
      final guide = AudioGuideService(nativeTtsService: FakeNativeTts());

      await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
            const QuizScreen(),
            settings: settings,
            guide: guide,
            history: history,
          )));
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();

      final optionFinder = find.byType(OutlinedButton).first;
      await tester.ensureVisible(optionFinder);
      await tester.pump();
      await tester.tap(optionFinder);
      await tester.pump();
      final nextFinder = find.text('Suivant');
      await tester.ensureVisible(nextFinder);
      await tester.pump();
      await tester.tap(nextFinder);
      await tester.pump();
      await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();

      // Back to an unanswered state: 4 tappable options, no reveal text.
      expect(find.byType(OutlinedButton), findsNWidgets(4));
      expect(find.text('Suivant'), findsNothing);
    });

    testWidgets('with a Gemini API key configured, asks the generated '
        'text-comprehension question instead', (tester) async {
      await seedEntries(5, tester: tester);
      var responded = false;
      final client = fakeDio((options) async {
        responded = true;
        return (
          statusCode: 200,
          body: jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {
                      'text': jsonEncode({
                        'question': 'En quelle année ?',
                        'correctAnswer': '1889',
                        'wrongAnswers': ['1789', '1900', '1850'],
                      }),
                    },
                  ],
                },
              },
            ],
          }),
        );
      });
      final guide = AudioGuideService(
        nativeTtsService: FakeNativeTts(),
        geminiApiService: GeminiApiService(apiKey: 'test-key', dioClient: client),
      );

      await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
            const QuizScreen(),
            settings: settings,
            guide: guide,
            history: history,
          )));
      await tester.pump();
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && !responded; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      await tester.pump();

      expect(find.text('En quelle année ?'), findsOneWidget);
      expect(find.text('1889'), findsOneWidget);
      expect(find.text('1789'), findsOneWidget);
      expect(find.text('Où était-ce ?'), findsNothing);
    });

    // Found via user feedback: while a Gemini text-comprehension question
    // is still being generated, the guess-the-place placeholder text used
    // to show anyway — misleading, since it isn't necessarily the
    // question that ends up being asked.
    testWidgets(
        'while a text-comprehension question is loading, does not show the '
        'guess-the-place placeholder question', (tester) async {
      await seedEntries(5, tester: tester);
      final responseCompleter = Completer<({int statusCode, String body})>();
      final client = fakeDio((options) async => responseCompleter.future);
      final guide = AudioGuideService(
        nativeTtsService: FakeNativeTts(),
        geminiApiService: GeminiApiService(apiKey: 'test-key', dioClient: client),
      );

      await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
            const QuizScreen(),
            settings: settings,
            guide: guide,
            history: history,
          )));
      await tester.pump();
      await tester.pump();

      // Still waiting on the Gemini call.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Où était-ce ?'), findsNothing);

      responseCompleter.complete((
        statusCode: 200,
        body: jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {
                    'text': jsonEncode({
                      'question': 'En quelle année ?',
                      'correctAnswer': '1889',
                      'wrongAnswers': ['1789', '1900', '1850'],
                    }),
                  },
                ],
              },
            },
          ],
        }),
      ));
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      await tester.pump();

      expect(find.text('En quelle année ?'), findsOneWidget);
    });

    testWidgets('falls back to guess-the-place when question generation '
        'fails', (tester) async {
      await seedEntries(5, tester: tester);
      var responded = false;
      final client = fakeDio((options) async {
        responded = true;
        return (statusCode: 500, body: 'error');
      });
      final guide = AudioGuideService(
        nativeTtsService: FakeNativeTts(),
        geminiApiService: GeminiApiService(apiKey: 'test-key', dioClient: client),
      );

      await tester.runAsync(() => tester.pumpWidget(wrapWithProviders(
            const QuizScreen(),
            settings: settings,
            guide: guide,
            history: history,
          )));
      await tester.pump();
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && !responded; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      await tester.pump();

      expect(find.text('Où était-ce ?'), findsOneWidget);
    });
  });
}
