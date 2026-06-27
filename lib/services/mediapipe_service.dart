import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'ai_service.dart';

const _channel = MethodChannel('com.audioguide/mediapipe');

const _modelUrl =
    'https://huggingface.co/litert-community/Gemma3-1B-IT-INT4/resolve/main/gemma3-1b-it-int4.task';
const _modelFileName = 'gemma3-1b-multimodal.task';

class MediaPipeService implements AIService {
  bool _initialized = false;

  @override
  String get displayName => 'Gemma 3 1B (on-device)';

  @override
  Future<bool> isAvailable() async => Platform.isAndroid;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await _channel.invokeMethod('loadModel');
    _initialized = true;
  }

  Future<bool> isModelDownloaded() async {
    final result = await _channel.invokeMethod<bool>('isModelDownloaded');
    return result ?? false;
  }

  Future<String> getModelPath() async {
    final result = await _channel.invokeMethod<String>('getModelPath');
    return result ?? '';
  }

  Future<void> downloadModel({
    required Function(double progress, String status) onProgress,
  }) async {
    final modelPath = await getModelPath();
    onProgress(0, 'Connexion...');

    final request = http.Request('GET', Uri.parse(_modelUrl));
    final response = await request.send();

    if (response.statusCode != 200) {
      throw Exception('Erreur téléchargement: ${response.statusCode}');
    }

    final totalBytes = response.contentLength ?? 0;
    var receivedBytes = 0;
    final sink = File(modelPath).openWrite();

    onProgress(0, 'Téléchargement du modèle...');

    await for (final chunk in response.stream) {
      sink.add(chunk);
      receivedBytes += chunk.length;
      if (totalBytes > 0) {
        final progress = receivedBytes / totalBytes;
        final downloaded = (receivedBytes / 1024 / 1024).toStringAsFixed(0);
        final total = (totalBytes / 1024 / 1024).toStringAsFixed(0);
        onProgress(progress, '$downloaded MB / $total MB');
      }
    }

    await sink.close();
    onProgress(1.0, 'Modèle prêt !');
  }

  @override
  Future<AudioGuideResult> analyzeImage(File imageFile) async {
    if (!_initialized) await initialize();

    try {
      final response = await _channel.invokeMethod<String>('analyzeImage', {
        'imagePath': imageFile.path,
      });

      final text = response ?? '';

      // Extract title from first sentence
      final sentences = text.split('. ');
      final title = sentences.isNotEmpty
          ? sentences.first.replaceAll(RegExp(r'[^a-zA-ZÀ-ÿ0-9\s]'), '').trim()
          : 'Lieu analysé';

      return AudioGuideResult(
        title: title.length > 40 ? '${title.substring(0, 40)}...' : title,
        script: text,
      );
    } on PlatformException catch (e) {
      throw Exception('Erreur MediaPipe: ${e.message}');
    }
  }

  @override
  void dispose() {
    _initialized = false;
  }
}
