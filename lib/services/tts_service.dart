import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'remote_config_service.dart';

class TtsService {
  sherpa.OfflineTts? _tts;
  bool _initialized = false;
  bool _isPlaying = false;
  Function()? onComplete;

  // Sentence-level progress: 0.0 to 1.0
  Function(double progress)? onProgress;

  bool get isPlaying => _isPlaying;

  Future<void> initialize() async {
    if (_initialized) return;

    sherpa.initBindings();

    final dir = await getApplicationDocumentsDirectory();
    final ttsDir = p.join(dir.path, 'tts');

    final dataDirPath = p.join(ttsDir, 'espeak-ng-data');
    if (!Directory(dataDirPath).existsSync()) {
      if (Directory(ttsDir).existsSync()) {
        await Directory(ttsDir).delete(recursive: true);
      }
    }

    await _extractAssetsBackground(ttsDir);

    final modelPath = p.join(ttsDir, 'fr_FR-miro-high.onnx');
    final tokensPath = p.join(ttsDir, 'tokens.txt');

    if (!File(modelPath).existsSync()) {
      throw Exception('TTS model not found: $modelPath');
    }
    if (!Directory(dataDirPath).existsSync()) {
      final extracted = Directory(ttsDir).listSync().map((e) => e.path.split('/').last).join(', ');
      throw Exception('espeak-ng-data not found. Extracted: $extracted');
    }

    final vits = sherpa.OfflineTtsVitsModelConfig(
      model: modelPath,
      tokens: tokensPath,
      dataDir: dataDirPath,
    );

    final modelConfig = sherpa.OfflineTtsModelConfig(
      vits: vits,
      numThreads: RemoteConfigService.current.ttsNumThreads,
      debug: false,
      provider: 'cpu',
    );

    final config = sherpa.OfflineTtsConfig(
      model: modelConfig,
      maxNumSenetences: 1,
    );

    _tts = await _createTtsInBackground(config);
    _initialized = true;
  }

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

      await Future.delayed(Duration.zero);
    }
  }

  static Future<sherpa.OfflineTts> _createTtsInBackground(
      sherpa.OfflineTtsConfig config) async {
    return await Isolate.run(() {
      sherpa.initBindings();
      return sherpa.OfflineTts(config);
    });
  }

  /// Split text into sentences for progress tracking
  static List<String> _splitSentences(String text) {
    // Split on . ! ? followed by space or end
    final parts = text.split(RegExp(r'(?<=[.!?])\s+'));
    return parts.where((s) => s.trim().isNotEmpty).toList();
  }

  Future<void> speak(String text) async {
    if (!_initialized) await initialize();
    final tts = _tts;
    if (tts == null) return;

    _isPlaying = true;

    final sentences = _splitSentences(text);
    final totalChars = text.length;

    // Generate full audio in background
    final tmpDir = await getTemporaryDirectory();
    final wavPath = p.join(tmpDir.path, 'tts_output.wav');

    final sampleRate = await _generateInBackground(tts, text, wavPath);

    // Estimate duration per sentence proportional to char count
    // We'll get real duration from the WAV file
    final wavFile = File(wavPath);
    final wavBytes = await wavFile.readAsBytes();
    // WAV: data size at offset 40 (4 bytes LE), sample rate at 24
    final dataSize = wavBytes.buffer.asByteData().getUint32(40, Endian.little);
    final sr = wavBytes.buffer.asByteData().getUint32(24, Endian.little);
    final totalDurationMs = (dataSize / (sr * 2) * 1000).round();

    // Start playback (non-blocking)
    const channel = MethodChannel('com.audioguide/audio_player');
    channel.invokeMethod('playWav', {'path': wavPath}).then((_) {
      _isPlaying = false;
      onComplete?.call();
    });

    // Drive sentence-level progress while audio plays
    _driveSentenceProgress(sentences, totalChars, totalDurationMs);
  }

  void _driveSentenceProgress(
      List<String> sentences, int totalChars, int totalDurationMs) async {
    if (sentences.isEmpty || totalDurationMs <= 0) return;

    int elapsed = 0;
    int charsSoFar = 0;

    for (int i = 0; i < sentences.length; i++) {
      if (!_isPlaying) break;

      // Report progress at start of each sentence
      final progress = charsSoFar / totalChars;
      onProgress?.call(progress.clamp(0.0, 1.0));

      // Wait proportional to this sentence's char count
      final sentenceChars = sentences[i].length;
      final sentenceDuration = (sentenceChars / totalChars * totalDurationMs).round();

      await Future.delayed(Duration(milliseconds: sentenceDuration));
      charsSoFar += sentenceChars + 1; // +1 for space
    }

    // Final progress
    if (_isPlaying) onProgress?.call(1.0);
  }

  static Future<int> _generateInBackground(
      sherpa.OfflineTts tts, String text, String wavPath) async {
    return await Isolate.run(() {
      sherpa.initBindings();
      final genConfig = sherpa.OfflineTtsGenerationConfig(
        sid: RemoteConfigService.current.ttsSid,
        speed: RemoteConfigService.current.ttsSpeed
    );
      final audio = tts.generateWithConfig(text: text, config: genConfig);
      sherpa.writeWave(
        filename: wavPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );
      return audio.sampleRate;
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
