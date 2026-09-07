/// #343: a text-comprehension quiz question generated from an already
/// -existing history entry's script — see
/// `GeminiApiService.generateQuizQuestion`.
class QuizQuestion {
  final String question;
  final String correctAnswer;

  /// Exactly 3 plausible-but-wrong answers.
  final List<String> wrongAnswers;

  const QuizQuestion({
    required this.question,
    required this.correctAnswer,
    required this.wrongAnswers,
  });
}
