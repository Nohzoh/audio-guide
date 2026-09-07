import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiolens/services/gemini_api_service.dart';
import 'support/fake_dio_adapter.dart';

String _candidateJson(String text) => jsonEncode({
  'candidates': [
    {
      'content': {
        'parts': [
          {'text': text},
        ],
      },
    },
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses a well-formed quiz question from a valid JSON response',
      () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => (
            statusCode: 200,
            body: _candidateJson(jsonEncode({
              'question': 'En quelle année ce monument a-t-il été construit ?',
              'correctAnswer': '1889',
              'wrongAnswers': ['1789', '1900', '1850'],
            })),
          )),
    );

    final question = await service.generateQuizQuestion(script: 'La Tour Eiffel...');

    expect(question, isNotNull);
    expect(question!.question, 'En quelle année ce monument a-t-il été construit ?');
    expect(question.correctAnswer, '1889');
    expect(question.wrongAnswers, ['1789', '1900', '1850']);
  });

  test('returns null instead of throwing on a non-200 response', () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => (statusCode: 429, body: 'rate limited')),
    );

    final question = await service.generateQuizQuestion(script: 'La Tour Eiffel...');

    expect(question, isNull);
  });

  test('returns null instead of throwing on malformed JSON', () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async =>
          (statusCode: 200, body: _candidateJson('this is not json at all'))),
    );

    final question = await service.generateQuizQuestion(script: 'La Tour Eiffel...');

    expect(question, isNull);
  });

  test('returns null when fewer than 3 wrong answers are provided', () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => (
            statusCode: 200,
            body: _candidateJson(jsonEncode({
              'question': 'Quand ?',
              'correctAnswer': '1889',
              'wrongAnswers': ['1789'],
            })),
          )),
    );

    final question = await service.generateQuizQuestion(script: 'La Tour Eiffel...');

    expect(question, isNull);
  });

  test('deduplicates repeated wrong answers before checking the minimum of 3',
      () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => (
            statusCode: 200,
            body: _candidateJson(jsonEncode({
              'question': 'Quand ?',
              'correctAnswer': '1889',
              'wrongAnswers': ['1789', '1789', '1900'],
            })),
          )),
    );

    final question = await service.generateQuizQuestion(script: 'La Tour Eiffel...');

    expect(question, isNull);
  });

  test('returns null on a network error', () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => throw Exception('network down')),
    );

    final question = await service.generateQuizQuestion(script: 'La Tour Eiffel...');

    expect(question, isNull);
  });
}
