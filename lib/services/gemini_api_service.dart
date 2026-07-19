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

    final prompt = 'Tu es un guide audio de musee, passionne et erudit. '
        'Redige deux choses en JSON valide uniquement, sans markdown : '
        '{"title": "titre court et evocateur (5-8 mots max)", "script": "le texte du guide"} '
        'Le titre doit nommer precisement l\'oeuvre ou le lieu si reconnu, sinon evoquer ce qu\'on voit. '
        'Le script : narratif et immersif, tu t\'adresses au visiteur avec "vous". '
        'Varie toujours l\'accroche d\'ouverture : ne commence jamais par "Arrêtez-vous", '
        '"Regardez", "Devant vous", "Contemplez" ou toute formule repetitive. '
        'Sois inventif : commence par un fait surprenant, une question, une anecdote, '
        'une sensation, une date marquante, ou plonge directement dans l\'histoire. '
        'Construis : accroche originale, details fascinants, contexte historique, '
        'anecdote marquante, conclusion emotionnelle. '
        'Si tu reconnais l\'oeuvre, nomme-la avec des faits reels. '
        '$contextPart '
        'Entre 300 et 400 mots pour le script, sans mise en forme ni asterisque.';

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
            'thinkingConfig': {'thinkingBudget': cfg.geminiThinkingBudget, 'includeThoughts': false},
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
  String _cleanMarkdown(String text) {
    var result = text
        .replaceAll(RegExp(r'\*{1,3}'), '')
        .replaceAll(RegExp(r'^\s*[-•]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\s*\(\d+\)'), '')
        .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    // Remove English thinking preamble lines
    final lines = result.split('\n');
    final filtered = lines.where((line) {
      final lower = line.toLowerCase();
      return !lower.contains('rough estimate') &&
             !lower.contains('word count') &&
             !lower.startsWith("let's") &&
             !lower.startsWith('okay,') &&
             !lower.startsWith('alright,') &&
             !RegExp(r'^paragraph \d', caseSensitive: false).hasMatch(lower);
    }).toList();
    return filtered.join('\n').trim();
  }
}
