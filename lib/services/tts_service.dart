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
    await _extractAssets(ttsDir);

    final modelPath = p.join(ttsDir, 'fr_FR-miro-high.onnx');
    final tokensPath = p.join(ttsDir, 'tokens.txt');
    final dataDirPath = p.join(ttsDir, 'espeak-ng-data');

    // Verify files exist
    if (!File(modelPath).existsSync()) {
      throw Exception('TTS model not found at $modelPath. '
        'ttsDir: $ttsDir, '
        'exists: ${Directory(ttsDir).existsSync()}');
    }

    final vits = sherpa.OfflineTtsVitsModelConfig(
      model: modelPath,
      tokens: tokensPath,
      dataDir: dataDirPath,
    );

    final modelConfig = sherpa.OfflineTtsModelConfig(
      vits: vits,
      numThreads: 2,
      debug: true,
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
      throw Exception('Failed to create TTS: $e. '
          'model=$modelPath, '
          'tokens=$tokensPath, '
          'dataDir=$dataDirPath, '
          'modelExists=${File(modelPath).existsSync()}, '
          'tokensExists=${File(tokensPath).existsSync()}, '
          'dataDirExists=${Directory(dataDirPath).existsSync()}');
    }
  }

  Future<void> _extractAssets(String targetDir) async {
    final modelFile = File(p.join(targetDir, 'fr_FR-miro-high.onnx'));
    if (await modelFile.exists()) return;

    await Directory(targetDir).create(recursive: true);

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets()
        .where((a) => a.startsWith('assets/tts/'));

    for (final asset in assets) {
      final relativePath = asset.replaceFirst('assets/tts/', '');
      if (relativePath.isEmpty) continue;
      final targetPath = p.join(targetDir, relativePath);
      await Directory(p.dirname(targetPath)).create(recursive: true);
      final data = await rootBundle.load(asset);
      await File(targetPath).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
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

    // Write WAV to temp file using sherpa's built-in function
    final tmpDir = await getTemporaryDirectory();
    final wavPath = p.join(tmpDir.path, 'tts_output.wav');
    sherpa.writeWave(
      filename: wavPath,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );

    // Play via MediaPlayer
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
