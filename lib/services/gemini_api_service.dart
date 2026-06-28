import 'dart:io';
import 'dart:convert';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'ai_service.dart';

// Models to try in order of preference
const _models = [
  'gemini-1.5-flash',
  'gemini-1.0-pro-vision-latest',
  'gemini-pro-vision',
];

class GeminiApiService implements AIService {
  final String apiKey;
  GenerativeModel? _model;
  String _currentModel = _models[0];

  GeminiApiService({required this.apiKey});

  @override
  String get displayName => 'Gemini ($_currentModel)';

  @override
  Future<bool> isAvailable() async => apiKey.isNotEmpty;

  @override
  Future<void> initialize() async {
    _model = GenerativeModel(model: _currentModel, apiKey: apiKey);
  }

  @override
  Future<AudioGuideResult> analyzeImage(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    const prompt = '''
Tu es un guide audio culturel expert. Analyse cette image et génère un commentaire audio.
Réponds UNIQUEMENT en JSON valide, sans markdown :
{"title":"Nom du lieu ou objet (max 5 mots)","location":"Ville ou pays si identifiable, sinon null","script":"Commentaire de 3-4 phrases, ton chaleureux et informatif. Commence directement par décrire ce que tu vois."}
''';

    // Try each model until one works
    for (final modelName in _models) {
      try {
        _currentModel = modelName;
        final model = GenerativeModel(model: modelName, apiKey: apiKey);
        final content = [
          Content.multi([
            TextPart(prompt),
            DataPart('image/jpeg', bytes),
          ])
        ];
        final response = await model.generateContent(content);
        final text = response.text ?? '';
        _model = model;
        return _parseResponse(text);
      } catch (e) {
        final err = e.toString();
        // If permission or not found, try next model
        if (err.contains('permission') || err.contains('not found') || 
            err.contains('404') || err.contains('403')) {
          continue;
        }
        // Other errors (quota, network) — rethrow
        rethrow;
      }
    }
    throw Exception('Aucun modèle Gemini disponible avec cette clé API');
  }

  AudioGuideResult _parseResponse(String text) {
    try {
      final jsonStr = text.replaceAll('```json', '').replaceAll('```', '').trim();
      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      return AudioGuideResult(
        title: parsed['title'] as String? ?? 'Lieu analysé',
        script: parsed['script'] as String? ?? text,
        locationName: parsed['location'] as String?,
      );
    } catch (_) {
      return AudioGuideResult(title: 'Analyse', script: text);
    }
  }

  @override
  void dispose() {
    _model = null;
  }
}
