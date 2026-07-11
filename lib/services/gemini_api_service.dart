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
        'En analysant cette image$contextPart, genere un commentaire audio en francais. '
        'REGLES ABSOLUES : '
        '1. Texte brut uniquement, ZERO markdown, ZERO asterisque, ZERO mise en forme. '
        '2. Commence directement par la description, sans formule de bienvenue ni introduction. '
        '3. Identifie precisement ce que tu vois. Si tu reconnais l\u0027oeuvre ou le lieu, '
        'nomme-le explicitement avec son auteur et son contexte historique reel. '
        '4. Si des informations factuelles sont fournies dans le contexte, utilise-les en priorite. '
        '5. Structure : description visuelle (2-3 phrases), identification et histoire (3-4 phrases), '
        'anecdote marquante (2-3 phrases), conclusion emotionnelle (2 phrases). '
        '6. Vise 350 a 450 mots. Ton chaleureux, vivant, passionne.';

    // Try primary model then fallbacks on 429
    final modelsToTry = [
      cfg.geminiModel,
      ...cfg.geminiModelFallbacks.where((m) => m != cfg.geminiModel),
    ];

    http.Response? response;
    String? lastError;

    for (final model in modelsToTry) {
      final url =
          '${cfg.geminiApiUrl}/models/$model:generateContent?key=$apiKey';

      final resp = await http.post(
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

      if (resp.statusCode == 200) {
        response = resp;
        break;
      } else if (resp.statusCode == 429 || resp.statusCode == 404 || resp.statusCode == 503) {
        // Quota exceeded, model unavailable, or overloaded — try next model
        final err = jsonDecode(resp.body);
        lastError = err['error']?['message'] ?? 'Quota exceeded';
        continue;
      } else {
        final err = jsonDecode(resp.body);
        throw Exception(
          'Gemini API erreur ${resp.statusCode}: '
          '${err['error']?['message'] ?? resp.body}',
        );
      }
    }

    if (response == null) {
      throw Exception('Tous les modèles Gemini sont en quota: $lastError');
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
