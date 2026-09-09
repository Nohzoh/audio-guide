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

String _questionsBody(List<Map<String, dynamic>> questions) =>
    _candidateJson(jsonEncode({'questions': questions}));

Map<String, dynamic> _question({
  String question = 'En quelle année ce monument a-t-il été construit ?',
  String correctAnswer = '1889',
  List<String> wrongAnswers = const ['1789', '1900', '1850'],
}) =>
    {
      'question': question,
      'correctAnswer': correctAnswer,
      'wrongAnswers': wrongAnswers,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses a batch of well-formed quiz questions from a valid JSON response',
      () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => (
            statusCode: 200,
            body: _questionsBody([
              _question(),
              _question(question: 'Où se trouve-t-il ?', correctAnswer: 'Paris'),
            ]),
          )),
    );

    final questions = await service.generateQuizQuestions(script: 'La Tour Eiffel...');

    expect(questions, hasLength(2));
    expect(questions[0].question, 'En quelle année ce monument a-t-il été construit ?');
    expect(questions[0].correctAnswer, '1889');
    expect(questions[0].wrongAnswers, ['1789', '1900', '1850']);
    expect(questions[1].question, 'Où se trouve-t-il ?');
    expect(questions[1].correctAnswer, 'Paris');
  });

  test('returns an empty list instead of throwing on a non-200 response', () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => (statusCode: 429, body: 'rate limited')),
    );

    final questions = await service.generateQuizQuestions(script: 'La Tour Eiffel...');

    expect(questions, isEmpty);
  });

  test('returns an empty list instead of throwing on malformed JSON', () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async =>
          (statusCode: 200, body: _candidateJson('this is not json at all'))),
    );

    final questions = await service.generateQuizQuestions(script: 'La Tour Eiffel...');

    expect(questions, isEmpty);
  });

  test('drops individual questions with fewer than 3 wrong answers but keeps '
      'the rest of the batch', () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => (
            statusCode: 200,
            body: _questionsBody([
              _question(question: 'Quand ?', wrongAnswers: ['1789']),
              _question(question: 'Où ?', correctAnswer: 'Paris'),
            ]),
          )),
    );

    final questions = await service.generateQuizQuestions(script: 'La Tour Eiffel...');

    expect(questions, hasLength(1));
    expect(questions.single.question, 'Où ?');
  });

  test('deduplicates repeated wrong answers before checking the minimum of 3',
      () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => (
            statusCode: 200,
            body: _questionsBody([
              _question(question: 'Quand ?', wrongAnswers: ['1789', '1789', '1900']),
            ]),
          )),
    );

    final questions = await service.generateQuizQuestions(script: 'La Tour Eiffel...');

    expect(questions, isEmpty);
  });

  test('returns an empty list when the response has no "questions" array',
      () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => (
            statusCode: 200,
            body: _candidateJson(jsonEncode(_question())),
          )),
    );

    final questions = await service.generateQuizQuestions(script: 'La Tour Eiffel...');

    expect(questions, isEmpty);
  });

  test('returns an empty list on a network error', () async {
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async => throw Exception('network down')),
    );

    final questions = await service.generateQuizQuestions(script: 'La Tour Eiffel...');

    expect(questions, isEmpty);
  });
}
