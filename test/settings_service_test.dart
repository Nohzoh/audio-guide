import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audiolens/services/settings_service.dart';

const _secureChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// T68 — only autoGenerateAudio was covered before this (incidentally, via
/// script_only_mode_test.dart); showKofiButton, scriptStyle (T75), the
/// onboarding/API key flow, and resetOnboarding() had no dedicated test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final secureStore = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureStore.clear();
    // T123 follow-up: SecureKeyStorage.writeApiKey no longer falls back to
    // plaintext SharedPreferences on failure, so it needs a real (mocked)
    // secure storage channel to succeed in tests.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, dynamic>();
      switch (call.method) {
        case 'write':
          secureStore[args!['key'] as String] = args['value'] as String;
          return null;
        case 'read':
          return secureStore[args!['key'] as String];
        case 'delete':
          secureStore.remove(args!['key'] as String);
          return null;
        case 'deleteAll':
          secureStore.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(secureStore);
        case 'containsKey':
          return secureStore.containsKey(args!['key'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
  });

  test('defaults before onboarding: not complete, empty key, style immersive', () async {
    final settings = SettingsService();
    await settings.init();

    expect(settings.isOnboardingComplete, isFalse);
    expect(settings.geminiApiKey, isEmpty);
    expect(settings.showKofiButton, isTrue);
    expect(settings.autoGenerateAudio, isTrue);
    expect(settings.scriptStyle, 'immersive');
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.outputLanguage, 'Français');
  });

  test('completeOnboarding stores the API key and marks onboarding complete',
      () async {
    final settings = SettingsService();
    await settings.init();

    await settings.completeOnboarding(apiKey: 'AIza-test-key');

    expect(settings.isOnboardingComplete, isTrue);
    expect(settings.geminiApiKey, 'AIza-test-key');

    // Persisted, not just in-memory — a fresh instance sees the same state.
    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.isOnboardingComplete, isTrue);
    expect(reloaded.geminiApiKey, 'AIza-test-key');
  });

  // #298: apiKey is optional — a device where local AI (Nano) already
  // works can finish onboarding without one.
  test('completeOnboarding without an apiKey still marks onboarding '
      'complete, leaving geminiApiKey empty', () async {
    final settings = SettingsService();
    await settings.init();

    await settings.completeOnboarding();

    expect(settings.isOnboardingComplete, isTrue);
    expect(settings.geminiApiKey, isEmpty);
  });

  // #299
  test('lastSeenVersion is null by default and persists across a reload '
      'once recorded', () async {
    final settings = SettingsService();
    await settings.init();
    expect(settings.lastSeenVersion, isNull);

    await settings.recordSeenVersion('1.2.3');
    expect(settings.lastSeenVersion, '1.2.3');

    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.lastSeenVersion, '1.2.3');
  });

  test('resetOnboarding clears lastSeenVersion too', () async {
    final settings = SettingsService();
    await settings.init();
    await settings.recordSeenVersion('1.2.3');

    await settings.resetOnboarding();

    expect(settings.lastSeenVersion, isNull);
  });

  // #312 diagnostic breadcrumb
  test('whatsNewShownVersion/whatsNewDismissedVersion are null by default '
      'and persist across a reload once recorded', () async {
    final settings = SettingsService();
    await settings.init();
    expect(settings.whatsNewShownVersion, isNull);
    expect(settings.whatsNewDismissedVersion, isNull);

    await settings.recordWhatsNewShown('1.2.3');
    expect(settings.whatsNewShownVersion, '1.2.3');
    expect(settings.whatsNewDismissedVersion, isNull);

    await settings.recordWhatsNewDismissed('1.2.3');
    expect(settings.whatsNewDismissedVersion, '1.2.3');

    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.whatsNewShownVersion, '1.2.3');
    expect(reloaded.whatsNewDismissedVersion, '1.2.3');
  });

  test('resetOnboarding clears the whats-new shown/dismissed breadcrumb too',
      () async {
    final settings = SettingsService();
    await settings.init();
    await settings.recordWhatsNewShown('1.2.3');
    await settings.recordWhatsNewDismissed('1.2.3');

    await settings.resetOnboarding();

    expect(settings.whatsNewShownVersion, isNull);
    expect(settings.whatsNewDismissedVersion, isNull);
  });

  // #309
  group('startup tips', () {
    test('tipsEnabled defaults to true, launchCount/tipIndex default to 0',
        () async {
      final settings = SettingsService();
      await settings.init();

      expect(settings.tipsEnabled, isTrue);
      expect(settings.launchCount, 0);
      expect(settings.tipIndex, 0);
    });

    test('setTipsEnabled persists across a reload', () async {
      final settings = SettingsService();
      await settings.init();

      await settings.setTipsEnabled(false);
      expect(settings.tipsEnabled, isFalse);

      final reloaded = SettingsService();
      await reloaded.init();
      expect(reloaded.tipsEnabled, isFalse);
    });

    test('incrementLaunchCount persists across a reload', () async {
      final settings = SettingsService();
      await settings.init();

      await settings.incrementLaunchCount();
      await settings.incrementLaunchCount();
      expect(settings.launchCount, 2);

      final reloaded = SettingsService();
      await reloaded.init();
      expect(reloaded.launchCount, 2);
    });

    test('setTipIndex persists across a reload', () async {
      final settings = SettingsService();
      await settings.init();

      await settings.setTipIndex(3);
      expect(settings.tipIndex, 3);

      final reloaded = SettingsService();
      await reloaded.init();
      expect(reloaded.tipIndex, 3);
    });

    test('resetOnboarding clears tipsEnabled/launchCount/tipIndex too',
        () async {
      final settings = SettingsService();
      await settings.init();
      await settings.setTipsEnabled(false);
      await settings.incrementLaunchCount();
      await settings.setTipIndex(5);

      await settings.resetOnboarding();

      expect(settings.tipsEnabled, isTrue);
      expect(settings.launchCount, 0);
      expect(settings.tipIndex, 0);
    });
  });

  test('setShowKofiButton persists across a reload', () async {
    final settings = SettingsService();
    await settings.init();

    await settings.setShowKofiButton(false);
    expect(settings.showKofiButton, isFalse);

    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.showKofiButton, isFalse);
  });

  test('setScriptStyle persists across a reload (T75)', () async {
    final settings = SettingsService();
    await settings.init();

    await settings.setScriptStyle('anecdotal');
    expect(settings.scriptStyle, 'anecdotal');

    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.scriptStyle, 'anecdotal');
  });

  // #130
  test('setOutputLanguage persists across a reload', () async {
    final settings = SettingsService();
    await settings.init();

    await settings.setOutputLanguage('English');
    expect(settings.outputLanguage, 'English');

    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.outputLanguage, 'English');
  });

  test('resetOnboarding clears onboarding, API key, and restores every default',
      () async {
    final settings = SettingsService();
    await settings.init();
    await settings.completeOnboarding(apiKey: 'AIza-test-key');
    await settings.setShowKofiButton(false);
    await settings.setAutoGenerateAudio(false);
    await settings.setScriptStyle('concise');
    await settings.setAutoPurgeEnabled(true);
    await settings.setAutoPurgeDays(7);
    await settings.setThemeMode(ThemeMode.dark);
    await settings.setAppLocale('en');
    await settings.setOutputLanguageFollowsApp(true);
    await settings.setOutputLanguage('Deutsch');

    await settings.resetOnboarding();

    expect(settings.isOnboardingComplete, isFalse);
    expect(settings.geminiApiKey, isEmpty);
    expect(settings.showKofiButton, isTrue);
    expect(settings.autoGenerateAudio, isTrue);
    expect(settings.scriptStyle, 'immersive');
    expect(settings.autoPurgeEnabled, isFalse);
    expect(settings.autoPurgeDays, 30);
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.outputLanguage, 'Français');
    expect(settings.outputLanguageFollowsApp, isFalse);
    expect(settings.appLocale, isNull);
  });

  // #145
  test('setThemeMode persists across a reload', () async {
    final settings = SettingsService();
    await settings.init();

    await settings.setThemeMode(ThemeMode.light);
    expect(settings.themeMode, ThemeMode.light);

    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.themeMode, ThemeMode.light);
  });

  test('setThemeMode(ThemeMode.dark) also persists across a reload (#145)',
      () async {
    final settings = SettingsService();
    await settings.init();

    await settings.setThemeMode(ThemeMode.dark);

    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.themeMode, ThemeMode.dark);
  });

  // #260
  test('setAppLocale persists across a reload, null resets to system', () async {
    final settings = SettingsService();
    await settings.init();
    expect(settings.appLocale, isNull);

    await settings.setAppLocale('en');
    expect(settings.appLocale, 'en');
    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.appLocale, 'en');

    await reloaded.setAppLocale(null);
    expect(reloaded.appLocale, isNull);
    final reloadedAgain = SettingsService();
    await reloadedAgain.init();
    expect(reloadedAgain.appLocale, isNull);
  });

  // #263 follow-up (narration language can track the app's own language)
  group('outputLanguageFollowsApp', () {
    test('off by default, matching outputLanguage\'s own independent default',
        () async {
      final settings = SettingsService();
      await settings.init();
      expect(settings.outputLanguageFollowsApp, isFalse);
    });

    test('enabling resolves outputLanguage from the current appLocale',
        () async {
      final settings = SettingsService();
      await settings.init();
      await settings.setAppLocale('en');

      await settings.setOutputLanguageFollowsApp(true);

      expect(settings.outputLanguageFollowsApp, isTrue);
      expect(settings.outputLanguage, 'English');
    });

    test('changing appLocale while enabled keeps outputLanguage in sync',
        () async {
      final settings = SettingsService();
      await settings.init();
      await settings.setAppLocale('en');
      await settings.setOutputLanguageFollowsApp(true);
      expect(settings.outputLanguage, 'English');

      await settings.setAppLocale('fr');

      expect(settings.outputLanguage, 'Français');
    });

    test('changing appLocale while disabled leaves outputLanguage untouched',
        () async {
      final settings = SettingsService();
      await settings.init();
      await settings.setOutputLanguage('Deutsch');

      await settings.setAppLocale('en');

      expect(settings.outputLanguage, 'Deutsch');
    });

    test('picking a language explicitly turns follow-app back off', () async {
      final settings = SettingsService();
      await settings.init();
      await settings.setAppLocale('en');
      await settings.setOutputLanguageFollowsApp(true);

      await settings.setOutputLanguage('Español');

      expect(settings.outputLanguageFollowsApp, isFalse);
      expect(settings.outputLanguage, 'Español');
    });

    test('persists across a reload and re-resolves against the current appLocale',
        () async {
      final settings = SettingsService();
      await settings.init();
      await settings.setAppLocale('en');
      await settings.setOutputLanguageFollowsApp(true);

      // appLocale changes while the app is closed (e.g. from a different
      // device/session) -- the reload should re-resolve, not replay the
      // stale persisted string.
      await settings.setAppLocale('fr');
      final reloaded = SettingsService();
      await reloaded.init();

      expect(reloaded.outputLanguageFollowsApp, isTrue);
      expect(reloaded.outputLanguage, 'Français');
    });
  });

  test('auto-purge defaults to disabled, 30 days (T95)', () async {
    final settings = SettingsService();
    await settings.init();

    expect(settings.autoPurgeEnabled, isFalse);
    expect(settings.autoPurgeDays, 30);
  });

  test('setAutoPurgeEnabled/setAutoPurgeDays persist across a reload (T95)',
      () async {
    final settings = SettingsService();
    await settings.init();

    await settings.setAutoPurgeEnabled(true);
    await settings.setAutoPurgeDays(14);
    expect(settings.autoPurgeEnabled, isTrue);
    expect(settings.autoPurgeDays, 14);

    final reloaded = SettingsService();
    await reloaded.init();
    expect(reloaded.autoPurgeEnabled, isTrue);
    expect(reloaded.autoPurgeDays, 14);
  });
}
