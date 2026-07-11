import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'ai_service.dart';
import 'remote_config_service.dart';

class GeminiApiService implements AIService {
  final String apiKey;

  GeminiApiService({required this.apiKey});

  @override
  String get displayName => 'Gemini API';

  String get providerName => 'Gemini API';

  @override
  Future<bool> isAvailable() async => apiKey.isNotEmpty;

  @override
  Future<void> initialize() async {}

  @override
  void dispose() {}

  @override
  Future<AudioGuideResult> analyzeImage(
    File imageFile, {
    String? locationContext,
  }) async {
    final cfg = RemoteConfigService.current;
    final imageBytes = await imageFile.readAsBytes();
    final base64Image = base64Encode(imageBytes);

    final contextPart = locationContext != null && locationContext.isNotEmpty
        ? '\n\nContexte et informations factuelles disponibles :\n$locationContext'
        : '';

    final prompt = 'Tu es un guide audio culturel expert et passionne. '
        'En analysant cette image$contextPart, genere un commentaire audio en francais, '
        'avec un ton chaleureux et vivant, comme si tu t\'adressais a un touriste curieux. '
        'Identifie precisement ce que tu vois (oeuvre d\'art, monument, lieu). '
        'Si tu reconnais l\'oeuvre ou le lieu, donne son nom exact, son auteur/architecte, '
        'et son contexte historique et culturel en utilisant des faits reels. '
        'Si des informations factuelles sont fournies dans le contexte, utilise-les en priorite. '
        'Structure ton commentaire : description visuelle, identification, contexte historique, '
        'anecdote ou fait marquant, conclusion emotionnelle. '
        'Vise 300 a 400 mots, ton chaleureux et passionne.';

    final url =
        '${cfg.geminiApiUrl}/models/${cfg.geminiModel}:generateContent?key=$apiKey';

    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {
            'parts': [
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data': base64Image,
                }
              },
              {'text': prompt},
            ]
          }
        ],
        'generationConfig': {
          'maxOutputTokens': cfg.geminiMaxTokens,
          'temperature': cfg.geminiTemperature,
        },
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      final error = jsonDecode(response.body);
      throw Exception(
        'Gemini API erreur ${response.statusCode}: '
        '${error['error']?['message'] ?? response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final text =
        data['candidates']?[0]?['content']?['parts']?[0]?['text'] as String?;

    if (text == null || text.isEmpty) {
      throw Exception('Gemini API reponse vide');
    }

    final firstSentence = text.split(RegExp(r'[.!?]')).first.trim();
    final title = firstSentence.length > 60
        ? '${firstSentence.substring(0, 60)}...'
        : firstSentence;

    return AudioGuideResult(title: title, script: text);
  }
}
