import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/audio_guide_service.dart';

class PlayerScreen extends StatefulWidget {
  final File imageFile;
  const PlayerScreen({super.key, required this.imageFile});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final ScrollController _scrollController = ScrollController();
  double _readingProgress = 0.0; // 0.0 to 1.0

  @override
  void initState() {
    super.initState();
    // Listen to TTS progress from service
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final guide = context.read<AudioGuideService>();
      guide.ttsService.onProgress = (progress) {
        if (!mounted) return;
        setState(() => _readingProgress = progress);
        _scrollToProgress(progress);
      };
    });
  }

  void _scrollToProgress(double progress) {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return;
    final target = maxScroll * progress;
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Consumer<AudioGuideService>(
        builder: (context, guide, _) {
          // Reset progress when new analysis starts
          if (guide.state == GuideState.locating ||
              guide.state == GuideState.analyzing) {
            _readingProgress = 0.0;
          }

          return Stack(
            fit: StackFit.expand,
            children: [
              // Background image
              Image.file(widget.imageFile, fit: BoxFit.cover),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.95),
                    ],
                    stops: const [0.25, 0.75],
                  ),
                ),
              ),

              SafeArea(
                child: Column(
                  children: [
                    // Top bar
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back, color: Colors.white),
                            onPressed: () {
                              guide.stop();
                              Navigator.pop(context);
                            },
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),

                    // Content area
                    Expanded(
                      flex: 3,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Pipeline progress
                            if (guide.state == GuideState.locating ||
                                guide.state == GuideState.analyzing ||
                                guide.state == GuideState.synthesizing) ...[
                              _PipelineProgressWidget(guide: guide),
                              const SizedBox(height: 16),
                            ],

                            // State label
                            _StateLabel(state: guide.state),
                            const SizedBox(height: 8),

                            // Title
                            if (guide.lastResult != null) ...[
                              Text(
                                guide.lastResult!.title,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ).animate().fadeIn().slideY(begin: 0.2),

                              if (guide.lastResult!.locationName != null) ...[
                                const SizedBox(height: 4),
                                Row(children: [
                                  const Icon(Icons.location_on,
                                      color: Colors.white54, size: 13),
                                  const SizedBox(width: 4),
                                  Text(
                                    guide.lastResult!.locationName!,
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 12),
                                  ),
                                ]),
                              ],

                              const SizedBox(height: 12),

                              // Scrollable script with reading progress bar
                              Expanded(
                                child: Stack(
                                  children: [
                                    // Script text — scrollable by user + auto-scroll
                                    SingleChildScrollView(
                                      controller: _scrollController,
                                      physics: const BouncingScrollPhysics(),
                                      child: _HighlightedScript(
                                        text: guide.lastResult!.script,
                                        progress: _readingProgress,
                                      ),
                                    ),

                                    // Reading progress bar on the left edge
                                    if (guide.state == GuideState.speaking ||
                                        guide.state == GuideState.paused)
                                      Positioned(
                                        left: 0,
                                        top: 0,
                                        bottom: 0,
                                        child: Container(
                                          width: 3,
                                          decoration: BoxDecoration(
                                            color: Colors.white12,
                                            borderRadius: BorderRadius.circular(2),
                                          ),
                                          child: FractionallySizedBox(
                                            alignment: Alignment.topCenter,
                                            heightFactor: _readingProgress,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: Colors.white,
                                                borderRadius: BorderRadius.circular(2),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],

                            // Error
                            if (guide.state == GuideState.error)
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.red.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  guide.errorMessage ?? 'Erreur',
                                  style: const TextStyle(
                                      color: Colors.redAccent, fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // Controls
                    if (guide.state == GuideState.speaking ||
                        guide.state == GuideState.paused)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                        child: Row(
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
                      ),

                    const SizedBox(height: 8),
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

/// Displays script text with progressive highlighting
class _HighlightedScript extends StatelessWidget {
  final String text;
  final double progress; // 0.0 to 1.0

  const _HighlightedScript({required this.text, required this.progress});

  @override
  Widget build(BuildContext context) {
    if (progress <= 0.0) {
      return Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Text(
          text,
          style: const TextStyle(
              color: Colors.white70, fontSize: 15, height: 1.7),
        ),
      );
    }

    final splitIndex = (text.length * progress).round().clamp(0, text.length);
    final read = text.substring(0, splitIndex);
    final unread = text.substring(splitIndex);

    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: read,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.7,
                fontWeight: FontWeight.w500,
              ),
            ),
            TextSpan(
              text: unread,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 15,
                height: 1.7,
              ),
            ),
          ],
        ),
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
                    progress: isActive
                        ? progress.stepProgress
                        : (isDone ? 1.0 : 0.0),
                  ),
                  if (i < steps.length - 1)
                    Expanded(
                      child: Container(
                        height: 2,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        color: isDone ? Colors.white : Colors.white24,
                      ),
                    ),
                ],
              ),
            );
          }),
        ),
        if (progress.estimatedSecondsRemaining != null) ...[
          const SizedBox(height: 6),
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
            SizedBox(
              width: 36,
              height: 36,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.0, end: progress < 0 ? 0.0 : progress),
                duration: const Duration(milliseconds: 400),
                builder: (_, value, __) => CircularProgressIndicator(
                  value: progress < 0 ? null : value,
                  strokeWidth: 2,
                  backgroundColor: Colors.white12,
                  color: isDone ? Colors.greenAccent : Colors.white,
                ),
              ),
            ),
            Icon(
              isDone ? Icons.check : icon,
              size: 16,
              color: isDone
                  ? Colors.greenAccent
                  : isActive
                      ? Colors.white
                      : Colors.white38,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: isDone
                ? Colors.greenAccent
                : isActive
                    ? Colors.white
                    : Colors.white38,
          ),
        ),
      ],
    );
  }
}

class _StateLabel extends StatelessWidget {
  final GuideState state;
  const _StateLabel({required this.state});

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      GuideState.locating => const Row(children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white)),
          SizedBox(width: 8),
          Text('Localisation...', style: TextStyle(color: Colors.white70)),
        ]).animate().fadeIn(),
      GuideState.analyzing => const Row(children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white)),
          SizedBox(width: 8),
          Text('Analyse en cours...',
              style: TextStyle(color: Colors.white70)),
        ]).animate().fadeIn(),
      GuideState.synthesizing => const Row(children: [
          SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white)),
          SizedBox(width: 8),
          Text('Génération audio...',
              style: TextStyle(color: Colors.white70)),
        ]).animate().fadeIn(),
      GuideState.speaking => const Row(children: [
          Icon(Icons.graphic_eq, color: Colors.greenAccent, size: 16),
          SizedBox(width: 8),
          Text('Lecture...', style: TextStyle(color: Colors.white70)),
        ]).animate().fadeIn(),
      GuideState.paused => const Row(children: [
          Icon(Icons.pause_circle, color: Colors.white54, size: 16),
          SizedBox(width: 8),
          Text('En pause', style: TextStyle(color: Colors.white54)),
        ]),
      _ => const SizedBox.shrink(),
    };
  }
}
