import 'dart:io';
import 'dart:convert';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'ai_service.dart';

/// Provider cloud Gemini (Option A — fallback ou futur Pixel 11)
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
    _model = GenerativeModel(
      model: 'gemini-1.5-flash',
      apiKey: apiKey,
    );
  }

  @override
  Future<AudioGuideResult> analyzeImage(File imageFile) async {
    if (_model == null) await initialize();

    final bytes = await imageFile.readAsBytes();
    final prompt = '''
Tu es un guide audio culturel expert. Analyse cette image et génère un commentaire audio.

Réponds UNIQUEMENT en JSON avec ce format exact :
{
  "title": "Nom court du lieu ou de l'objet (max 5 mots)",
  "location": "Ville ou pays si identifiable, sinon null",
  "script": "Commentaire audio de 3-4 phrases, ton chaleureux et informatif, comme un vrai guide. Commence directement par décrire ce que tu vois."
}
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
      final jsonStr = text.replaceAll('```json', '').replaceAll('```', '').trim();
      final json = jsonDecode(jsonStr);
      return AudioGuideResult(
        title: json['title'] ?? 'Lieu inconnu',
        script: json['script'] ?? text,
        locationName: json['location'],
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
