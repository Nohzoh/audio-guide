import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'ai_service.dart';

class GeminiApiService implements AIService {
  final String apiKey;

  GeminiApiService({required this.apiKey});

  @override
  String get providerName => 'Gemini API';

  @override
  Future<AudioGuideResult> analyzeImage(
    File imageFile, {
    String? locationContext,
  }) async {
    final imageBytes = await imageFile.readAsBytes();
    final base64Image = base64Encode(imageBytes);

    final contextPart = locationContext != null && locationContext.isNotEmpty
        ? '\n\nContexte et informations factuelles disponibles :\n$locationContext'
        : '';

    final prompt = '''Tu es un guide audio culturel expert et passionné. '
En analysant cette image$contextPart, génère un commentaire audio en français, '
avec un ton chaleureux et vivant, comme si tu t\'adressais à un touriste curieux. '
Identifie précisément ce que tu vois (œuvre d\'art, monument, lieu). '
Si tu reconnais l\'œuvre ou le lieu, donne son nom exact, son auteur/architecte, '
et son contexte historique et culturel en utilisant des faits réels. '
Si des informations factuelles sont fournies dans le contexte, utilise-les en priorité. '
Structure ton commentaire : description visuelle, identification, contexte historique, '
anecdote ou fait marquant, conclusion émotionnelle. '
Vise 300 à 400 mots, ton chaleureux et passionné.''';

    final response = await http.post(
      Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/'
        'gemini-1.5-flash:generateContent?key=$apiKey',
      ),
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
          'maxOutputTokens': 1024,
          'temperature': 0.7,
        },
      }),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      final error = jsonDecode(response.body);
      throw Exception(
        'Gemini API error ${response.statusCode}: '
        '${error['error']?['message'] ?? response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final text = data['candidates']?[0]?['content']?['parts']?[0]?['text']
        as String?;

    if (text == null || text.isEmpty) {
      throw Exception('Gemini API returned empty response');
    }

    // Extract title (first sentence)
    final firstSentence = text.split(RegExp(r'[.!?]')).first.trim();
    final title = firstSentence.length > 60
        ? '${firstSentence.substring(0, 60)}...'
        : firstSentence;

    return AudioGuideResult(title: title, script: text);
  }
}
