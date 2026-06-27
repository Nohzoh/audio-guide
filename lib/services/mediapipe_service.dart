import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'ai_service.dart';

const _modelDownloadUrl =
    'https://huggingface.co/litert-community/Gemma2-2B-IT/resolve/main/gemma2-2b-it-cpu-int8.bin';
const _modelFileName = 'gemma2-2b-it-cpu-int8.bin';

class MediaPipeService implements AIService {
  bool _initialized = false;

  @override
  String get displayName => 'Gemma on-device (MediaPipe)';

  @override
  Future<bool> isAvailable() async => Platform.isAndroid;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
  }

  Future<String> _getModelPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_modelFileName';
  }

  Future<bool> isModelDownloaded() async {
    final path = await _getModelPath();
    return File(path).existsSync();
  }

  Future<void> downloadModel({
    required Function(double progress, String status) onProgress,
  }) async {
    final path = await _getModelPath();
    onProgress(0, 'Connexion...');

    final request = http.Request('GET', Uri.parse(_modelDownloadUrl));
    final response = await request.send();

    if (response.statusCode != 200) {
      throw Exception('Erreur téléchargement: ${response.statusCode}');
    }

    final totalBytes = response.contentLength ?? 0;
    var receivedBytes = 0;
    final sink = File(path).openWrite();

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
    // Placeholder — full MediaPipe native binding in next iteration
    return const AudioGuideResult(
      title: 'Analyse locale',
      script:
          'Le modèle local analyse votre image. Intégration native MediaPipe en cours de développement.',
    );
  }

  @override
  void dispose() {
    _initialized = false;
  }
}
