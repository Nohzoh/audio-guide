import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiolens/models/guide_error.dart';
import 'package:audiolens/services/gemini_api_service.dart';
import 'package:audiolens/services/remote_config_service.dart';
import 'support/fake_dio_adapter.dart';

String _successJson() => jsonEncode({
  'candidates': [
    {
      'content': {
        'parts': [
          {
            'text':
                '{"title": "La Joconde", "script": "Bienvenue devant ce chef-d\'oeuvre."}',
          },
        ],
      },
    },
  ],
});

String _errorJson() => jsonEncode({
  'error': {'message': 'rate limit exceeded'},
});

/// A well-formed 200 body whose candidate carries [text] — used to build
/// the various "succeeded but unusable" shapes below.
String _textPayload(String text) => jsonEncode({
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

/// What thinking-budget exhaustion looks like: a valid 200, empty text.
String _emptyTextJson() => _textPayload('');

String _modelFromPath(String path) =>
    RegExp(r'/models/([^:]+):').firstMatch(path)?.group(1) ?? '?';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cfg = RemoteConfigService.current;
  final primary = cfg.geminiModel;
  final fallbacks =
      cfg.geminiModelFallbacks.where((m) => m != primary).toList();
  final fb1 = fallbacks.first;

  late Directory tmpDir;
  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('gemini-api-fallback');
  });
  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  File tempImage() {
    final f = File('${tmpDir.path}/photo.jpg');
    f.writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);
    return f;
  }

  test('primary 429 -> falls back to next model', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        final model = _modelFromPath(options.uri.path);
        requested.add(model);
        if (model == primary) {
          return (statusCode: 429, body: _errorJson());
        }
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary, fb1]);
    expect(service.lastUsedModel, fb1);
    expect(result.title, 'La Joconde');
    expect(service.lastAttempts, hasLength(2));
    expect(service.lastAttempts.first, startsWith('✗ $primary'));
    expect(service.lastAttempts.last, startsWith('✓ $fb1'));
  });

  test('primary 404 -> falls back to next model', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        final model = _modelFromPath(options.uri.path);
        requested.add(model);
        if (model == primary) {
          return (statusCode: 404, body: _errorJson());
        }
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary, fb1]);
    expect(service.lastUsedModel, fb1);
    expect(result.title, 'La Joconde');
  });

  test('primary 503 -> falls back to next model', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        final model = _modelFromPath(options.uri.path);
        requested.add(model);
        if (model == primary) {
          return (statusCode: 503, body: _errorJson());
        }
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary, fb1]);
    expect(service.lastUsedModel, fb1);
    expect(result.title, 'La Joconde');
  });

  test('network error on primary -> next model attempted', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        final model = _modelFromPath(options.uri.path);
        requested.add(model);
        if (model == primary) {
          throw const SocketException('network down');
        }
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary, fb1]);
    expect(service.lastUsedModel, fb1);
    expect(result.title, 'La Joconde');
  });

  test('primary succeeds -> no fallback attempted', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        requested.add(_modelFromPath(options.uri.path));
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary]);
    expect(service.lastUsedModel, primary);
    expect(service.lastAttempts, ['✓ $primary']);
    expect(result.title, 'La Joconde');
  });

  test('all models fail -> throws with full trace', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        requested.add(_modelFromPath(options.uri.path));
        return (statusCode: 429, body: _errorJson());
      }),
    );

    // Every attempt was a 429, so the user gets the quota kind rather
    // than a raw per-model trace.
    await expectLater(
      service.analyzeImage(tempImage()),
      throwsA(isA<GuideError>()
          .having((e) => e.kind, 'kind', GuideErrorKind.aiQuotaExceeded)),
    );

    expect(requested, hasLength(fallbacks.length + 1));
    // The full trace is still available for the debug screen.
    expect(service.lastAttempts, hasLength(fallbacks.length + 1));
    expect(service.lastUsedModel, isNull);
  });

  // A 200 with no usable text is what a thinking-budget exhaustion looks
  // like from the client's side: the request succeeded, the model just had
  // no tokens left to answer with. Before this was handled, the loop broke
  // on the 200 and then threw, never reaching a fallback model.
  test('primary returns 200 with empty text -> falls back to next model', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        final model = _modelFromPath(options.uri.path);
        requested.add(model);
        if (model == primary) {
          return (statusCode: 200, body: _emptyTextJson());
        }
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary, fb1]);
    expect(service.lastUsedModel, fb1);
    expect(result.title, 'La Joconde');
    expect(service.lastAttempts.first, startsWith('✗ $primary (200'));
    expect(service.lastAttempts.last, startsWith('✓ $fb1'));
  });

  test('primary returns 200 with no candidates at all -> falls back', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        final model = _modelFromPath(options.uri.path);
        requested.add(model);
        if (model == primary) {
          return (statusCode: 200, body: jsonEncode({'candidates': []}));
        }
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary, fb1]);
    expect(service.lastUsedModel, fb1);
    expect(result.title, 'La Joconde');
  });

  // A 200 whose body is syntactically valid JSON but the wrong shape (not
  // an object at all) is plausible from a proxy/CDN error page or a
  // future API schema tweak — the top-level `jsonDecode(body) as
  // Map<String, dynamic>` cast used to throw TypeError here, escaping
  // this method's FormatException contract and getting mislabelled as a
  // network failure by analyzeImage's generic catch, instead of falling
  // back to the next model like every other unusable-response case.
  test('primary returns a 200 whose body is a JSON array, not an object -> falls back', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        final model = _modelFromPath(options.uri.path);
        requested.add(model);
        if (model == primary) {
          return (statusCode: 200, body: jsonEncode([1, 2, 3]));
        }
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary, fb1]);
    expect(service.lastUsedModel, fb1);
    expect(result.title, 'La Joconde');
    expect(service.lastAttempts.first, startsWith('✗ $primary (200'));
  });

  // Same class of bug as above, one level deeper: candidates[0] present
  // but not an object (e.g. a bare string) — the (firstCandidate as
  // Map<String, dynamic>?) cast used to throw TypeError here too.
  test('primary returns a 200 whose first candidate is not an object -> falls back', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        final model = _modelFromPath(options.uri.path);
        requested.add(model);
        if (model == primary) {
          return (statusCode: 200, body: jsonEncode({'candidates': ['not an object']}));
        }
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary, fb1]);
    expect(service.lastUsedModel, fb1);
    expect(result.title, 'La Joconde');
    expect(service.lastAttempts.first, startsWith('✗ $primary (200'));
  });

  test('primary returns unrecoverable JSON debris -> falls back', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        final model = _modelFromPath(options.uri.path);
        requested.add(model);
        if (model == primary) {
          // JSON-shaped but neither field recoverable — must not be shown
          // verbatim (T90), and must not end the loop either.
          return (statusCode: 200, body: _textPayload('{"title": , "script": }'));
        }
        return (statusCode: 200, body: _successJson());
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary, fb1]);
    expect(service.lastUsedModel, fb1);
    expect(result.title, 'La Joconde');
  });

  test('every model returns an empty 200 -> throws with full trace', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        requested.add(_modelFromPath(options.uri.path));
        return (statusCode: 200, body: _emptyTextJson());
      }),
    );

    await expectLater(
      service.analyzeImage(tempImage()),
      throwsA(isA<GuideError>()
          .having((e) => e.kind, 'kind', GuideErrorKind.aiUnusableResponse)),
    );

    expect(requested, hasLength(fallbacks.length + 1));
    expect(service.lastUsedModel, isNull);
  });

  // Guards the plain-text branch: a model ignoring the JSON instruction
  // entirely still produces usable content, so it must NOT be treated as
  // an unusable response and skipped over.
  test('plain-text (non-JSON) 200 is accepted, not treated as a failure', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        requested.add(_modelFromPath(options.uri.path));
        return (
          statusCode: 200,
          body: _textPayload('Bienvenue devant ce chef-d\'oeuvre. Il fut peint en 1503.'),
        );
      }),
    );

    final result = await service.analyzeImage(tempImage());

    expect(requested, [primary]);
    expect(service.lastUsedModel, primary);
    expect(result.script, contains('chef-d\'oeuvre'));
  });


  group('user-facing failure kind', () {
    // #230: services throw a GuideErrorKind, not prose — localizing (and
    // keeping the per-model trace out of what the user sees) is the UI
    // layer's job now, tested separately via guide_error_localizer.
    Future<GuideErrorKind> kindWhenAllModelsReturn(
      Future<({int statusCode, String body})> Function(String model) respond,
    ) async {
      final service = GeminiApiService(
        apiKey: 'test-key',
        dioClient: fakeDio((options) async => respond(_modelFromPath(options.uri.path))),
      );
      try {
        await service.analyzeImage(tempImage());
        fail('expected analyzeImage to throw');
      } on GuideError catch (e) {
        // Deliberately not a bare `catch`: fail() above throws a
        // TestFailure, which a bare catch would swallow and return as if
        // it were the kind under test, turning a broken test green.
        return e.kind;
      }
    }

    test('503 everywhere -> service-unavailable kind', () async {
      final kind = await kindWhenAllModelsReturn(
          (_) async => (statusCode: 503, body: _errorJson()));
      expect(kind, GuideErrorKind.aiServiceUnavailable);
    });

    test('404 everywhere -> model-unavailable kind', () async {
      final kind = await kindWhenAllModelsReturn(
          (_) async => (statusCode: 404, body: _errorJson()));
      expect(kind, GuideErrorKind.aiModelUnavailable);
    });

    test('network failure everywhere -> network kind', () async {
      final kind = await kindWhenAllModelsReturn(
          (_) async => throw const SocketException('network down'));
      expect(kind, GuideErrorKind.network);
    });

    // The reason genuinely differs per model in the real world: the
    // primary can be out of quota while a fallback has simply been
    // retired. Only the last attempt's cause is reported, rather than
    // stitching several unrelated causes into one kind.
    test('mixed causes -> reports the last attempt, not the first', () async {
      final service = GeminiApiService(
        apiKey: 'test-key',
        dioClient: fakeDio((options) async {
          final model = _modelFromPath(options.uri.path);
          // Primary: out of quota. Every fallback: retired model.
          return model == primary
              ? (statusCode: 429, body: _errorJson())
              : (statusCode: 404, body: _errorJson());
        }),
      );

      await expectLater(
        service.analyzeImage(tempImage()),
        throwsA(isA<GuideError>()
            .having((e) => e.kind, 'kind', GuideErrorKind.aiModelUnavailable)),
      );
    });

    test('the failure kind carries no per-model trace', () async {
      final kind = await kindWhenAllModelsReturn(
          (_) async => (statusCode: 429, body: _errorJson()));
      // The trace lives in lastAttempts for the debug screen — a plain
      // enum value is structurally incapable of leaking model IDs or
      // HTTP codes to the user.
      expect(kind, GuideErrorKind.aiQuotaExceeded);
    });
  });

  test('HTTP 500 -> rethrows immediately, stops the fallback loop', () async {
    final requested = <String>[];
    final service = GeminiApiService(
      apiKey: 'test-key',
      dioClient: fakeDio((options) async {
        requested.add(_modelFromPath(options.uri.path));
        return (statusCode: 500, body: 'internal error');
      }),
    );

    await expectLater(
      service.analyzeImage(tempImage()),
      throwsA(isA<GuideError>()
          .having((e) => e.kind, 'kind', GuideErrorKind.aiGeneric)
          .having((e) => e.detail, 'detail', contains('HTTP 500'))),
    );

    expect(requested, hasLength(1));
  });
}
