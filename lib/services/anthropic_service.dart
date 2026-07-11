import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ai_service.dart';

class AnthropicService implements AIService {
  final String apiKey;

  AnthropicService({required this.apiKey});

  @override
  String get displayName => 'Claude (Anthropic)';

  @override
  Future<bool> isAvailable() async => apiKey.isNotEmpty;

  @override
  Future<void> initialize() async {}

  @override
  Future<AudioGuideResult> analyzeImage(File imageFile, {String? locationContext}) async {
    final bytes = await imageFile.readAsBytes();
    final base64Image = base64Encode(bytes);

    final response = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': 'claude-haiku-4-5-20251001',
        'max_tokens': 512,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/jpeg',
                  'data': base64Image,
                },
              },
              {
                'type': 'text',
                'text': '''Tu es un guide audio culturel expert. Analyse cette image et génère un commentaire audio.
Réponds UNIQUEMENT en JSON valide, sans markdown :
{"title":"Nom du lieu ou objet (max 5 mots)","location":"Ville ou pays si identifiable, sinon null","script":"Commentaire de 3-4 phrases, ton chaleureux et informatif. Commence directement par décrire ce que tu vois."}''',
              },
            ],
          }
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Erreur API: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body);
    final text = data['content'][0]['text'] as String;

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
  void dispose() {}
}
