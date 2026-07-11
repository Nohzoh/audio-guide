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
              Image.file(imageFile, fit: BoxFit.cover),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.92),
                    ],
                    stops: const [0.3, 1.0],
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () {
                        guide.stop();
                        Navigator.pop(context);
                      },
                    ),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Pipeline progress
                          if (guide.state == GuideState.locating ||
                              guide.state == GuideState.analyzing ||
                              guide.state == GuideState.synthesizing) ...[
                            _PipelineProgressWidget(guide: guide),
                            const SizedBox(height: 20),
                          ],

                          // State indicator
                          _StateIndicator(state: guide.state),
                          const SizedBox(height: 12),

                          // Result content
                          if (guide.lastResult != null) ...[
                            Text(
                              guide.lastResult!.title,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ).animate().fadeIn().slideY(begin: 0.2),

                            if (guide.lastResult!.locationName != null) ...[
                              const SizedBox(height: 4),
                              Row(children: [
                                const Icon(Icons.location_on, color: Colors.white54, size: 14),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    guide.lastResult!.locationName!,
                                    style: const TextStyle(color: Colors.white54),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ]),
                            ],

                            const SizedBox(height: 12),
                            Text(
                              guide.lastResult!.script,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white70,
                                height: 1.5,
                              ),
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                            ).animate().fadeIn(delay: 200.ms),
                          ],

                          if (guide.state == GuideState.error)
                            Container(
                              margin: const EdgeInsets.only(top: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                guide.errorMessage ?? 'Erreur inconnue',
                                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                              ),
                            ),

                          const SizedBox(height: 24),

                          // Playback controls
                          if (guide.state == GuideState.speaking ||
                              guide.state == GuideState.paused)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton.filled(
                                  iconSize: 36,
                                  icon: Icon(guide.state == GuideState.speaking
                                      ? Icons.pause : Icons.play_arrow),
                                  onPressed: guide.togglePause,
                                ),
                                const SizedBox(width: 16),
                                IconButton(
                                  icon: const Icon(Icons.stop_circle_outlined,
                                      color: Colors.white70, size: 36),
                                  onPressed: () {
                                    guide.stop();
                                    Navigator.pop(context);
                                  },
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

class _PipelineProgressWidget extends StatelessWidget {
  final AudioGuideService guide;
  const _PipelineProgressWidget({required this.guide});

  @override
  Widget build(BuildContext context) {
    final progress = guide.progress;
    final steps = [
      (icon: Icons.location_on, label: 'GPS'),
      (icon: Icons.psychology, label: 'Analyse'),
      (icon: Icons.record_voice_over, label: 'Voix'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Step indicators
        Row(
          children: List.generate(steps.length, (i) {
            final isDone = i < progress.currentStep;
            final isActive = i == progress.currentStep;
            return Expanded(
              child: Row(
                children: [
                  _StepDot(
                    icon: steps[i].icon,
                    label: steps[i].label,
                    isDone: isDone,
                    isActive: isActive,
                    progress: isActive ? progress.stepProgress : (isDone ? 1.0 : 0.0),
                  ),
                  if (i < steps.length - 1)
                    Expanded(
                      child: Container(
                        height: 2,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: isDone ? Colors.white : Colors.white24,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
        ),

        // Estimated time remaining
        if (progress.estimatedSecondsRemaining != null) ...[
          const SizedBox(height: 8),
          Text(
            '~${progress.estimatedSecondsRemaining!.round()}s restantes',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class _StepDot extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isDone;
  final bool isActive;
  final double progress;

  const _StepDot({
    required this.icon,
    required this.label,
    required this.isDone,
    required this.isActive,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            // Progress ring - TweenAnimationBuilder smooths rapid updates
            SizedBox(
              width: 36,
              height: 36,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: progress),
                duration: const Duration(milliseconds: 400),
                builder: (_, value, __) => CircularProgressIndicator(
                  value: value,
                  strokeWidth: 2,
                  backgroundColor: Colors.white12,
                  color: isDone ? Colors.greenAccent : Colors.white,
                ),
              ),
            ),
            // Icon
            Icon(
              isDone ? Icons.check : icon,
              size: 16,
              color: isDone ? Colors.greenAccent
                  : isActive ? Colors.white
                  : Colors.white38,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: isDone ? Colors.greenAccent
                : isActive ? Colors.white
                : Colors.white38,
          ),
        ),
      ],
    );
  }
}

class _StateIndicator extends StatelessWidget {
  final GuideState state;
  const _StateIndicator({required this.state});

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      GuideState.locating => const Row(children: [
          SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          SizedBox(width: 8),
          Text('Localisation...', style: TextStyle(color: Colors.white70)),
        ]).animate().fadeIn(),
      GuideState.analyzing => const Row(children: [
          SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          SizedBox(width: 8),
          Text('Analyse en cours...', style: TextStyle(color: Colors.white70)),
        ]).animate().fadeIn(),
      GuideState.synthesizing => const Row(children: [
          SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
          SizedBox(width: 8),
          Text('Génération audio...', style: TextStyle(color: Colors.white70)),
        ]).animate().fadeIn(),
      GuideState.speaking => Row(children: [
          const Icon(Icons.graphic_eq, color: Colors.greenAccent, size: 18),
          const SizedBox(width: 8),
          const Text('Lecture audio...', style: TextStyle(color: Colors.white70)),
        ]).animate().fadeIn(),
      GuideState.paused => const Row(children: [
          Icon(Icons.pause_circle, color: Colors.white54, size: 18),
          SizedBox(width: 8),
          Text('En pause', style: TextStyle(color: Colors.white54)),
        ]),
      _ => const SizedBox.shrink(),
    };
  }
}
