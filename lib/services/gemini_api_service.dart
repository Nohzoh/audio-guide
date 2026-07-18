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
        'Redige le script d\'un audio-guide pour cette oeuvre ou ce lieu$contextPart. '
        'Style : narratif et immersif, tu t\'adresses directement au visiteur avec "vous". '
        'Tu construis une dramaturgie : accroche saisissante, details techniques fascinants, '
        'contexte historique vivant, anecdote marquante, conclusion emotionnelle. '
        'Si tu reconnais precisement l\'oeuvre ou le lieu, nomme-le et utilise des faits reels. '
        'Si des informations factuelles sont disponibles dans le contexte, utilise-les. '
        'Ecris entre 300 et 400 mots, en francais, sans aucune mise en forme ni asterisque.';

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
            'thinkingConfig': {'thinkingBudget': 1024, 'includeThoughts': false},
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
        // Remove bold/italic markers
        .replaceAll(RegExp(r'\*{1,3}'), '')
        // Remove bullet points
        .replaceAll(RegExp(r'^\s*[-•]\s+', multiLine: true), '')
        // Remove word count annotations like (23) (15)
        .replaceAll(RegExp(r'\s*\(\d+\)'), '')
        // Remove headers
        .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
        // Remove thinking preambles in English
        .replaceAll(RegExp(r'^.*?(rough estimate|word count|paragraph \d|let\'s|okay|alright)[^\n]*\n',
            multiLine: true, caseSensitive: false), '')
        // Collapse multiple blank lines
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return result;
  }
}
