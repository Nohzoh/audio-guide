import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../models/quiz_question.dart';
import '../services/audio_guide_service.dart';
import '../services/history_service.dart';
import '../services/settings_service.dart';

/// #343: minimum number of *distinct-titled* completed entries needed
/// before a quiz is worth offering — below this there isn't enough of a
/// pool to build plausible multiple-choice distractors from.
const quizMinimumEntries = 5;

List<HistoryEntry> eligibleQuizEntries(HistoryService history) => history.entries
    .where((e) => e.status == AnalysisStatus.complete && e.title.isNotEmpty)
    .toList();

bool hasEnoughQuizEntries(HistoryService history) =>
    eligibleQuizEntries(history).map((e) => e.title).toSet().length >= quizMinimumEntries;

/// #343: a quiz screen built entirely from existing history data — no new
/// analysis, no new photo. Two question types, picked per round:
/// - "Where was this?" (always available): the photo of a past entry,
///   answer options built from other entries' titles/location names.
/// - A text-comprehension question generated from that entry's own
///   cached script (only when a Gemini API key is configured — see
///   AudioGuideService.geminiApiServiceForQuiz's doc), falling back
///   silently to the first type if generation fails for any reason.
///
/// No score/state is persisted — this is a lightweight, ungraded pastime,
/// not a tracked feature (matches the issue's "pas de nouvelle donnée à
/// générer" scope).
class QuizScreen extends StatefulWidget {
  const QuizScreen({super.key});

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  // #147-style reuse: the same bare MethodChannel HomeScreen's grid tiles
  // use for cached-audio replay (see _toggleGridPlayback there) — no
  // AudioGuideService involvement needed for replaying an already
  // -synthesized file.
  static const _audioPlayerChannel = MethodChannel('audio_guide/audio_player');
  final _random = Random();

  late final List<HistoryEntry> _eligible;
  HistoryEntry? _current;
  QuizQuestion? _textQuestion;
  List<String> _options = const [];
  String? _selected;
  bool _loadingQuestion = false;
  bool _isPlayingAudio = false;
  int _correctCount = 0;
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    _eligible = eligibleQuizEntries(context.read<HistoryService>());
    // Deferred to a post-frame callback: when no Gemini API key is
    // configured, _nextQuestion() has no real `await` before its first
    // setState() (the guess-the-place path is fully synchronous), which
    // would otherwise call setState() before the first build completes.
    WidgetsBinding.instance.addPostFrameCallback((_) => _nextQuestion());
  }

  @override
  void dispose() {
    if (_isPlayingAudio) _audioPlayerChannel.invokeMethod('stop');
    super.dispose();
  }

  Future<void> _nextQuestion() async {
    // Captured before any `await` below — reading from `context` after an
    // async gap risks a since-unmounted/disposed provider.
    final geminiApiService = context.read<AudioGuideService>().geminiApiServiceForQuiz;
    final outputLanguage = context.read<SettingsService>().outputLanguage;
    final history = context.read<HistoryService>();

    if (_isPlayingAudio) {
      await _audioPlayerChannel.invokeMethod('stop');
    }

    // Avoids immediately repeating the entry just answered, when the pool
    // is large enough to pick something else.
    final pool = _eligible.length > 1
        ? _eligible.where((e) => e.id != _current?.id).toList()
        : _eligible;
    final entry = pool[_random.nextInt(pool.length)];

    setState(() {
      _current = entry;
      _selected = null;
      _textQuestion = null;
      _options = const [];
      _isPlayingAudio = false;
    });

    // #373 (follow-up): try a previously-generated, not-yet-asked question
    // for this exact entry before spending a fresh API call — a batch call
    // below generates more than one at a time precisely so this cache has
    // something to serve on a later round that lands on the same entry.
    QuizQuestion? textQuestion = await history.takeCachedQuizQuestion(entry.id!);
    if (!mounted) return;

    if (textQuestion == null && geminiApiService != null) {
      setState(() => _loadingQuestion = true);
      final batch = await geminiApiService.generateQuizQuestions(
        script: entry.script,
        language: entry.outputLanguage ?? outputLanguage,
      );
      if (!mounted) return;
      if (batch.isNotEmpty) {
        textQuestion = batch.first;
        if (batch.length > 1) {
          await history.cacheQuizQuestions(entry.id!, batch.sublist(1));
        }
      }
    }

    late final List<String> options;
    if (textQuestion != null) {
      options = [textQuestion.correctAnswer, ...textQuestion.wrongAnswers];
    } else {
      // Guess-the-place fallback: distractors from other entries' titles,
      // topped up with location names if there aren't enough distinct
      // titles (e.g. several entries sharing a title from repeat visits).
      final distractorPool = _eligible
          .where((e) => e.id != entry.id && e.title != entry.title)
          .map((e) => e.title)
          .toSet()
          .toList();
      if (distractorPool.length < 3) {
        distractorPool.addAll(_eligible
            .where((e) => e.locationName != null && e.locationName != entry.locationName)
            .map((e) => e.locationName!)
            .toSet());
      }
      distractorPool.shuffle(_random);
      options = [entry.title, ...distractorPool.take(3)];
    }
    options.shuffle(_random);

    setState(() {
      _loadingQuestion = false;
      _textQuestion = textQuestion;
      _options = options;
    });
  }

  String get _correctAnswer => _textQuestion?.correctAnswer ?? _current!.title;

  void _answer(String chosen) {
    if (_selected != null) return;
    setState(() {
      _selected = chosen;
      _totalCount++;
      if (chosen == _correctAnswer) _correctCount++;
    });
  }

  Future<void> _toggleReplay() async {
    final entry = _current;
    if (entry?.audioPath == null) return;
    if (_isPlayingAudio) {
      await _audioPlayerChannel.invokeMethod('stop');
      if (mounted) setState(() => _isPlayingAudio = false);
      return;
    }
    setState(() => _isPlayingAudio = true);
    _audioPlayerChannel.invokeMethod('playWav', {'path': entry!.audioPath}).then((_) {
      if (!mounted) return;
      setState(() => _isPlayingAudio = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final entry = _current;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.quizScreenTitle),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: Text(l10n.quizScore(_correctCount, _totalCount))),
          ),
        ],
      ),
      body: SafeArea(
        child: entry == null
            ? const Center(child: CircularProgressIndicator())
            : _buildQuestion(context, l10n, entry),
      ),
    );
  }

  Widget _buildQuestion(BuildContext context, AppLocalizations l10n, HistoryEntry entry) {
    final answered = _selected != null;
    final correctAnswer = _correctAnswer;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.file(File(entry.imagePath), fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 16),
          if (_loadingQuestion)
            // Found via user feedback: showing the guess-the-place text
            // here while a text-comprehension question is still being
            // generated is misleading — it isn't necessarily the question
            // that ends up being asked, since a successful Gemini call
            // replaces it entirely once _nextQuestion()'s setState below
            // runs. The loading state speaks for itself instead.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(l10n.quizGeneratingQuestion),
                ],
              ),
            )
          else ...[
            Text(
              _textQuestion?.question ?? l10n.quizQuestionWhereIsThis,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ..._options.map((option) => _OptionButton(
                  label: option,
                  isCorrect: option == correctAnswer,
                  isSelected: option == _selected,
                  answered: answered,
                  onTap: () => _answer(option),
                )),
          ],
          if (answered) ...[
            const SizedBox(height: 8),
            Text(
              _selected == correctAnswer ? l10n.quizCorrect : l10n.quizIncorrect(correctAnswer),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _selected == correctAnswer ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (entry.hasAudio) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: Icon(_isPlayingAudio ? Icons.stop : Icons.play_arrow),
                      label: Text(l10n.quizReplayAudio),
                      onPressed: _toggleReplay,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton(
                    onPressed: _nextQuestion,
                    child: Text(l10n.quizNext),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  final String label;
  final bool isCorrect;
  final bool isSelected;
  final bool answered;
  final VoidCallback onTap;

  const _OptionButton({
    required this.label,
    required this.isCorrect,
    required this.isSelected,
    required this.answered,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color? borderColor;
    if (answered) {
      if (isCorrect) {
        borderColor = Colors.green;
      } else if (isSelected) {
        borderColor = Colors.red;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton(
        onPressed: answered ? null : onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          side: borderColor != null ? BorderSide(color: borderColor, width: 2) : null,
        ),
        child: Text(label, textAlign: TextAlign.center),
      ),
    );
  }
}
