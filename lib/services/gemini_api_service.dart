import 'dart:io';
import 'dart:convert';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'ai_service.dart';

class GeminiApiService implements AIService {
  final String apiKey;
  GenerativeModel? _model;

  GeminiApiService({required this.apiKey});

  @override
  String get displayName => 'Gemini 1.5 Flash (cloud)';

  @override
  Future<bool> isAvailable() async => apiKey.isNotEmpty;

  @override
  Future<void> initialize() async {
    _model = GenerativeModel(model: 'gemini-1.5-flash-latest', apiKey: apiKey);
  }

  @override
  Future<AudioGuideResult> analyzeImage(File imageFile) async {
    if (_model == null) await initialize();

    final bytes = await imageFile.readAsBytes();
    const prompt = '''
Tu es un guide audio culturel expert. Analyse cette image et génère un commentaire audio.
Réponds UNIQUEMENT en JSON valide, sans markdown :
{"title":"Nom du lieu ou objet (max 5 mots)","location":"Ville ou pays si identifiable, sinon null","script":"Commentaire de 3-4 phrases, ton chaleureux et informatif. Commence directement par décrire ce que tu vois."}
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
