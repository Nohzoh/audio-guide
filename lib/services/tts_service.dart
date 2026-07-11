import 'dart:io';
import 'dart:isolate';
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
    if (!Directory(dataDirPath).existsSync()) {
      if (Directory(ttsDir).existsSync()) {
        await Directory(ttsDir).delete(recursive: true);
      }
    }

    // Extract assets in background isolate to avoid freezing UI
    await _extractAssetsBackground(ttsDir);

    final modelPath = p.join(ttsDir, 'fr_FR-miro-high.onnx');
    final tokensPath = p.join(ttsDir, 'tokens.txt');

    if (!File(modelPath).existsSync()) {
      throw Exception('TTS model not found: ');
    }
    if (!Directory(dataDirPath).existsSync()) {
      final extracted = Directory(ttsDir).listSync().map((e) => e.path.split('/').last).join(', ');
      throw Exception('espeak-ng-data not found. Extracted: ');
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

    // Create TTS in background to avoid freezing
    _tts = await _createTtsInBackground(config);
    _initialized = true;
  }

  // Extract assets using rootBundle (must stay on main isolate)
  // but we do it async to avoid blocking
  Future<void> _extractAssetsBackground(String targetDir) async {
    final modelFile = File(p.join(targetDir, 'fr_FR-miro-high.onnx'));
    if (await modelFile.exists() &&
        Directory(p.join(targetDir, 'espeak-ng-data')).existsSync()) {
      return;
    }

    await Directory(targetDir).create(recursive: true);

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final ttsAssets = manifest.listAssets()
        .where((a) => a.startsWith('assets/tts/'))
        .toList();

    for (final asset in ttsAssets) {
      var relativePath = asset.replaceFirst('assets/tts/', '');
      if (relativePath.isEmpty) continue;
      relativePath = Uri.decodeComponent(relativePath);
      if (relativePath.endsWith('/')) continue;

      final targetPath = p.join(targetDir, relativePath);
      await Directory(p.dirname(targetPath)).create(recursive: true);

      try {
        final data = await rootBundle.load(asset);
        await File(targetPath).writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } catch (_) {}

      // Yield to UI thread periodically
      await Future.delayed(Duration.zero);
    }
  }

  // Create OfflineTts in a separate isolate to avoid freezing
  static Future<sherpa.OfflineTts> _createTtsInBackground(
      sherpa.OfflineTtsConfig config) async {
    // sherpa.OfflineTts creation can be slow - run in isolate
    return await Isolate.run(() {
      sherpa.initBindings();
      return sherpa.OfflineTts(config);
    });
  }

  Future<void> speak(String text) async {
    if (!_initialized) await initialize();
    final tts = _tts;
    if (tts == null) return;

    _isPlaying = true;

    // Generate audio in background isolate
    final tmpDir = await getTemporaryDirectory();
    final wavPath = p.join(tmpDir.path, 'tts_output.wav');

    await _generateInBackground(tts, text, wavPath);

    // Play (non-blocking - completion handled via callback)
    const channel = MethodChannel('com.audioguide/audio_player');
    channel.invokeMethod('playWav', {'path': wavPath}).then((_) {
      _isPlaying = false;
      onComplete?.call();
    });
  }

  static Future<void> _generateInBackground(
      sherpa.OfflineTts tts, String text, String wavPath) async {
    await Isolate.run(() {
      sherpa.initBindings();
      final genConfig = sherpa.OfflineTtsGenerationConfig(
        sid: 0,
        speed: 0.9,
      );
      final audio = tts.generateWithConfig(text: text, config: genConfig);
      sherpa.writeWave(
        filename: wavPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );
    });
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
