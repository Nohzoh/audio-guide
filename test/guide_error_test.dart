import 'package:flutter_test/flutter_test.dart';
import 'package:audiolens/models/guide_error.dart';

void main() {
  test('GuideError exposes a kind and an optional detail', () {
    const error = GuideError(GuideErrorKind.network);
    expect(error.kind, GuideErrorKind.network);
    expect(error.detail, isNull);
    expect(error.toString(), 'network');
  });

  test('GuideError.detail carries a sanitized diagnostic for kinds that need one', () {
    const error = GuideError(GuideErrorKind.tts, 'timeout');
    expect(error.kind, GuideErrorKind.tts);
    expect(error.detail, 'timeout');
    expect(error.toString(), 'tts: timeout');
  });
}
