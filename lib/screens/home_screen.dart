import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/audio_guide_service.dart';
import '../services/settings_service.dart';
import '../services/history_service.dart';
import 'player_screen.dart';
import 'history_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _takePicture(BuildContext context) async {
    final guide = context.read<AudioGuideService>();
    final history = context.read<HistoryService>();

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

    // Analyze and save to history
    final result = await guide.analyzeAndPlay(imageFile);
    if (result != null) {
      await history.addEntry(
        imagePath: imageFile.path,
        title: result.title,
        script: result.script,
        locationName: result.locationName,
      );
    }
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
            colors: [theme.colorScheme.surface, theme.colorScheme.surfaceContainerHigh],
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
                    Text('🎧 AudioLens',
                      style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.history),
                      tooltip: 'Historique',
                      onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const HistoryScreen()),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () =>
                          context.read<SettingsService>().resetOnboarding(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Consumer<AudioGuideService>(
                  builder: (context, guide, _) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          guide.providerName.contains('Nano')
                              ? Icons.phone_android
                              : Icons.cloud_outlined,
                          size: 14, color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          guide.providerName.isEmpty
                              ? 'Initialisation...'
                              : guide.providerName,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // History preview
                Consumer<HistoryService>(
                  builder: (context, history, _) {
                    if (history.entries.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('Récemment visité',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: Colors.white38,
                                ),
                              ),
                              const Spacer(),
                              GestureDetector(
                                onTap: () => Navigator.push(context,
                                  MaterialPageRoute(builder: (_) => const HistoryScreen()),
                                ),
                                child: Text('Voir tout',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 80,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: history.entries.take(5).length,
                              itemBuilder: (context, i) {
                                final entry = history.entries[i];
                                return GestureDetector(
                                  onTap: () => Navigator.push(context,
                                    MaterialPageRoute(
                                      builder: (_) => HistoryDetailScreen(entry: entry),
                                    ),
                                  ),
                                  child: Container(
                                    width: 80,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(10),
                                      color: theme.colorScheme.surfaceContainerHigh,
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: File(entry.imagePath).existsSync()
                                        ? Image.file(File(entry.imagePath), fit: BoxFit.cover)
                                        : const Icon(Icons.image, color: Colors.white24),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.camera_alt_outlined, size: 80, color: Colors.white12),
                        SizedBox(height: 16),
                        Text(
                          'Pointez votre appareil\nvers un lieu ou un monument',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 15, height: 1.5),
                        ),
                      ],
                    ),
                  ),
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
