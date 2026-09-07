import 'package:flutter_test/flutter_test.dart';
import 'package:audiolens/utils/whats_new_parser.dart';

void main() {
  test('splits French labeled sections with their icons', () {
    final sections = parseWhatsNewSections(
      "Nouveautés : un quiz ludique. Corrections : un bug corrigé.",
    );

    expect(sections, hasLength(2));
    expect(sections[0].label, 'Nouveautés');
    expect(sections[0].icon, '✨');
    expect(sections[0].content, 'un quiz ludique.');
    expect(sections[1].label, 'Corrections');
    expect(sections[1].icon, '🔧');
    expect(sections[1].content, 'un bug corrigé.');
  });

  test('splits English labeled sections with their icons', () {
    final sections = parseWhatsNewSections(
      "New: a fun quiz. Improvements: faster analysis.",
    );

    expect(sections, hasLength(2));
    expect(sections[0].label, 'New');
    expect(sections[0].icon, '✨');
    expect(sections[0].content, 'a fun quiz.');
    expect(sections[1].label, 'Improvements');
    expect(sections[1].icon, '⚡');
    expect(sections[1].content, 'faster analysis.');
  });

  test('falls back to a single unlabeled section when no known label is found', () {
    final sections = parseWhatsNewSections('Juste un texte libre, sans étiquette.');

    expect(sections, hasLength(1));
    expect(sections.single.label, isEmpty);
    expect(sections.single.icon, isEmpty);
    expect(sections.single.content, 'Juste un texte libre, sans étiquette.');
  });

  test('skips a label that has no content after it', () {
    final sections = parseWhatsNewSections('Nouveautés : un quiz. Corrections : ');

    expect(sections, hasLength(1));
    expect(sections.single.label, 'Nouveautés');
  });

  test('a single section trims surrounding whitespace', () {
    final sections = parseWhatsNewSections('  Nouveautés :   un quiz.  ');

    expect(sections.single.content, 'un quiz.');
  });
}
