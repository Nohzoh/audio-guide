import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/guide_error.dart';
import '../utils/app_logger.dart';
import '../utils/cancel_token.dart';
import '../utils/error_sanitizer.dart';
import '../utils/text_chunker.dart';
import 'gemini_tts_service.dart';
import 'native_tts_service.dart';

/// Speaks a script via Gemini TTS (cloud) when available, falling back to
/// the device's native TTS engine (local) on failure (T06 — extracted
/// from AudioGuideService.analyzeAndPlay; T89 — native engine replaced
/// Piper as the local fallback after real-device A/B testing showed
/// better quality).
class TtsOrchestrator {
  TtsOrchestrator({required this.nativeTts});

  final NativeTtsService nativeTts;

  /// Set by [speak]/[speakChunked] when the most recent call fell back to
  /// the native engine specifically because Gemini TTS was rate-limited
  /// (429), as opposed to some other failure — lets the UI show an
  /// accurate reason instead of a generic "unavailable" message.
  bool wasRateLimited = false;

  /// Speaks [script] in one blocking synthesis call. Returns the model
  /// actually used ('gemini-tts' or 'native-tts'). Throws [GuideError] if
  /// both engines fail. Prefer [speakChunked], which uses this as its
  /// fallback for scripts too short to chunk or when Gemini TTS isn't
  /// configured.
  /// [speed] is a playback speed multiplier (T15, 1.0 = normal), applied
  /// regardless of which engine actually ends up playing.
  Future<String> speak(
    String script, {
    required CancelToken cancelToken,
    GeminiTtsService? geminiTts,
    double speed = 1.0,
  }) async {
    wasRateLimited = false;
    if (geminiTts != null) {
      try {
        geminiTts.onComplete = nativeTts.onComplete;
        await geminiTts.speak(script, cancelToken: cancelToken, speed: speed);
        return 'gemini-tts';
      } catch (ttsError) {
        // A cancellation must stop playback outright, not fall back to
        // the native voice speaking a script the user asked to cancel (T70).
        if (ttsError is CancelledException) rethrow;
        wasRateLimited = ttsError is GeminiTtsRateLimitException;
        AppLogger.error('Gemini TTS failed, falling back to native TTS: '
            '${sanitizeError(ttsError.toString())}');
        try {
          await nativeTts.speak(script, cancelToken: cancelToken, speed: speed);
          return 'native-tts';
        } catch (fallbackError) {
          throw GuideError(GuideErrorKind.tts, sanitizeError(fallbackError.toString()));
        }
      }
    }
    try {
      await nativeTts.speak(script, cancelToken: cancelToken, speed: speed);
      return 'native-tts';
    } catch (ttsError) {
      throw GuideError(GuideErrorKind.tts, sanitizeError(ttsError.toString()));
    }
  }

  /// Speaks [script] in streamed chunks via Gemini TTS (T76): synthesizes
  /// the first (short) chunk and starts playing it immediately, then
  /// synthesizes each following chunk while the previous one is still
  /// playing — instead of waiting for the whole script (often ~30s) to be
  /// synthesized before any audio starts.
  ///
  /// Falls back to [speak] (unchanged, single-shot) when there's no Gemini
  /// TTS configured or the script is too short to be worth chunking. If a
  /// chunk fails to synthesize partway through, the remaining text is
  /// spoken via the native engine as one block — the already-played
  /// chunks stay as they were (no restart), and the rest is announced
  /// consistently in a single fallback voice rather than bouncing between
  /// engines.
  ///
  /// [onChunkStart] is called with the (0-based) index of each chunk as
  /// its playback begins and the total chunk count, e.g. to drive a
  /// "morceau N/M" progress indicator.
  ///
  /// Returns the model used, like [speak].
  Future<String> speakChunked(
    String script, {
    required CancelToken cancelToken,
    GeminiTtsService? geminiTts,
    void Function(int chunkIndex, int totalChunks)? onChunkStart,
    double speed = 1.0,
  }) async {
    wasRateLimited = false;
    if (geminiTts == null) {
      return speak(script, cancelToken: cancelToken, geminiTts: geminiTts, speed: speed);
    }

    final chunks = chunkScript(script);
    if (chunks.length <= 1) {
      return speak(script, cancelToken: cancelToken, geminiTts: geminiTts, speed: speed);
    }

    final tmpDir = await getTemporaryDirectory();
    final chunkPaths = List.generate(
      chunks.length,
      (i) => p.join(tmpDir.path, 'gemini_tts_chunk_$i.wav'),
    );

    try {
      await geminiTts.synthesizeToFile(chunks[0], chunkPaths[0]);
    } catch (ttsError) {
      wasRateLimited = ttsError is GeminiTtsRateLimitException;
      AppLogger.error('Gemini TTS (chunk 0) failed, falling back to native TTS: '
          '${sanitizeError(ttsError.toString())}');
      try {
        await nativeTts.speak(script, cancelToken: cancelToken, speed: speed);
        return 'native-tts';
      } catch (fallbackError) {
        throw GuideError(GuideErrorKind.tts, sanitizeError(fallbackError.toString()));
      }
    }

    geminiTts.onComplete = nativeTts.onComplete;

    for (var i = 0; i < chunks.length; i++) {
      if (cancelToken.isCancelled) return 'gemini-tts';
      onChunkStart?.call(i, chunks.length);

      final isLast = i == chunks.length - 1;
      final hasNext = i + 1 < chunks.length;

      // Synthesize the next chunk while this one plays. The error handler
      // is attached synchronously (via .then's onError, not a later
      // try/catch) so a rejection during the awaited playback below isn't
      // ever briefly unlistened — Dart's zone flags that as an unhandled
      // error even when a try/catch does eventually run.
      final Future<Object?>? nextSynthesisOutcome = hasNext
          ? geminiTts
              .synthesizeToFile(chunks[i + 1], chunkPaths[i + 1])
              .then<Object?>((_) => null, onError: (Object e) => e)
          : null;

      if (isLast) {
        // Match speak()'s contract: don't await final playback, just kick
        // it off — onComplete fires (once) when it actually finishes.
        unawaited(geminiTts.playFile(chunkPaths[i], speed: speed));
      } else {
        // notifyComplete: false — onComplete must fire only once, for the
        // truly last chunk, not after every intermediate one.
        await Future.any([
          geminiTts.playFile(chunkPaths[i], notifyComplete: false, speed: speed),
          cancelToken.onCancel,
        ]);
        if (cancelToken.isCancelled) return 'gemini-tts';
      }

      if (nextSynthesisOutcome != null) {
        final ttsError = await nextSynthesisOutcome;
        if (ttsError != null) {
          wasRateLimited = ttsError is GeminiTtsRateLimitException;
          AppLogger.error(
              'Gemini TTS (chunk ${i + 1}) failed, falling back to native TTS for the rest: '
              '${sanitizeError(ttsError.toString())}');
          final remaining = chunks.sublist(i + 1).join(' ');
          try {
            await nativeTts.speak(remaining, cancelToken: cancelToken, speed: speed);
          } catch (fallbackError) {
            throw GuideError(GuideErrorKind.tts, sanitizeError(fallbackError.toString()));
          }
          return 'native-tts';
        }
      }
    }

    // Every chunk was synthesized via Gemini — concatenate them into the
    // same conventional path speak() would have used, so history caching
    // (AudioGuideService._getLastWavPath) keeps working transparently.
    final combinedPath = p.join(tmpDir.path, 'gemini_tts_output.wav');
    await GeminiTtsService.concatenateWavFiles(chunkPaths, combinedPath);

    return 'gemini-tts';
  }
}
