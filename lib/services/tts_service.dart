import 'dart:io';
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

    final dir = await getApplicationDocumentsDirectory();
    final ttsDir = p.join(dir.path, 'tts');
    await _extractAssets(ttsDir);

    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: p.join(ttsDir, 'fr_FR-miro-high.onnx'),
          tokens: p.join(ttsDir, 'tokens.txt'),
          dataDir: p.join(ttsDir, 'espeak-ng-data'),
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
      ruleFsts: '',
      maxNumSentences: 1,
    );

    _tts = sherpa.OfflineTts(config);
    _initialized = true;
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

    final audio = tts.generate(text: text, sid: 0, speed: 0.9);
    final wav = _encodeWav(audio.samples, audio.sampleRate);

    final tmpDir = await getTemporaryDirectory();
    final file = File(p.join(tmpDir.path, 'tts_output.wav'));
    await file.writeAsBytes(wav);

    const channel = MethodChannel('com.audioguide/audio_player');
    await channel.invokeMethod('playWav', {'path': file.path});

    _isPlaying = false;
    onComplete?.call();
  }

  List<int> _encodeWav(List<double> samples, int sampleRate) {
    final dataSize = samples.length * 2;
    final buffer = ByteData(44 + dataSize);
    void setStr(int offset, String s) {
      for (int i = 0; i < s.length; i++) buffer.setUint8(offset + i, s.codeUnitAt(i));
    }
    setStr(0, 'RIFF');
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    setStr(8, 'WAVE');
    setStr(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, 1, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little);
    buffer.setUint16(32, 2, Endian.little);
    buffer.setUint16(34, 16, Endian.little);
    setStr(36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);
    for (int i = 0; i < samples.length; i++) {
      buffer.setInt16(44 + i * 2,
          (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
    }
    return buffer.buffer.asUint8List();
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
