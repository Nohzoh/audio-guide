import 'package:flutter/material.dart';

/// #366: promoted out of `settings_screen.dart` (previously a private
/// `_SectionHeader`) so `advanced_settings_screen.dart` can render section
/// headers with the same look without duplicating the widget.
class SectionHeader extends StatelessWidget {
  final String title;
  const SectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
            letterSpacing: 1.2,
          ),
    );
  }
}
