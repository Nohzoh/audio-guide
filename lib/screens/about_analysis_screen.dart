import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../services/history_service.dart';

class AboutAnalysisScreen extends StatelessWidget {
  final HistoryEntry entry;

  const AboutAnalysisScreen({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('À propos de cette analyse'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Image thumbnail
          if (File(entry.imagePath).existsSync())
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(File(entry.imagePath),
                  height: 180, width: double.infinity, fit: BoxFit.cover),
            ),
          const SizedBox(height: 20),

          // Title
          Text(entry.title,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),

          _Section(title: 'DATES', children: [
            _Row('Capture', DateFormat('dd/MM/yyyy à HH:mm').format(entry.createdAt)),
            if (entry.analyzedAt != null)
              _Row('Analyse', DateFormat('dd/MM/yyyy à HH:mm').format(entry.analyzedAt!)),
            if (entry.analysisDurationMs != null)
              _Row('Durée d\'analyse', '${(entry.analysisDurationMs! / 1000).toStringAsFixed(1)}s'),
          ]),

          _Section(title: 'MODÈLES', children: [
            _Row('Modèle IA', entry.aiModel ?? 'Inconnu'),
            _Row('Modèle TTS', entry.ttsModel ?? 'Inconnu'),
            _Row('Source image', _sourceLabel(entry.analysisSource)),
          ]),

          _Section(title: 'GÉOLOCALISATION', children: [
            _Row('Source GPS', _gpsSourceLabel(entry.gpsSource)),
            if (entry.gpsLatitude != null && entry.gpsLongitude != null)
              _Row('Coordonnées',
                  '${entry.gpsLatitude!.toStringAsFixed(5)}, '
                  '${entry.gpsLongitude!.toStringAsFixed(5)}'),
            if (entry.gpsAddress != null && entry.gpsAddress!.isNotEmpty)
              _Row('Adresse', entry.gpsAddress!
                  .replaceAll('Localisation GPS : ', '')
                  .split('(').last.replaceAll(')', '').trim()),
            _Row('Wikipedia utilisé', entry.wikipediaUsed ? 'Oui' : 'Non'),
          ]),

          _Section(title: 'CONTENU', children: [
            _Row('Mots', entry.wordCount?.toString() ?? 'Inconnu'),
            if (entry.audioDurationEstimate.isNotEmpty)
              _Row('Durée audio estimée', entry.audioDurationEstimate),
            _Row('Statut', _statusLabel(entry.status)),
            if (entry.audioPath != null)
              _Row('Audio en cache', 'Oui (${entry.ttsModel ?? '?'})'),
          ]),

          const SizedBox(height: 12),

          // Copy debug info
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copier les infos de debug'),
            onPressed: () {
              final debug = _buildDebugInfo();
              Clipboard.setData(ClipboardData(text: debug));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Infos copiées')),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _buildDebugInfo() {
    return '''AudioLens Debug Info
====================
Title: ${entry.title}
Created: ${entry.createdAt.toIso8601String()}
Analyzed: ${entry.analyzedAt?.toIso8601String() ?? 'unknown'}
AI Model: ${entry.aiModel ?? 'unknown'}
TTS Model: ${entry.ttsModel ?? 'unknown'}
Analysis source: ${entry.analysisSource ?? 'unknown'}
GPS source: ${entry.gpsSource ?? 'unknown'}
GPS: ${entry.gpsLatitude ?? 'null'}, ${entry.gpsLongitude ?? 'null'}
Wikipedia: ${entry.wikipediaUsed}
Word count: ${entry.wordCount ?? 'unknown'}
Analysis duration: ${entry.analysisDurationMs ?? 'unknown'}ms
Audio path: ${entry.audioPath ?? 'none'}
Status: ${entry.status.name}
''';
  }

  String _sourceLabel(String? source) => switch (source) {
    'camera' => '📷 Caméra',
    'gallery' => '🖼️ Galerie',
    'retry' => '🔄 Relancée',
    _ => 'Inconnu',
  };

  String _gpsSourceLabel(String? source) => switch (source) {
    'realtime' => '📡 Temps réel',
    'exif' => '📷 Métadonnées EXIF',
    'none' => '❌ Non disponible',
    _ => 'Inconnu',
  };

  String _statusLabel(AnalysisStatus status) => switch (status) {
    AnalysisStatus.complete => '✅ Complète',
    AnalysisStatus.pending => '⏳ En attente',
    AnalysisStatus.failed => '❌ Échouée',
  };
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white38, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
