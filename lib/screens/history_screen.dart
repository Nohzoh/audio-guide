import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import '../services/audio_guide_service.dart';
import '../services/history_service.dart';
import 'package:provider/provider.dart';
import '../services/audio_guide_service.dart';
import '../services/tts_service.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historique'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Consumer<HistoryService>(
        builder: (context, history, _) {
          if (history.entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.history, size: 64, color: Colors.white12),
                  const SizedBox(height: 16),
                  Text(
                    'Aucune visite enregistrée',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Prenez une photo pour commencer',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white24,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: history.entries.length,
            itemBuilder: (context, index) {
              final entry = history.entries[index];
              return _HistoryCard(entry: entry)
                  .animate(delay: (index * 50).ms)
                  .fadeIn()
                  .slideY(begin: 0.1);
            },
          );
        },
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final HistoryEntry entry;
  const _HistoryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateStr = DateFormat('d MMM yyyy · HH:mm', 'fr_FR')
        .format(entry.createdAt);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => HistoryDetailScreen(entry: entry),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Thumbnail
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: File(entry.imagePath).existsSync()
                        ? Image.file(
                            File(entry.imagePath),
                            fit: BoxFit.cover,
                          )
                        : Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.image_not_supported,
                                color: Colors.white24),
                          ),
                  ),
                ),
                const SizedBox(width: 12),

                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (entry.locationName != null) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            const Icon(Icons.location_on,
                                size: 12, color: Colors.white38),
                            const SizedBox(width: 2),
                            Text(
                              entry.locationName!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white38,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        dateStr,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white24,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),

                const Icon(Icons.chevron_right, color: Colors.white24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HistoryDetailScreen extends StatefulWidget {
  final HistoryEntry entry;
  const HistoryDetailScreen({super.key, required this.entry});

  @override
  State<HistoryDetailScreen> createState() => _HistoryDetailScreenState();
}

class _HistoryDetailScreenState extends State<HistoryDetailScreen> {
  bool _isPlaying = false;

  // Use AudioGuideService TTS so same voice as first analysis
  _getTts(BuildContext context) {
    final guide = context.read<AudioGuideService>();
    return guide.geminiTtsService ?? guide.ttsService;
  }

  // Play cached audio file directly without re-generating TTS
  Future<void> _playCachedAudio(String path) async {
    const channel = MethodChannel('com.audioguide/audio_player');
    channel.invokeMethod('playWav', {'path': path}).then((_) {
      setState(() => _isPlaying = false);
    });
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    // Stop playback when leaving screen
    const channel = MethodChannel('com.audioguide/audio_player');
    channel.invokeMethod('stop');
    super.dispose();
  }

  Future<void> _toggleAudio() async {
    if (_isPlaying) {
      final tts = _getTts(context);
      await tts.stop();
      setState(() => _isPlaying = false);
    } else {
      setState(() => _isPlaying = true);
      if (widget.entry.hasAudio) {
        // Use cached audio — no TTS regeneration needed
        await _playCachedAudio(widget.entry.audioPath!);
      } else {
        // No cache — generate with TTS
        final tts = _getTts(context);
        tts.onComplete = () => setState(() => _isPlaying = false);
        await tts.speak(widget.entry.script);
      }
    }
  }

  Future<void> _deleteEntry(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer'),
        content: const Text('Supprimer cette entrée de l\'historique ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<HistoryService>().deleteEntry(widget.entry.id!);
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateStr = DateFormat('EEEE d MMMM yyyy · HH:mm', 'fr_FR')
        .format(widget.entry.createdAt);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Full image background
          if (File(widget.entry.imagePath).existsSync())
            Image.file(File(widget.entry.imagePath), fit: BoxFit.cover),

          // Gradient overlay
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.3),
                  Colors.black.withOpacity(0.95),
                ],
                stops: const [0.3, 1.0],
              ),
            ),
          ),

          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top bar
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back,
                            color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.redAccent),
                        onPressed: () => _deleteEntry(context),
                      ),
                    ],
                  ),
                ),

                // Content
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      // Date
                      Text(
                        dateStr,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white54,
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Title
                      Text(
                        widget.entry.title,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),

                      if (widget.entry.locationName != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.location_on,
                                color: Colors.white54, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              widget.entry.locationName!,
                              style: const TextStyle(color: Colors.white54),
                            ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 16),

                      // Copy button
                      Align(
                        alignment: Alignment.centerRight,
                        child: InkWell(
                          onTap: () {
                            Clipboard.setData(
                                ClipboardData(text: widget.entry.script));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Texte copié'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                vertical: 4, horizontal: 2),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.copy,
                                    size: 14, color: Colors.white54),
                                SizedBox(width: 4),
                                Text('Copier',
                                    style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Script
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.1)),
                        ),
                        child: Text(
                          widget.entry.script,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white.withOpacity(0.85),
                            height: 1.6,
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Play button
                      FilledButton.icon(
                        onPressed: _toggleAudio,
                        icon: Icon(_isPlaying
                            ? Icons.stop
                            : Icons.play_arrow),
                        label: Text(_isPlaying
                            ? 'Arrêter'
                            : 'Écouter le commentaire'),
                        style: FilledButton.styleFrom(
                          minimumSize:
                              const Size(double.infinity, 52),
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(14)),
                        ),
                      ),

                      const SizedBox(height: 12),
                    ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
