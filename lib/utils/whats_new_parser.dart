/// One labeled section of a whats-new announcement (e.g. "Nouveautés",
/// "Corrections") — see [parseWhatsNewSections].
class WhatsNewSection {
  final String icon;
  final String label;
  final String content;

  const WhatsNewSection({required this.icon, required this.label, required this.content});
}

const _labelIcons = <String, String>{
  'Nouveautés': '✨',
  'New': '✨',
  'Corrections': '🔧',
  'Fixes': '🔧',
  'Améliorations': '⚡',
  'Improvements': '⚡',
};

final _labelPattern = RegExp(
  '(${_labelIcons.keys.join('|')})\\s*:\\s*',
);

/// Splits the `ship` skill's free-form whats-new prose (one paragraph per
/// release, with "Label : ..."/"Label: ..." sections — see AGENTS.md's
/// ship skill) into distinct labeled sections for display, instead of
/// dumping it as one flat, unstructured paragraph. Falls back to a
/// single unlabeled section wrapping the whole text if no known label is
/// found, so an older/different format still renders instead of vanishing.
List<WhatsNewSection> parseWhatsNewSections(String text) {
  final matches = _labelPattern.allMatches(text).toList();
  if (matches.isEmpty) {
    return [WhatsNewSection(icon: '', label: '', content: text.trim())];
  }

  final sections = <WhatsNewSection>[];
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    final label = match.group(1)!;
    final contentEnd = i + 1 < matches.length ? matches[i + 1].start : text.length;
    final content = text.substring(match.end, contentEnd).trim();
    if (content.isEmpty) continue;
    sections.add(WhatsNewSection(icon: _labelIcons[label] ?? '', label: label, content: content));
  }
  return sections.isEmpty
      ? [WhatsNewSection(icon: '', label: '', content: text.trim())]
      : sections;
}
