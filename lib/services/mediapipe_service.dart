import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ai_service.dart';

/// URLs des modèles Gemma disponibles via MediaPipe
const _models = {
  'gemma-2b': {
    'url': 'https://huggingface.co/litert-community/Gemma2-2B-IT/resolve/main/gemma2-2b-it-cpu-int8.bin',
    'size': 1500, // MB
    'displayName': 'Gemma 2B (Équilibré)',
  },
};

const _defaultModel = 'gemma-2b';
const _modelFileName = 'gemma2-2b-it-cpu-int8.bin';

class MediaPipeService implements AIService {
  bool _initialized = false;
  String? _modelPath;

  @override
  String get displayName => 'Gemma on-device (MediaPipe)';

  @override
  Future<bool> isAvailable() async {
    // MediaPipe LLM fonctionne sur Android API 29+ avec suffisamment de RAM
    // Le Pixel 7a est compatible
    return Platform.isAndroid;
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    _modelPath = await _getModelPath();
    _initialized = true;
  }

  Future<String> _getModelPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_modelFileName';
  }

  /// Vérifie si le modèle est déjà téléchargé
  Future<bool> isModelDownloaded() async {
    final path = await _getModelPath();
    return File(path).existsSync();
  }

  /// Télécharge le modèle avec progression
  Future<void> downloadModel({
    required Function(double progress, String status) onProgress,
  }) async {
    final modelInfo = _models[_defaultModel]!;
    final url = modelInfo['url'] as String;
    final path = await _getModelPath();

    onProgress(0, 'Connexion...');

    final request = http.Request('GET', Uri.parse(url));
    final response = await request.send();

    if (response.statusCode != 200) {
      throw Exception('Erreur téléchargement: ${response.statusCode}');
    }

    final totalBytes = response.contentLength ?? 0;
    var receivedBytes = 0;
    final file = File(path);
    final sink = file.openWrite();

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

    // Pour l'instant on utilise une analyse basée sur les métadonnées de l'image
    // L'intégration native MediaPipe se fait via un MethodChannel Android
    // qui sera implémenté dans le code natif Android
    final bytes = await imageFile.readAsBytes();
    final base64Image = base64Encode(bytes);

    // Appel au MethodChannel natif (implémenté côté Android)
    // Pour le moment on retourne un placeholder pendant le développement
    return const AudioGuideResult(
      title: 'Analyse en cours',
      script: 'Le modèle local analyse votre image. Cette fonctionnalité sera '
          'complète une fois le modèle téléchargé et l\'intégration native finalisée.',
    );
  }

  @override
  void dispose() {
    _initialized = false;
  }
}
