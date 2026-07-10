import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'services/settings_service.dart';
import 'services/audio_guide_service.dart';
import 'screens/onboarding_screen.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  await settings.init();
  final guide = AudioGuideService();
  await guide.init(settings.geminiApiKey.isNotEmpty ? settings.geminiApiKey : null);
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: guide),
      ],
      child: const AudioGuideApp(),
    ),
  );
}

class AudioGuideApp extends StatelessWidget {
  const AudioGuideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audio Guide',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6B4EFF),
          brightness: Brightness.dark,
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
        useMaterial3: true,
      ),
      home: Consumer<SettingsService>(
        builder: (context, settings, _) {
          // If Gemini Nano available, skip onboarding entirely
          final guide = context.read<AudioGuideService>();
          if (guide.isReady) return const HomeScreen();
          if (settings.isOnboardingComplete) return const HomeScreen();
          return const OnboardingScreen();
        },
      ),
    );
  }
}
