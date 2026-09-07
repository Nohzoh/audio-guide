import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/guide_error.dart';
import '../models/quiz_question.dart';
import '../utils/app_logger.dart';
import '../utils/cancel_token.dart';
import '../utils/error_sanitizer.dart';
import '../utils/image_downscale.dart';
import '../utils/script_cleanup.dart';
import '../utils/script_validation.dart';
import 'package:dio/dio.dart' as dio;
import 'ai_service.dart';
import 'remote_config_service.dart';

class GeminiApiService implements AIService {
  String? _lastUsedModel;
  String? get lastUsedModel => _lastUsedModel;
  List<String> _lastAttempts = [];
  List<String> get lastAttempts => _lastAttempts;

  final String apiKey;
  final dio.Dio _dio;

  /// [dioClient] allows injecting a mock Dio instance in tests (fallback
  /// logic) — see `test/support/fake_dio_adapter.dart`.
  GeminiApiService({required this.apiKey, dio.Dio? dioClient})
      : _dio = dioClient ?? dio.Dio();

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
    CancelToken? cancelToken,
    String? style,
    String? language,
  }) async {
    final cfg = RemoteConfigService.current;
    // T113: downscale before upload — a full-res phone photo (10-20MB) is
    // real memory pressure and, base64-encoded, ~33% bigger again over
    // the wire. The original file (used for EXIF/history) is untouched.
    final imageBytes = await downscaleForUpload(
      imageFile,
      maxWidth: cfg.imageMaxWidth,
      quality: cfg.imageQuality,
    );
    final base64Image = base64Encode(imageBytes);

    final contextPart = locationContext != null && locationContext.isNotEmpty
        ? '\n\nContexte et informations factuelles disponibles :\n$locationContext'
        : '';

    final wordCount =
        style == 'concise' ? 'Entre 100 et 150 mots' : 'Entre 300 et 400 mots';

    // #130: an explicit override directive is enough to steer the actual
    // content language regardless of what language the rest of this
    // (French) prompt's own instructions are written in.
    final languagePart = language != null && language.isNotEmpty
        ? 'Redige le titre et le script exclusivement en $language, meme si '
            'ces instructions sont en francais. '
        : '';

    final prompt = 'Tu es un guide audio de musee, passionne et erudit. '
        'Redige deux choses en JSON valide uniquement, sans markdown : '
        '{"title": "titre court et evocateur (5-8 mots max)", "script": "le texte du guide"} '
        '$languagePart'
        'Le titre doit nommer precisement l\'oeuvre ou le lieu si reconnu, sinon evoquer ce qu\'on voit. '
        '${_styleGuidance(style)} '
        'Si tu reconnais l\'oeuvre, nomme-la avec des faits reels. '
        'Si le contexte fourni mentionne un lieu identifie, une adresse ou une enseigne, '
        'utilise-le en priorite pour identifier precisement l\'endroit reel plutot que de '
        'rester generique, et cherche les faits marquants qui s\'y rattachent (tournages, '
        'evenements historiques, personnalites) plutot que de decrire seulement ce qui est visible. '
        '$contextPart '
        '$wordCount pour le script, sans mise en forme ni asterisque. '
        'Ne montre jamais ton raisonnement interne. '
        'Ne commente pas le nombre de mots. '
        'Ecris uniquement le JSON final, rien d\'autre.';

    // Try primary model then fallbacks on 429
    final modelsToTry = [
      cfg.geminiModel,
      ...cfg.geminiModelFallbacks.where((m) => m != cfg.geminiModel),
    ];

    ({int statusCode, String body})? response;
    AudioGuideResult? parsedResult;
    final List<String> attempts = [];
    // Why the most recent model attempt failed, kept structured (rather
    // than only as the display string in `attempts`) so the final error
    // can be phrased for the user. Only the last attempt's reason is
    // used: failures often differ across models (the primary may be out
    // of quota while a fallback is simply retired), and stitching several
    // causes into one message helps nobody.
    _GeminiFailure? lastFailure;

    for (final model in modelsToTry) {
      final fullUrl =
          '${cfg.geminiApiUrl}/models/$model:generateContent?key=$apiKey';

      try {
        final resp = await _post(
          Uri.parse(fullUrl),
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
          cancelToken: cancelToken,
        );

        if (resp.statusCode == 200) {
          // A 200 is not by itself a success: the model can return an
          // empty or JSON-debris body — most commonly when thinking
          // tokens consume the whole maxOutputTokens budget, leaving
          // nothing for the actual answer. Validate the body here, inside
          // the loop, so an unusable response falls through to the next
          // fallback model instead of terminating the loop with a
          // guaranteed failure a few lines below.
          try {
            final parsed = _parseResponseBody(resp.body);
            response = resp;
            parsedResult = parsed;
            _lastUsedModel = model;
            attempts.add('✓ $model');
            AppLogger.ai('Model succeeded: $model');
            break;
          } on FormatException catch (e) {
            // sanitizeError even though these messages are ours and short:
            // the log-hygiene guardrail (T126) treats any raw exception
            // interpolation as a leak risk, and keeping the rule absolute
            // is worth more than the couple of characters it costs here.
            final reason = sanitizeError(e.message);
            attempts.add('✗ $model (200, réponse inexploitable): $reason');
            AppLogger.ai('Model returned unusable 200: $model ($reason)');
            lastFailure = _GeminiFailure.unusableResponse;
            continue;
          }
        } else if (resp.statusCode == 429 || resp.statusCode == 404 || resp.statusCode == 503) {
          final err = _tryDecode(resp.body);
          final msg = err?['error']?['message'] as String? ?? 'HTTP ${resp.statusCode}';
          final short = msg.length > 80 ? msg.substring(0, 80) : msg;
          attempts.add('✗ $model (${resp.statusCode}): $short');
          AppLogger.ai('Model failed: $model (${resp.statusCode}): $short');
          lastFailure = switch (resp.statusCode) {
            429 => _GeminiFailure.quotaExceeded,
            404 => _GeminiFailure.modelUnavailable,
            _ => _GeminiFailure.serviceUnavailable,
          };
          continue;
        } else {
          final err = _tryDecode(resp.body);
          final msg = (err?['error']?['message'] as String?) ?? resp.body;
          attempts.add('✗ $model (${resp.statusCode}): $msg');
          throw Exception(
            'Gemini API erreur ${resp.statusCode} sur $model:\n$msg',
          );
        }
      } catch (e) {
        // A cancellation must abort the whole retry-across-models loop, not
        // be treated as "this model failed, try the next one" (T70) — the
        // user asked to stop, not to keep burning quota on fallbacks.
        if (e is CancelledException) rethrow;
        if (e is Exception && e.toString().contains('Gemini API erreur')) rethrow;
        attempts.add('✗ $model (timeout/réseau): ${sanitizeError(e.toString())}');
        lastFailure = _GeminiFailure.network;
        continue;
      }
    }

    _lastAttempts = attempts;
    if (response == null) {
      // The thrown message is what the user actually sees (AudioGuideService
      // surfaces it as-is via errorMessage), so phrase it for them rather
      // than dumping the per-model trace — that trace stays available in
      // lastAttempts for the debug screen.
      AppLogger.ai('All models failed:\n${attempts.join('\n')}');
      throw GuideError(_failureKind(lastFailure));
    }

    // Non-null whenever response is: both are set together in the loop above.
    return parsedResult!;
  }

  /// #230: maps the *last* attempt's failure to a [GuideErrorKind] —
  /// localized to a user-facing message at display time, not here (this
  /// class has no `BuildContext`/`AppLocalizations` to localize with).
  static GuideErrorKind _failureKind(_GeminiFailure? failure) {
    switch (failure) {
      case _GeminiFailure.quotaExceeded:
        return GuideErrorKind.aiQuotaExceeded;
      case _GeminiFailure.modelUnavailable:
        return GuideErrorKind.aiModelUnavailable;
      case _GeminiFailure.serviceUnavailable:
        return GuideErrorKind.aiServiceUnavailable;
      case _GeminiFailure.unusableResponse:
        return GuideErrorKind.aiUnusableResponse;
      case _GeminiFailure.network:
        return GuideErrorKind.network;
      case null:
        // No model was even attempted — an empty model list, which is a
        // configuration problem rather than a runtime failure.
        return GuideErrorKind.aiNoModelConfigured;
    }
  }

  /// #343: generates a text-comprehension quiz question from [script] — an
  /// already-existing history entry's cached AI-written text, no new photo
  /// analysis involved. Silent-failure by design: returns null on any
  /// error (network, rate limit, malformed/incomplete JSON) rather than
  /// throwing — the quiz screen falls back to its zero-cost "guess the
  /// place" question type when this returns null, so a single missing
  /// quiz question isn't worth retrying across models or surfacing an
  /// error for, unlike a real analysis.
  Future<QuizQuestion?> generateQuizQuestion({
    required String script,
    String? language,
  }) async {
    final cfg = RemoteConfigService.current;
    final languagePart = language != null && language.isNotEmpty
        ? 'Pose la question et les reponses exclusivement en $language. '
        : '';
    final prompt = 'Voici le texte d\'un guide audio touristique :\n\n$script\n\n'
        'A partir de ce texte, redige en JSON valide uniquement, sans markdown : '
        '{"question": "une question factuelle courte sur une information precise '
        'mentionnee dans ce texte", "correctAnswer": "la bonne reponse, courte '
        '(quelques mots)", "wrongAnswers": ["reponse plausible mais fausse 1", '
        '"reponse plausible mais fausse 2", "reponse plausible mais fausse 3"]} '
        '$languagePart'
        'La question doit porter sur un fait precis et verifiable du texte (date, '
        'nom, materiau, anecdote...), jamais une question generale ou d\'opinion. '
        'Les mauvaises reponses doivent etre plausibles et du meme type que la '
        'bonne (une date proche pour une question de date, etc.), jamais absurdes. '
        'Ecris uniquement le JSON final, rien d\'autre.';

    try {
      final resp = await _post(
        Uri.parse('${cfg.geminiApiUrl}/models/${cfg.geminiModel}:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt}
              ]
            }
          ],
          'generationConfig': {
            'maxOutputTokens': cfg.geminiMaxTokens,
            'temperature': cfg.geminiTemperature,
          },
        }),
      );
      if (resp.statusCode != 200) return null;

      final text = _extractCandidateText(resp.body);
      if (text == null || text.isEmpty) return null;

      final jsonBlob = _extractJsonObject(text);
      if (jsonBlob == null) return null;
      final parsed = jsonDecode(jsonBlob);
      if (parsed is! Map<String, dynamic>) return null;

      final question = (parsed['question'] as String? ?? '').trim();
      final correctAnswer = (parsed['correctAnswer'] as String? ?? '').trim();
      final wrongAnswersRaw = parsed['wrongAnswers'];
      final wrongAnswers = wrongAnswersRaw is List
          ? wrongAnswersRaw
              .whereType<String>()
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toSet() // guards against the model repeating an answer
              .toList()
          : <String>[];

      if (question.isEmpty || correctAnswer.isEmpty || wrongAnswers.length < 3) {
        return null;
      }

      return QuizQuestion(
        question: question,
        correctAnswer: correctAnswer,
        wrongAnswers: wrongAnswers.take(3).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Parses a 200 response body into a result, or throws [FormatException]
  /// if the body can't yield a usable title+script.
  ///
  /// Throwing [FormatException] specifically (rather than a generic
  /// Exception) is what lets [analyzeImage]'s model loop distinguish "this
  /// model gave us nothing usable, try the next one" from a hard error
  /// that should abort the whole call.
  AudioGuideResult _parseResponseBody(String body) {
    // `is` checks rather than `as` casts throughout this walk: an `as`
    // cast throws TypeError on a shape mismatch, not FormatException —
    // which would escape this method's FormatException contract (a
    // syntactically valid but unexpectedly-shaped 200 body is plausible
    // from a proxy/CDN error page or a future API schema tweak) and land
    // in analyzeImage's generic catch, mislabelled as a network failure
    // instead of an unusable response.
    final text = _extractCandidateText(body);

    if (text == null || text.isEmpty) {
      // Most often: thinking tokens consumed the entire maxOutputTokens
      // budget (they're billed against the same budget as the answer), so
      // the model had nothing left to emit.
      throw const FormatException('réponse vide');
    }

    // Try JSON response {title, script}
    String title;
    String script;
    try {
      final jsonBlob = _extractJsonObject(text);
      if (jsonBlob == null) throw const FormatException('no JSON');
      final parsed = jsonDecode(jsonBlob) as Map<String, dynamic>;
      final parsedTitle = (parsed['title'] as String? ?? '').trim();
      final parsedScript = (parsed['script'] as String? ?? '').trim();
      // Require both fields — falling back to the raw (still-JSON-shaped)
      // `text` for a missing script would leak the JSON wrapper into the
      // displayed script, the same bug as T90 but on the script side.
      if (parsedTitle.isEmpty || parsedScript.isEmpty) {
        throw const FormatException('empty title or script');
      }
      title = parsedTitle;
      script = cleanMarkdown(parsedScript);
    } catch (_) {
      // Full JSON parsing failed — often because the model left an
      // unescaped quote inside a field (not a brace-matching problem, so
      // _extractJsonObject's string-aware scan doesn't help here). Try to
      // recover title/script independently via regex before giving up:
      // "title" alone is short (5-8 words per the prompt) and rarely
      // contains a stray quote, so it's often recoverable even when the
      // whole object isn't valid JSON — but "script" is long-form prose,
      // so a stray quote inside it is much more likely to also break the
      // regex, unlike title.
      final titleMatch = RegExp(r'"title"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(text);
      final scriptMatch = RegExp(r'"script"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(text);
      final regexTitle = titleMatch != null ? _unescapeJsonString(titleMatch.group(1)!) : null;
      final regexScript = scriptMatch != null ? _unescapeJsonString(scriptMatch.group(1)!) : null;

      // A "title"/"script" key literal appearing anywhere means the
      // response was meant to be JSON — even if regex extraction above
      // only got one field or none, the raw text is JSON-shaped and must
      // never be shown verbatim as either the title or the script.
      final looksLikeJson = text.trimLeft().startsWith('{') ||
          RegExp(r'"(title|script)"\s*:').hasMatch(text);

      if (regexTitle != null &&
          regexTitle.trim().isNotEmpty &&
          regexScript != null &&
          regexScript.trim().isNotEmpty) {
        title = regexTitle.trim();
        script = cleanMarkdown(regexScript.trim());
      } else if (looksLikeJson) {
        // Malformed beyond what regex can recover, on either field —
        // showing the raw JSON debris as the title or (worse) reading it
        // aloud as the script (T90) is a worse experience than a clear
        // failure the app's existing retry flow already handles.
        // FormatException (not a bare Exception) so analyzeImage's loop
        // treats this as "try the next model" rather than aborting.
        throw const FormatException(
          'réponse JSON invalide (title/script illisibles)',
        );
      } else {
        // Genuinely plain-text response (model ignored the JSON
        // instruction entirely) — legitimate, readable content, just not
        // in the expected shape.
        final cleaned = cleanMarkdown(text);
        final first = cleaned.split(RegExp(r'[.!?]')).first.trim();
        title = first.length > 60 ? '${first.substring(0, 60)}...' : first;
        script = cleaned;
      }
    }

    return AudioGuideResult(
      title: title,
      // T117: cap runaway output before it reaches history/TTS.
      script: capScriptLength(script, maxChars: RemoteConfigService.current.scriptMaxChars),
    );
  }

  /// Tone/structure instruction for the script, keyed by [style] (T75/T48).
  /// The default ('immersive', including null/unrecognized values) is the
  /// original prompt text unchanged, so the default experience never
  /// regresses.
  static String _styleGuidance(String? style) {
    switch (style) {
      case 'academic':
        return 'Le script : documentaire et rigoureux, tu t\'adresses au visiteur avec "vous". '
            'Privilegie les faits verifies, dates precises et contexte historique '
            'detaille plutot que l\'emotion. Commence par le fait le plus '
            'significatif ou la date cle, sans effet de style superflu. '
            'Construis : mise en contexte factuelle, developpement historique, '
            'details techniques ou artistiques, conclusion sur l\'importance '
            'du lieu ou de l\'oeuvre.';
      case 'anecdotal':
        return 'Le script : complice et plein de curiosites, tu t\'adresses au '
            'visiteur avec "vous". Varie toujours l\'accroche d\'ouverture : ne '
            'commence jamais par "Arrêtez-vous", "Regardez", "Devant vous", '
            '"Contemplez" ou toute formule repetitive. Mets l\'accent sur les '
            'anecdotes, secrets et petites histoires peu connues plutot qu\'une '
            'description exhaustive, comme un ami qui partage ce qu\'il sait de '
            'plus surprenant. Construis : accroche par une anecdote, '
            'enchainement de curiosites, conclusion sur ce qui rend l\'histoire '
            'memorable.';
      case 'concise':
        return 'Le script : direct et efficace, tu t\'adresses au visiteur avec '
            '"vous". Va droit au but : l\'essentiel seulement, sans digression '
            'ni developpement long. Une accroche courte, un ou deux faits '
            'marquants, une conclusion breve.';
      default: // 'immersive'
        return 'Le script : narratif et immersif, tu t\'adresses au visiteur '
            'avec "vous". Varie toujours l\'accroche d\'ouverture : ne commence '
            'jamais par "Arrêtez-vous", "Regardez", "Devant vous", "Contemplez" '
            'ou toute formule repetitive. Sois inventif : commence par un fait '
            'surprenant, une question, une anecdote, une sensation, une date '
            'marquante, ou plonge directement dans l\'histoire. Construis : '
            'accroche originale, details fascinants, contexte historique, '
            'anecdote marquante, conclusion emotionnelle.';
    }
  }

  /// Pulls the first candidate's text out of a raw `generateContent`
  /// response body, or null on any shape mismatch — a response can
  /// legitimately carry an empty/missing candidates/parts list (e.g.
  /// everything was filtered out), and indexed access rather than `[0]`
  /// directly avoids a RangeError on that case.
  static String? _extractCandidateText(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final candidates = decoded['candidates'];
    final firstCandidate =
        (candidates is List && candidates.isNotEmpty) ? candidates.first : null;
    final content = firstCandidate is Map<String, dynamic> ? firstCandidate['content'] : null;
    final parts = content is Map<String, dynamic> ? content['parts'] : null;
    final firstPart = (parts is List && parts.isNotEmpty) ? parts.first : null;
    final rawText = firstPart is Map<String, dynamic> ? firstPart['text'] : null;
    return rawText is String ? rawText : null;
  }

  /// Finds the first top-level JSON object in [text] by scanning for
  /// balanced braces, tracking whether the scanner is inside a string
  /// literal so a `{`/`}` inside e.g. the "script" value's own text (or a
  /// ```` ```json ```` fence around the object) doesn't throw off the
  /// match — unlike a plain `indexOf('{')`/`lastIndexOf('}')` pair, which
  /// silently returns the wrong boundary in both cases (T90).
  static String? _extractJsonObject(String text) {
    final start = text.indexOf('{');
    if (start == -1) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final char = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == '\\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
      } else if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  /// Unescapes a raw JSON string body (the content between the quotes,
  /// as captured by a regex) by delegating to [jsonDecode] rather than
  /// hand-rolling escape handling. Returns null if [raw] isn't valid
  /// JSON string content (e.g. a truncated escape sequence).
  static String? _unescapeJsonString(String raw) {
    try {
      return jsonDecode('"$raw"') as String;
    } catch (_) {
      return null;
    }
  }

  /// Posts [body] to [uri] via dio, whose [dio.CancelToken] actually aborts
  /// the in-flight request (unlike the old `http` client + `Future.timeout`
  /// combo, which stopped *waiting* but left the request running in the
  /// background to completion regardless — T70). Wires [cancelToken] (the
  /// app's own token) to a fresh dio token for this call, and treats an
  /// exceeded [const Duration(seconds: 30)] the same way: cancel the
  /// socket, not just the wait.
  Future<({int statusCode, String body})> _post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
    CancelToken? cancelToken,
  }) async {
    final dioToken = dio.CancelToken();
    cancelToken?.onCancel.then((_) => dioToken.cancel());
    try {
      final resp = await _dio
          .postUri<String>(
            uri,
            data: body,
            cancelToken: dioToken,
            options: dio.Options(
              headers: headers,
              responseType: dio.ResponseType.plain,
              validateStatus: (_) => true,
            ),
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              dioToken.cancel();
              throw TimeoutException('Gemini API: délai dépassé');
            },
          );
      return (statusCode: resp.statusCode ?? 0, body: resp.data ?? '');
    } on dio.DioException catch (e) {
      if (e.type == dio.DioExceptionType.cancel) {
        throw const CancelledException();
      }
      rethrow;
    }
  }

  /// Safely decodes an error body: API error pages are not always JSON.
  static Map<String, dynamic>? _tryDecode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }
}

/// Why a model attempt failed, kept distinct from its display string so
/// the final user-facing error can be phrased per cause (T117/#158).
enum _GeminiFailure {
  /// HTTP 429 — the user's own Google AI quota, by far the most common
  /// real-world failure for a bring-your-own-key setup.
  quotaExceeded,

  /// HTTP 404 — the configured model no longer exists (Google retires
  /// model IDs regularly).
  modelUnavailable,

  /// HTTP 503 — transient service outage.
  serviceUnavailable,

  /// HTTP 200 but nothing usable in the body (most often thinking tokens
  /// consuming the whole output budget).
  unusableResponse,

  /// Timeout or transport-level failure.
  network,
}
