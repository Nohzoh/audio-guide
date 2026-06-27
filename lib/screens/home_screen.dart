import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/audio_guide_service.dart';
import '../services/settings_service.dart';
import 'model_download_screen.dart';
import 'player_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _takePicture(BuildContext context) async {
    final guide = context.read<AudioGuideService>();

    if (!guide.modelDownloaded) {
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => const ModelDownloadScreen(),
      ));
      return;
    }

    final picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
      maxWidth: 1280,
    );

    if (xFile == null || !context.mounted) return;

    final imageFile = File(xFile.path);

    Navigator.push(context, MaterialPageRoute(
      builder: (_) => PlayerScreen(imageFile: imageFile),
    ));

    guide.analyzeAndPlay(imageFile);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
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
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '🎧 Audio Guide',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () =>
                          context.read<SettingsService>().resetOnboarding(),
                    ),
                  ],
                ),
                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.camera_alt_outlined,
                            size: 100, color: Colors.white12),
                        SizedBox(height: 24),
                        Text(
                          'Pointez votre appareil\nvers un lieu ou un monument',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white38, fontSize: 16, height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ),
                Consumer<AudioGuideService>(
                  builder: (context, guide, _) {
                    if (!guide.modelDownloaded) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer
                                .withOpacity(0.3),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: theme.colorScheme.primary
                                    .withOpacity(0.3)),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.download_outlined,
                                  color: theme.colorScheme.primary, size: 20),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Téléchargez le modèle IA pour commencer',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                FilledButton.icon(
                  onPressed: () => _takePicture(context),
                  icon: const Icon(Icons.camera_alt, size: 24),
                  label: const Text('Prendre une photo',
                      style: TextStyle(fontSize: 18)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 64),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  ),
                ).animate().scale(delay: 200.ms),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
