import 'dart:io';
import 'dart:convert';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'ai_service.dart';

class GeminiApiService implements AIService {
  final String apiKey;
  GenerativeModel? _model;

  GeminiApiService({required this.apiKey});

  @override
  String get displayName => 'Gemini (cloud)';

  @override
  Future<bool> isAvailable() async => apiKey.isNotEmpty;

  @override
  Future<void> initialize() async {
    _model = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);
  }

  @override
  Future<AudioGuideResult> analyzeImage(File imageFile) async {
    if (_model == null) await initialize();

    final bytes = await imageFile.readAsBytes();
    const prompt = '''
Tu es un guide audio culturel. Analyse cette image et génère un commentaire audio.
Réponds UNIQUEMENT en JSON:
{"title":"Nom du lieu (max 5 mots)","location":"Ville/pays ou null","script":"Commentaire 3-4 phrases, ton chaleureux."}
''';

    final content = [
      Content.multi([
        TextPart(prompt),
        DataPart('image/jpeg', bytes),
      ])
    ];

    final response = await _model!.generateContent(content);
    final text = response.text ?? '';

    try {
      final jsonStr =
          text.replaceAll('```json', '').replaceAll('```', '').trim();
      final parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      return AudioGuideResult(
        title: parsed['title'] as String? ?? 'Lieu inconnu',
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
