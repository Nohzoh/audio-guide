import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class TtsService {
  sherpa.OfflineTts? _tts;
  bool _initialized = false;
  bool _isPlaying = false;
  Function()? onComplete;

  bool get isPlaying => _isPlaying;

  Future<void> initialize() async {
    if (_initialized) return;

    sherpa.initBindings();

    final dir = await getApplicationDocumentsDirectory();
    final ttsDir = p.join(dir.path, 'tts');

    // Force re-extract if espeak-ng-data is missing
    final dataDirPath = p.join(ttsDir, 'espeak-ng-data');
    final modelPath = p.join(ttsDir, 'fr_FR-miro-high.onnx');
    if (!Directory(dataDirPath).existsSync()) {
      // Delete and re-extract everything
      if (Directory(ttsDir).existsSync()) {
        await Directory(ttsDir).delete(recursive: true);
      }
    }

    await _extractAssets(ttsDir);

    final tokensPath = p.join(ttsDir, 'tokens.txt');

    if (!File(modelPath).existsSync()) {
      throw Exception('TTS model not found: ');
    }
    if (!Directory(dataDirPath).existsSync()) {
      throw Exception('espeak-ng-data not found: . '
          'Assets extracted: ${await _listExtracted(ttsDir)}');
    }

    final vits = sherpa.OfflineTtsVitsModelConfig(
      model: modelPath,
      tokens: tokensPath,
      dataDir: dataDirPath,
    );

    final modelConfig = sherpa.OfflineTtsModelConfig(
      vits: vits,
      numThreads: 2,
      debug: false,
      provider: 'cpu',
    );

    final config = sherpa.OfflineTtsConfig(
      model: modelConfig,
      maxNumSenetences: 1,
    );

    try {
      _tts = sherpa.OfflineTts(config);
      _initialized = true;
    } catch (e) {
      throw Exception('Failed to create TTS: $e');
    }
  }

  Future<String> _listExtracted(String dir) async {
    try {
      final entities = Directory(dir).listSync(recursive: false);
      return entities.map((e) => e.path.split('/').last).join(', ');
    } catch (_) {
      return 'error listing';
    }
  }

  Future<void> _extractAssets(String targetDir) async {
    final modelFile = File(p.join(targetDir, 'fr_FR-miro-high.onnx'));
    if (await modelFile.exists() &&
        Directory(p.join(targetDir, 'espeak-ng-data')).existsSync()) {
      return;
    }

    await Directory(targetDir).create(recursive: true);

    // Use AssetBundle to list and extract all tts assets
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final allAssets = manifest.listAssets();
    final ttsAssets = allAssets.where((a) => a.startsWith('assets/tts/')).toList();

    for (final asset in ttsAssets) {
      // Remove 'assets/tts/' prefix
      var relativePath = asset.replaceFirst('assets/tts/', '');
      if (relativePath.isEmpty) continue;

      // URL decode the path (assets with spaces are URL-encoded)
      relativePath = Uri.decodeComponent(relativePath);

      final targetPath = p.join(targetDir, relativePath);
      final targetFile = File(targetPath);

      // Create parent directory
      await Directory(p.dirname(targetPath)).create(recursive: true);

      // Only write if it's a file (not a directory entry)
      if (!relativePath.endsWith('/')) {
        try {
          final data = await rootBundle.load(asset);
          await targetFile.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
        } catch (e) {
          // Skip files that can't be loaded
        }
      }
    }
  }

  Future<void> speak(String text) async {
    if (!_initialized) await initialize();
    final tts = _tts;
    if (tts == null) return;

    _isPlaying = true;

    final genConfig = sherpa.OfflineTtsGenerationConfig(
      sid: 0,
      speed: 0.9,
    );

    final audio = tts.generateWithConfig(text: text, config: genConfig);

    final tmpDir = await getTemporaryDirectory();
    final wavPath = p.join(tmpDir.path, 'tts_output.wav');
    sherpa.writeWave(
      filename: wavPath,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );

    const channel = MethodChannel('com.audioguide/audio_player');
    await channel.invokeMethod('playWav', {'path': wavPath});

    _isPlaying = false;
    onComplete?.call();
  }

  Future<void> pause() async {
    const channel = MethodChannel('com.audioguide/audio_player');
    await channel.invokeMethod('pause');
    _isPlaying = false;
  }

  Future<void> stop() async {
    const channel = MethodChannel('com.audioguide/audio_player');
    await channel.invokeMethod('stop');
    _isPlaying = false;
  }

  void dispose() {
    _tts?.free();
    _tts = null;
    _initialized = false;
  }
}
