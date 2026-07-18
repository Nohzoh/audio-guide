import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'remote_config_service.dart';

class GeminiTtsService {
  final String apiKey;
  Function()? onComplete;
  bool _isPlaying = false;

  bool get isPlaying => _isPlaying;

  GeminiTtsService({required this.apiKey});

  Future<void> speak(String text) async {
    final cfg = RemoteConfigService.current;

    // Add audio guide style instruction to the TTS prompt
    final styledText =
        '[Voix chaleureuse et passionnée d\'un guide de musée, '
        'ton vivant et expressif, rythme posé] $text';

    final response = await http.post(
      Uri.parse(
        '${cfg.geminiApiUrl}/models/${cfg.geminiTtsModel}:generateContent'
        '?key=$apiKey',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': styledText}
            ]
          }
        ],
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {
                'voiceName': cfg.geminiTtsVoice,
              }
            }
          }
        },
      }),
    ).timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      final error = jsonDecode(response.body);
      throw Exception(
        'Gemini TTS erreur ${response.statusCode}: '
        '${error['error']?['message'] ?? response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final audioData = data['candidates']?[0]?['content']?['parts']?[0]
        ?['inlineData']?['data'] as String?;

    if (audioData == null) {
      throw Exception('Gemini TTS: pas de données audio dans la réponse');
    }

    // Decode base64 PCM data and wrap in WAV
    final pcmBytes = base64Decode(audioData);
    final wavBytes = _pcmToWav(pcmBytes, sampleRate: 24000);

    // Write to temp file and play
    final tmpDir = await getTemporaryDirectory();
    final wavPath = p.join(tmpDir.path, 'gemini_tts_output.wav');
    await File(wavPath).writeAsBytes(wavBytes);

    _isPlaying = true;
    const channel = MethodChannel('com.audioguide/audio_player');
    channel.invokeMethod('playWav', {'path': wavPath}).then((_) {
      _isPlaying = false;
      onComplete?.call();
    });
  }

  /// Wraps raw PCM 16-bit mono data in a WAV header
  Uint8List _pcmToWav(Uint8List pcm, {int sampleRate = 24000}) {
    final dataSize = pcm.length;
    final buffer = ByteData(44 + dataSize);

    void setStr(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        buffer.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    setStr(0, 'RIFF');
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    setStr(8, 'WAVE');
    setStr(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little);   // chunk size
    buffer.setUint16(20, 1, Endian.little);    // PCM
    buffer.setUint16(22, 1, Endian.little);    // mono
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    buffer.setUint16(32, 2, Endian.little);    // block align
    buffer.setUint16(34, 16, Endian.little);   // bits per sample
    setStr(36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);

    final result = buffer.buffer.asUint8List();
    result.setRange(44, 44 + dataSize, pcm);
    return result;
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
}
