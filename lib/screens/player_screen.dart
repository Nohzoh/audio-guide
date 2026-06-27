import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/audio_guide_service.dart';

class PlayerScreen extends StatelessWidget {
  final File imageFile;
  const PlayerScreen({super.key, required this.imageFile});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Consumer<AudioGuideService>(
        builder: (context, guide, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              // Image de fond
              Image.file(imageFile, fit: BoxFit.cover),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.85),
                    ],
                    stops: const [0.4, 1.0],
                  ),
                ),
              ),

              // Contenu
              SafeArea(
                child: Column(
                  children: [
                    // Back button
                    Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: () {
                            guide.stop();
                            Navigator.pop(context);
                          },
                        ),
                      ),
                    ),

                    const Spacer(),

                    // Player card
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // État
                          _StateIndicator(state: guide.state),
                          const SizedBox(height: 16),

                          // Titre
                          if (guide.lastResult != null) ...[
                            Text(
                              guide.lastResult!.title,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ).animate().fadeIn().slideY(begin: 0.2),
                            if (guide.lastResult!.locationName != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.location_on, color: Colors.white54, size: 14),
                                  const SizedBox(width: 4),
                                  Text(
                                    guide.lastResult!.locationName!,
                                    style: const TextStyle(color: Colors.white54),
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 12),
                            Text(
                              guide.lastResult!.script,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white70,
                                height: 1.5,
                              ),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ).animate().fadeIn(delay: 200.ms),
                          ],

                          const SizedBox(height: 24),

                          // Controls
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (guide.state == GuideState.speaking ||
                                  guide.state == GuideState.paused) ...[
                                IconButton.filled(
                                  iconSize: 32,
                                  icon: Icon(
                                    guide.state == GuideState.speaking
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                  ),
                                  onPressed: guide.togglePause,
                                ),
                                const SizedBox(width: 16),
                                IconButton(
                                  icon: const Icon(Icons.stop, color: Colors.white70),
                                  onPressed: () {
                                    guide.stop();
                                    Navigator.pop(context);
                                  },
                                ),
                              ],
                              if (guide.state == GuideState.error)
                                Text(
                                  guide.errorMessage ?? 'Erreur',
                                  style: const TextStyle(color: Colors.redAccent),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StateIndicator extends StatelessWidget {
  final GuideState state;
  const _StateIndicator({required this.state});

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      GuideState.analyzing => Row(
          children: [
            const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 8),
            const Text('Analyse en cours...', style: TextStyle(color: Colors.white70)),
          ],
        ).animate().fadeIn(),
      GuideState.speaking => Row(
          children: [
            const Icon(Icons.graphic_eq, color: Colors.greenAccent, size: 18),
            const SizedBox(width: 8),
            const Text('Lecture...', style: TextStyle(color: Colors.white70)),
          ],
        ).animate().fadeIn(),
      GuideState.paused => const Row(
          children: [
            Icon(Icons.pause_circle, color: Colors.white54, size: 18),
            SizedBox(width: 8),
            Text('En pause', style: TextStyle(color: Colors.white54)),
          ],
        ),
      _ => const SizedBox.shrink(),
    };
  }
}
