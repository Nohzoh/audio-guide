import 'dart:io';
import '../utils/app_logger.dart';
import '../utils/analysis_runner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../constants/output_languages.dart';
import '../l10n/app_localizations.dart';
import '../services/audio_guide_service.dart';
import '../services/history_service.dart';
import '../services/settings_service.dart';
import '../widgets/guide_action_row.dart';
import '../widgets/kofi_button.dart';
import '../widgets/mini_map.dart';
import '../widgets/photo_gradient_background.dart';
import '../widgets/scrim_icon_button.dart';
import '../widgets/skip_icon_button.dart';
import '../utils/guide_error_localizer.dart';
import '../utils/user_message_utils.dart';
import 'about_analysis_screen.dart';

/// Launches the analysis for a captured entry (T78), using the raw GPS
/// saved at capture time rather than the device's current location.
Future<void> _launchAnalysis(BuildContext context, HistoryEntry entry) async {
  final imageFile = File(entry.imagePath);
  if (!imageFile.existsSync()) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(AppLocalizations.of(context)!.historyImageNotFound)),
    );
    return;
  }
  final knownCoordinates =
      await resolveKnownCoordinatesForRelaunch(context, entry);
  if (!context.mounted) return;
  await runAnalysisAndNavigate(
    context: context,
    imageFile: imageFile,
    entryId: entry.id!,
    source: 'captured',
    knownCoordinates: knownCoordinates,
  );
}

/// Retries a failed analysis, reusing whatever location was resolved for
/// the original attempt (live GPS, EXIF, or a manually picked map point)
/// instead of re-resolving the device's current position from scratch —
/// see HistoryService.failEntry's doc.
Future<void> _retryAnalysis(BuildContext context, HistoryEntry entry) async {
  final imageFile = File(entry.imagePath);
  if (!imageFile.existsSync()) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(AppLocalizations.of(context)!.historyImageNotFound)),
    );
    return;
  }
  final knownCoordinates =
      await resolveKnownCoordinatesForRelaunch(context, entry);
  if (!context.mounted) return;
  await runAnalysisAndNavigate(
    context: context,
    imageFile: imageFile,
    entryId: entry.id!,
    source: 'retry',
    knownCoordinates: knownCoordinates,
  );
}

/// #131: what the user picked in [_RegenerateSheet].
class _RegenerateChoice {
  final String style;
  final String language;
  final AIProvider provider;
  const _RegenerateChoice({
    required this.style,
    required this.language,
    required this.provider,
  });
}

/// #131: lets the user regenerate [entry]'s script with a different style/
/// language/model instead of only being able to retry with the same
/// settings. Per explicit product decision, picking new values here also
/// becomes the new default going forward (same as changing them from
/// Settings) — simplest mental model, and reuses the exact same
/// SettingsService/AudioGuideService plumbing every other analysis already
/// goes through, rather than inventing a separate "one-off override"
/// mechanism. The snackbar below is the one concession to that: it makes
/// the side effect visible instead of silently changing a global default.
Future<void> _openRegenerateSheet(
    BuildContext context, HistoryEntry entry) async {
  final settings = context.read<SettingsService>();
  final guide = context.read<AudioGuideService>();
  final choice = await showModalBottomSheet<_RegenerateChoice>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _RegenerateSheet(
      initialStyle: entry.scriptStyle ?? settings.scriptStyle,
      initialLanguage: entry.outputLanguage ?? settings.outputLanguage,
      initialProvider: guide.activeProvider,
      nanoAvailable: guide.nanoAvailable,
      geminiApiAvailable: guide.geminiApiKey?.isNotEmpty == true,
    ),
  );
  if (choice == null || !context.mounted) return;

  var settingsChanged = false;
  if (choice.style != settings.scriptStyle) {
    await settings.setScriptStyle(choice.style);
    settingsChanged = true;
  }
  if (choice.language != settings.outputLanguage) {
    await settings.setOutputLanguage(choice.language);
    settingsChanged = true;
  }
  if (choice.provider != guide.activeProvider) {
    await guide.setActiveProvider(choice.provider);
    settingsChanged = true;
  }
  if (settingsChanged && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            AppLocalizations.of(context)!.historyRegenerateSettingsUpdated),
      ),
    );
  }
  if (!context.mounted) return;
  await _retryAnalysis(context, entry);
}

class _RegenerateSheet extends StatefulWidget {
  final String initialStyle;
  final String initialLanguage;
  final AIProvider initialProvider;
  final bool nanoAvailable;
  final bool geminiApiAvailable;

  const _RegenerateSheet({
    required this.initialStyle,
    required this.initialLanguage,
    required this.initialProvider,
    required this.nanoAvailable,
    required this.geminiApiAvailable,
  });

  @override
  State<_RegenerateSheet> createState() => _RegenerateSheetState();
}

class _RegenerateSheetState extends State<_RegenerateSheet> {
  late String _style = widget.initialStyle;
  late String _language = widget.initialLanguage;
  late AIProvider _provider = widget.initialProvider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.historyRegenerateTitle,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            Text(l10n.settingsScriptStyleSection,
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (value, label) in [
                  ('immersive', l10n.settingsStyleImmersive),
                  ('academic', l10n.settingsStyleAcademic),
                  ('anecdotal', l10n.settingsStyleAnecdotal),
                  ('concise', l10n.settingsStyleConcise),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _style == value,
                    onSelected: (_) => setState(() => _style = value),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(l10n.settingsOutputLanguageSection,
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final language in outputLanguageLocales.keys)
                  ChoiceChip(
                    label: Text(language),
                    selected: _language == language,
                    onSelected: (_) => setState(() => _language = language),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(l10n.historyRegenerateModelLabel,
                style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  // #253: matches the Settings screen's provider card —
                  // "IA locale", not the brand name.
                  label: Text(l10n.settingsLocalAiName),
                  selected: _provider == AIProvider.geminiNano,
                  onSelected: widget.nanoAvailable
                      ? (_) => setState(() => _provider = AIProvider.geminiNano)
                      : null,
                ),
                ChoiceChip(
                  label: const Text('Gemini API'),
                  selected: _provider == AIProvider.geminiApi,
                  onSelected: widget.geminiApiAvailable
                      ? (_) => setState(() => _provider = AIProvider.geminiApi)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.historyCancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _RegenerateChoice(
                        style: _style,
                        language: _language,
                        provider: _provider),
                  ),
                  child: Text(l10n.historyRegenerateConfirm),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  // T51: mutually exclusive with each other and with "all" (both null).
  bool _favoritesOnly = false;
  int? _selectedCollectionId;

  void _selectAll() => setState(() {
        _favoritesOnly = false;
        _selectedCollectionId = null;
      });
  void _selectFavorites() => setState(() {
        _favoritesOnly = true;
        _selectedCollectionId = null;
      });
  void _selectCollection(int id) => setState(() {
        _favoritesOnly = false;
        _selectedCollectionId = id;
      });

  List<HistoryEntry> _filteredEntries(HistoryService history) {
    if (_favoritesOnly) {
      return history.entries.where((e) => e.isFavorite).toList();
    }
    if (_selectedCollectionId != null) {
      final id = _selectedCollectionId!;
      return history.entries
          .where((e) =>
              e.id != null && history.collectionIdsForEntry(e.id!).contains(id))
          .toList();
    }
    return history.entries;
  }

  Future<void> _createCollection(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.historyNewCollection),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.historyNewCollectionHint),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.historyCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.historyCreateCollection),
          ),
        ],
      ),
    );
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty && context.mounted) {
      await context.read<HistoryService>().createCollection(trimmed);
    }
  }

  Future<void> _confirmDeleteCollection(
      BuildContext context, Collection collection) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.historyDeleteCollection),
        content: Text(l10n.historyDeleteCollectionConfirm(collection.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.historyCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.historyDeleteCollection,
                style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      if (_selectedCollectionId == collection.id) {
        setState(() => _selectedCollectionId = null);
      }
      await context.read<HistoryService>().deleteCollection(collection.id!);
    }
  }

  Widget _buildFilterRow(BuildContext context, HistoryService history) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(l10n.historyAllFilter),
              selected: !_favoritesOnly && _selectedCollectionId == null,
              onSelected: (_) => _selectAll(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              avatar: const Icon(Icons.star, size: 16),
              label: Text(l10n.historyFavoritesFilter),
              selected: _favoritesOnly,
              onSelected: (_) => _selectFavorites(),
            ),
          ),
          for (final c in history.collections)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onLongPress: () => _confirmDeleteCollection(context, c),
                child: FilterChip(
                  label: Text(c.name),
                  selected: _selectedCollectionId == c.id,
                  onSelected: (_) => _selectCollection(c.id!),
                ),
              ),
            ),
          ActionChip(
            avatar: const Icon(Icons.add, size: 16),
            label: Text(l10n.historyNewCollection),
            onPressed: () => _createCollection(context),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.historyTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          Consumer<SettingsService>(
            builder: (context, settings, _) => KofiButton(
              show: settings.showKofiButton,
            ),
          ),
        ],
      ),
      body: Consumer<HistoryService>(
        builder: (context, history, _) {
          if (history.entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history,
                      size: 64,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.12)),
                  const SizedBox(height: 16),
                  Text(
                    l10n.historyEmptyTitle,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.historyEmptySubtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.24),
                    ),
                  ),
                ],
              ),
            );
          }

          final filtered = _filteredEntries(history);

          return Column(
            children: [
              _buildFilterRow(context, history),
              const SizedBox(height: 8),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          l10n.historyNoFilterResults,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.38),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final entry = filtered[index];
                          return _HistoryCard(
                                  key: ValueKey(entry.id), entry: entry)
                              .animate(delay: (index * 50).ms)
                              .fadeIn()
                              .slideY(begin: 0.1);
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// T51: bottom sheet to add/remove [entry] from any number of collections,
/// with inline creation of a new one. Shared by the history card's
/// long-press and the detail screen's collections button.
Future<void> _openCollectionsSheet(
    BuildContext context, HistoryEntry entry) async {
  if (entry.id == null) return;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CollectionsSheet(entryId: entry.id!),
  );
}

class _CollectionsSheet extends StatefulWidget {
  final int entryId;
  const _CollectionsSheet({required this.entryId});

  @override
  State<_CollectionsSheet> createState() => _CollectionsSheetState();
}

class _CollectionsSheetState extends State<_CollectionsSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _create(HistoryService history) async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    final collection = await history.createCollection(name);
    await history.setEntryInCollection(widget.entryId, collection.id!, true);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Consumer<HistoryService>(
        builder: (context, history, _) {
          final memberIds = history.collectionIdsForEntry(widget.entryId);
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.historyAddToCollection,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (history.collections.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(l10n.historyNoCollectionsYet,
                        style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.38))),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final c in history.collections)
                          CheckboxListTile(
                            value: memberIds.contains(c.id),
                            title: Text(c.name),
                            contentPadding: EdgeInsets.zero,
                            onChanged: (checked) =>
                                history.setEntryInCollection(
                                    widget.entryId, c.id!, checked ?? false),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: InputDecoration(
                            hintText: l10n.historyNewCollectionHint),
                        onSubmitted: (_) => _create(history),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _create(history),
                      child: Text(l10n.historyCreateCollection),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final HistoryEntry entry;
  const _HistoryCard({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final dateStr = DateFormat(
            'd MMM yyyy · HH:mm', Localizations.localeOf(context).toString())
        .format(entry.createdAt);
    final isFailed = entry.status == AnalysisStatus.failed;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            if (entry.isPending || isFailed) {
              _retryAnalysis(context, entry);
            } else if (entry.isCaptured) {
              _launchAnalysis(context, entry);
            } else {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HistoryDetailScreen(entry: entry),
                ),
              );
            }
          },
          // T51: long-press anywhere on the card to assign it to collections.
          onLongPress: entry.id == null
              ? null
              : () => _openCollectionsSheet(context, entry),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Thumbnail
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 72,
                        height: 72,
                        child: File(entry.imagePath).existsSync()
                            ? RotatedBox(
                                // #152/#183: this thumbnail is a fixed
                                // 72x72 square, so the width/height swap
                                // RotatedBox does for an odd quarter turn
                                // is a no-op here — unlike the full-bleed
                                // BackgroundPhoto, which accounts for it
                                // explicitly.
                                quarterTurns: entry.rotationQuarters,
                                child: Image.file(
                                  File(entry.imagePath),
                                  fit: BoxFit.cover,
                                ),
                              )
                            : Container(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.image_not_supported,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.24)),
                              ),
                      ),
                    ),
                    if (entry.id != null)
                      Positioned(
                        top: 2,
                        left: 2,
                        child: GestureDetector(
                          onTap: () => context
                              .read<HistoryService>()
                              .toggleFavorite(entry.id!),
                          // #145: fixed black/white — this badge sits on
                          // the thumbnail photo, not themed chrome.
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: const BoxDecoration(
                              color: Colors.black45,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              entry.isFavorite ? Icons.star : Icons.star_border,
                              size: 14,
                              color: entry.isFavorite
                                  ? Colors.amberAccent
                                  : Colors.white70,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),

                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (entry.locationName != null) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.location_on,
                                size: 12,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.38)),
                            const SizedBox(width: 2),
                            Text(
                              entry.locationName!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.38),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (entry.status == AnalysisStatus.complete &&
                          !entry.hasAudio) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.text_snippet_outlined,
                                size: 12,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.38)),
                            const SizedBox(width: 2),
                            Text(
                              l10n.historyScriptOnly,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.38),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (entry.isCaptured) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(Icons.cloud_off_outlined,
                                size: 12,
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.38)),
                            const SizedBox(width: 2),
                            Text(
                              l10n.historyCapturedTapToAnalyze,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface
                                    .withValues(alpha: 0.38),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (isFailed) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            const Icon(Icons.refresh,
                                size: 12, color: Colors.orangeAccent),
                            const SizedBox(width: 2),
                            Text(
                              l10n.historyFailedTapToRetry,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.orangeAccent,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        dateStr,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.24),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),

                Icon(Icons.chevron_right,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.24)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// #145: every `Colors.white*`/`Colors.black*` literal in this class is
/// deliberate, not an oversight — this screen renders its entire content
/// column over [BackgroundPhoto] + a gradient vignette, not the app's
/// themed chrome. Both the vignette and the text/icons on top of it stay
/// a fixed on-scrim color regardless of the app's light/dark setting,
/// the same way the vignette itself doesn't change with the theme —
/// swapping to `colorScheme.onSurface` would make them illegible against
/// both the photo and a light theme's dark-on-light assumption.
class HistoryDetailScreen extends StatefulWidget {
  final HistoryEntry entry;

  /// Starts playback automatically once this screen is shown — used when
  /// arriving here from a "ready" notification tap for an analysis that
  /// finished while the app was backgrounded (playback was deliberately
  /// deferred, see [AudioGuideService.analyzeAndPlay]'s background gating).
  final bool autoPlay;
  const HistoryDetailScreen(
      {super.key, required this.entry, this.autoPlay = false});

  @override
  State<HistoryDetailScreen> createState() => _HistoryDetailScreenState();
}

class _HistoryDetailScreenState extends State<HistoryDetailScreen> {
  bool _isPlaying = false;

  /// The native side that owns cached-WAV playback — the same channel
  /// GeminiTtsService drives, so play/stop/seek all go through one place.
  static const channel = MethodChannel('audio_guide/audio_player');

  /// Whether skip ±10s is meaningful for what's playing right now.
  ///
  /// Mirrors [AudioGuideService.canSkip]'s reasoning rather than
  /// re-deriving it: skipping needs a seekable position, which native TTS
  /// speaking live doesn't have. Two ways playback *is* seekable here:
  ///  - [HistoryEntry.hasAudio] — a cached file replayed via `playWav`.
  ///    Note this is `hasAudio` alone, deliberately not
  ///    `hasAudio && ttsModel == 'gemini-tts'`: legacy 'piper' cached
  ///    files go through the very same MediaPlayer and seek just as well,
  ///    so gating on the model would needlessly exclude them.
  ///  - [AudioGuideService.canSkip] — audio generated on the fly for a
  ///    script-only entry (T16) and played by GeminiTtsService, which is
  ///    seekable but has no cached file on this entry yet.
  bool _canSkip(HistoryEntry live, AudioGuideService guide) =>
      _isPlaying && (live.hasAudio || guide.canSkip);
  bool _isUpgrading = false;
  bool _photoMode =
      false; // T94: show the plain photo instead of the script overlay

  /// Always read the latest version from the service (not the stale widget.entry)
  HistoryEntry _liveEntry(BuildContext context) {
    final history = context.read<HistoryService>();
    return history.entries.firstWhere(
      (e) => e.id == widget.entry.id,
      orElse: () => widget.entry,
    );
  }

  /// #126: swipe-to-navigate, always over the full unfiltered list
  /// (`HistoryService.entries`) rather than whatever favorites/collection
  /// filter was active on the list screen this was opened from — the 3
  /// call sites that push this screen (history list, home-screen recents
  /// grid, notification tap) only ever pass a single [HistoryEntry] today,
  /// not a filtered list or index, so resolving "next in the active
  /// filter" would need new plumbing through all of them. Full-list order
  /// needs none. No-ops at the first/last entry — nothing to report,
  /// there's no error to surface.
  void _navigateAdjacent(BuildContext context, int direction) {
    final entries = context.read<HistoryService>().entries;
    final live = _liveEntry(context);
    final idx = entries.indexWhere((e) => e.id == live.id);
    final target = idx + direction;
    if (idx == -1 || target < 0 || target >= entries.length) return;
    Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => HistoryDetailScreen(entry: entries[target]),
        ));
  }

  // Use AudioGuideService TTS so same voice as first analysis.
  // dynamic: GeminiTtsService/NativeTtsService share no common interface,
  // only the .stop()/.speak() calls this method's callers actually use.
  dynamic _getTts(BuildContext context) {
    final guide = context.read<AudioGuideService>();
    return guide.geminiTtsService ?? guide.nativeTtsService;
  }

  // Play cached audio file directly without re-generating TTS
  Future<void> _playCachedAudio(String path) async {
    channel.invokeMethod('playWav', {'path': path}).then((_) {
      if (!mounted) return;
      setState(() => _isPlaying = false);
    });
  }

  /// Skip playback by [deltaMs], negative to go back.
  ///
  /// Talks to the same audio_guide/audio_player channel GeminiTtsService
  /// uses for its own skip controls, so this needs no new native plumbing
  /// — the channel already defaults to a 10s delta.
  Future<void> _skip(int deltaMs) async {
    await channel.invokeMethod(
      deltaMs >= 0 ? 'seekForward' : 'seekBack',
      {'deltaMs': deltaMs.abs()},
    );
  }

  @override
  void initState() {
    super.initState();
    // #255: instance hash distinguishes stacked pushes in the log (e.g.
    // this screen staying mounted underneath a pushed PlayerScreen during
    // a retry) — matters for diagnosing navigation-timing issues like
    // #246.
    AppLogger.nav(
        'HistoryDetailScreen opened (instance ${identityHashCode(this)}, '
        'entry: ${widget.entry.id}, "${widget.entry.title}", '
        'autoPlay: ${widget.autoPlay})');
    // Captured now, not read from context in dispose(): during a bulk
    // teardown (the whole tree unmounting at once, e.g. app shutdown or
    // a test's finalization) an ancestor Provider can already be
    // deactivated by the time a descendant's dispose() runs, and
    // context.read() at that point throws ("Looking up a deactivated
    // widget's ancestor is unsafe").
    _guide = context.read<AudioGuideService>();
    if (widget.autoPlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _toggleAudio());
    }
  }

  late final AudioGuideService _guide;

  /// Set only while this screen owns some TTS service's `onComplete` (see
  /// [_withTrackedCompletion]) — the callback it's about to restore once
  /// the current speech either finishes or this screen goes away,
  /// whichever comes first. [_completionOwner] remembers which service
  /// (`nativeTtsService` or `geminiTtsService` — both expose the same
  /// `Function()? onComplete` shape, no common interface to type this as)
  /// that restore belongs to.
  void Function()? _restoreOnComplete;
  dynamic _completionOwner;

  /// Speaks via [tts] (`nativeTtsService` or `geminiTtsService`), tracking
  /// `_isPlaying` without permanently hijacking that shared singleton's
  /// `onComplete`.
  ///
  /// A plain `tts.onComplete = () => setState(...)` (what this used to do,
  /// for both services independently — #315's code review caught the
  /// Gemini TTS one still doing this after the native TTS instance was
  /// already fixed) leaks two ways: if this screen closes before speech
  /// finishes, the closure still fires later and calls `setState` on a
  /// disposed State; and since it's never restored, it permanently
  /// replaces [AudioGuideService]'s own default completion handler (the
  /// one set in `init()`, which resets `_state`/`canSkip`) — starving
  /// every later screen's read of that state until the app restarts.
  ///
  /// [action] is whatever triggers the speech this screen wants to track
  /// — a direct `nativeTtsService.speak()`/`geminiTtsService.speak()` call,
  /// or the orchestrated `generateAudioForScript()` pipeline (which copies
  /// whatever's set on native onto Gemini TTS too, see
  /// [TtsOrchestrator.speak]) — the tracking closure itself self-restores
  /// the instant it fires, so every call site can share this without
  /// needing to know which one wins.
  Future<T> _withTrackedCompletion<T>(
    dynamic tts,
    Future<T> Function() action,
  ) async {
    _restoreOnComplete = tts.onComplete;
    _completionOwner = tts;
    tts.onComplete = () {
      tts.onComplete = _restoreOnComplete;
      _restoreOnComplete = null;
      _completionOwner = null;
      if (!mounted) return;
      setState(() => _isPlaying = false);
    };
    return action();
  }

  @override
  void dispose() {
    AppLogger.nav(
        'HistoryDetailScreen closed (instance ${identityHashCode(this)}, '
        'entry: ${widget.entry.id})');
    // Stop playback when leaving screen
    channel.invokeMethod('stop');
    _guide.nativeTtsService.stop();
    // If speech is still in flight, our tracking closure above is still
    // installed — put the previous handler back so a completion firing
    // after this screen is gone doesn't touch a disposed State or leave
    // AudioGuideService's own state stuck.
    if (_restoreOnComplete != null) {
      _completionOwner.onComplete = _restoreOnComplete;
    }
    super.dispose();
  }

  Future<void> _toggleAudio() async {
    if (_isPlaying) {
      final tts = _getTts(context);
      await tts.stop();
      setState(() => _isPlaying = false);
      return;
    }

    // #246: a regenerate (or any other analysis) already running on the
    // same shared AudioGuideService — starting a second operation here
    // raced with it finishing (both fast-failing near-simultaneously,
    // each with its own setState/SnackBar) right as the regenerate's own
    // Navigator.push transition was resolving, and showed up as this
    // screen's content bleeding through PlayerScreen. Same guard
    // runAnalysisAndNavigate already uses for the reverse direction.
    if (context.read<AudioGuideService>().isBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Une analyse est déjà en cours.')),
      );
      return;
    }

    final live = _liveEntry(context);
    setState(() => _isPlaying = true);

    if (live.hasAudio) {
      // Use cached audio — no TTS regeneration needed
      await _playCachedAudio(live.audioPath!);
      return;
    }

    if (live.hasLowQualityTts) {
      // T133: this entry's last known voice was the native fallback
      // (Gemini TTS failed at analysis time) and there's no cached file
      // (native TTS speaks live, never caches) — just replay it live
      // instead of silently re-attempting Gemini here too. The dedicated
      // "Améliorer la voix" button below is the explicit way to retry
      // Gemini.
      final guide = context.read<AudioGuideService>();
      // #130: this bypasses generateAudioForScript/_synthesizeAndPlay, so
      // the native TTS language has to be applied explicitly here too.
      guide.prepareNativeTtsLanguageForReplay(
        context.read<SettingsService>().outputLanguage,
      );
      await _withTrackedCompletion(
          guide.nativeTtsService, () => guide.nativeTtsService.speak(live.script));
      return;
    }

    // No cached audio (T16 — script-only entry, or a missing cache file):
    // generate via the orchestrated pipeline (cloud TTS + native fallback)
    // and persist the result so it's cached from now on.
    final guide = context.read<AudioGuideService>();
    final history = context.read<HistoryService>();
    final result = await _withTrackedCompletion(
      guide.nativeTtsService,
      () => guide.generateAudioForScript(
        title: live.title,
        script: live.script,
        locationName: live.locationName,
        language: context.read<SettingsService>().outputLanguage,
      ),
    );

    if (result == null) {
      // Synthesis failed — onComplete above never fires, reset locally.
      setState(() => _isPlaying = false);
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(guide.lastGuideError != null
                ? localizeGuideError(l10n, guide.lastGuideError!)
                : l10n.historyAudioGenerationFailed),
            duration: const Duration(seconds: 4),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      }
      return;
    }

    final audioPath = guide.lastAudioPath;
    if (audioPath != null && live.id != null) {
      try {
        await history.saveAudioPath(
          live.id!,
          audioPath,
          ttsModel: guide.lastTtsModel,
          ttsFallback: guide.ttsWasFallback,
        );
      } on HistoryStorageException catch (e) {
        // Playback via guide already worked — only caching the audio
        // file for next time failed (T116).
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  localizeHistoryStorageException(AppLocalizations.of(context)!, e))));
        }
      }
    }
  }

  Future<void> _deleteEntry(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l10n.historyDeleteTitle),
        content: Text(l10n.historyDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.historyCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.historyDeleteTitle,
                style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await context.read<HistoryService>().deleteEntry(widget.entry.id!);
      if (context.mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final live = _liveEntry(context);
    final dateStr = DateFormat('EEEE d MMMM yyyy · HH:mm',
            Localizations.localeOf(context).toString())
        .format(live.createdAt);

    // Always a darkened photo background, never colorScheme.surface — see
    // the matching comment in player_screen.dart's build() for why this
    // shouldn't follow the app theme's brightness like the global
    // AnnotatedRegion in main.dart does.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        // #126: swipe between entries — only when not zoomed/panning the
        // photo (_photoMode), so this doesn't fight BackgroundPhoto's own
        // InteractiveViewer for the gesture arena.
        body: GestureDetector(
          onHorizontalDragEnd: _photoMode
              ? null
              : (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity < -200) {
                    _navigateAdjacent(context, 1); // swipe left -> next/older
                  } else if (velocity > 200) {
                    _navigateAdjacent(
                        context, -1); // swipe right -> previous/newer
                  }
                },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // #147: shared with player_screen.dart. T96: the reading-mode
              // gradient here is a 3-stop vignette (stronger at the very top
              // than the player's) to protect the top bar icons — especially
              // the red delete icon — over a bright photo, not just the
              // bottom text.
              PhotoGradientBackground(
                file: File(live.imagePath),
                rotationQuarters: live.rotationQuarters,
                photoMode: _photoMode,
                readingGradientColors: [
                  Colors.black.withValues(alpha: 0.45),
                  Colors.black.withValues(alpha: 0.15),
                  Colors.black.withValues(alpha: 0.95),
                ],
                readingGradientStops: const [0.0, 0.3, 1.0],
              ),

              SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Top bar — each icon gets its own scrim (T96) so it stays
                    // legible regardless of gradient tuning or photo content.
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(
                        children: [
                          ScrimIconButton(
                            icon: Icons.arrow_back,
                            color: Colors.white,
                            tooltip: l10n.commonBack,
                            onPressed: () => Navigator.pop(context),
                          ),
                          // #235: was 6 icons in a horizontally-scrollable
                          // Row (rotate was the newest, #152/#183) — the
                          // least-recently-added ones (info, delete) scrolled
                          // off-screen and weren't discoverable without
                          // knowing to swipe. Only the two frequent, glanceable
                          // state toggles stay visible; the rest move into the
                          // overflow menu below.
                          const Spacer(),
                          ScrimIconButton(
                            icon: live.isFavorite
                                ? Icons.star
                                : Icons.star_border,
                            color: live.isFavorite
                                ? Colors.amberAccent
                                : Colors.white70,
                            tooltip: live.isFavorite
                                ? l10n.historyRemoveFromFavorites
                                : l10n.historyAddToFavorites,
                            // #190: same root cause as the rotate menu item
                            // below — _liveEntry(context) reads HistoryService
                            // via context.read, so nothing here rebuilds this
                            // screen just because toggleFavorite() notified a
                            // change.
                            onPressed: () async {
                              await context
                                  .read<HistoryService>()
                                  .toggleFavorite(live.id!);
                              if (mounted) setState(() {});
                            },
                          ),
                          const SizedBox(width: 4),
                          ScrimIconButton(
                            icon: _photoMode
                                ? Icons.article_outlined
                                : Icons.image_outlined,
                            color: Colors.white70,
                            tooltip: _photoMode
                                ? l10n.playerShowText
                                : l10n.playerPhotoMode,
                            onPressed: () =>
                                setState(() => _photoMode = !_photoMode),
                          ),
                          const SizedBox(width: 4),
                          // #246: regenerate disabled while a play/generate
                          // operation from the button below is in flight (or
                          // any other analysis is running elsewhere) — see
                          // the matching guard in _toggleAudio for why.
                          Consumer<AudioGuideService>(
                            builder: (context, guide, _) => _DetailOverflowMenu(
                              regenerateEnabled: !_isPlaying && !guide.isBusy,
                              onAddToCollection: () =>
                                  _openCollectionsSheet(context, live),
                              onRotate: () async {
                                try {
                                  await context
                                      .read<HistoryService>()
                                      .rotateEntry(live.id!);
                                  // #190: _liveEntry(context) reads
                                  // HistoryService via context.read, not watch
                                  // — this screen never rebuilds on its own
                                  // just because HistoryService notified a
                                  // change, so without this the new rotation
                                  // stayed invisible until some unrelated
                                  // setState (e.g. toggling photo mode)
                                  // happened to force a rebuild that re-read
                                  // it fresh.
                                  if (mounted) setState(() {});
                                } on HistoryStorageException catch (e) {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content: Text(localizeHistoryStorageException(
                                                AppLocalizations.of(context)!, e))));
                                  }
                                }
                              },
                              onRegenerate: () =>
                                  _openRegenerateSheet(context, live),
                              onInfo: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => AboutAnalysisScreen(
                                          entry: widget.entry))),
                              onDelete: () => _deleteEntry(context),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Content
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // T94: everything but the play/generate button below
                            // is hidden in photo mode, matching player_screen.dart
                            // — playback stays controllable while the photo is
                            // shown unobstructed.
                            if (!_photoMode) ...[
                              // Date
                              // #128: white70, not white54 — see the matching
                              // comment in player_screen.dart.
                              Text(
                                dateStr,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.white70,
                                ),
                              ),
                              const SizedBox(height: 8),

                              // Title
                              Text(
                                live.title,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),

                              if (live.locationName != null) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    const Icon(Icons.location_on,
                                        color: Colors.white70, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      live.locationName!,
                                      style: const TextStyle(
                                          color: Colors.white70),
                                    ),
                                  ],
                                ),
                              ],

                              // #126
                              if (live.gpsLatitude != null &&
                                  live.gpsLongitude != null) ...[
                                const SizedBox(height: 8),
                                MiniMap(
                                  latitude: live.gpsLatitude!,
                                  longitude: live.gpsLongitude!,
                                ),
                              ],

                              const SizedBox(height: 16),

                              // #147: shared with player_screen.dart.
                              GuideActionRow(
                                imagePath: live.imagePath,
                                rotationQuarters: live.rotationQuarters,
                                script: live.script,
                                title: live.title,
                                audioPath: live.audioPath,
                                aiModel: live.aiModel,
                                reportDate: live.analyzedAt ?? live.createdAt,
                                saveLabel: l10n.historySave,
                                savedSnackbarText:
                                    l10n.historyPhotoSavedToGallery,
                                copyLabel: l10n.historyCopy,
                                copiedSnackbarText: l10n.historyTextCopied,
                              ),
                              const SizedBox(height: 8),

                              // Script
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color:
                                          Colors.white.withValues(alpha: 0.1)),
                                ),
                                child: Text(
                                  live.script,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.85),
                                    height: 1.6,
                                  ),
                                ),
                              ),

                              const SizedBox(height: 20),
                            ], // end if (!_photoMode)
                          ],
                        ),
                      ),
                    ),

                    // Upgrade TTS button — deliberately kept out of the
                    // scrollable content above (T133): it used to live inside
                    // the `if (!_photoMode)` section, so it silently vanished
                    // in photo mode, and for a native-TTS-fallback entry (no
                    // cached audioPath) it was the ONLY way back to Gemini's
                    // better voice — same reasoning as the play/generate
                    // button below (T122).
                    if (_liveEntry(context).hasLowQualityTts)
                      Consumer<AudioGuideService>(
                        builder: (context, guide, _) {
                          if (guide.geminiTtsService == null) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                            child: OutlinedButton.icon(
                              icon: _isUpgrading
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.amber))
                                  : const Icon(Icons.auto_awesome, size: 16),
                              label: Text(_isUpgrading
                                  ? l10n.historyUpgradingVoice
                                  : l10n.historyUpgradeVoice),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.amber,
                                side: const BorderSide(color: Colors.amber),
                                minimumSize: const Size(double.infinity, 48),
                              ),
                              onPressed: _isUpgrading
                                  ? null
                                  : () async {
                                      final history =
                                          context.read<HistoryService>();
                                      setState(() => _isUpgrading = true);
                                      try {
                                        final tts = guide.geminiTtsService!;
                                        // Generate audio first, then play
                                        await _withTrackedCompletion(
                                            tts, () => tts.speak(live.script));
                                        // Save upgraded audio
                                        final lastPath = tts.lastWavPath;
                                        AppLogger.tts(
                                            'upgrade lastAudioPath: $lastPath, entry.id: ${live.id}');
                                        if (lastPath != null &&
                                            live.id != null) {
                                          await history.saveAudioPath(
                                              live.id!, lastPath,
                                              ttsModel: 'gemini-tts',
                                              ttsFallback: false);
                                          AppLogger.tts('saveAudioPath OK');
                                        } else {
                                          AppLogger.error(
                                              'saveAudioPath skipped: lastPath=$lastPath id=${live.id}');
                                        }
                                        setState(() => _isPlaying = true);
                                      } catch (error) {
                                        setState(() => _isPlaying = false);
                                        if (context.mounted) {
                                          final message =
                                              formatVoiceUpgradeErrorMessage(
                                                  error, l10n);
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(message),
                                              duration:
                                                  const Duration(seconds: 4),
                                              backgroundColor:
                                                  Colors.orange.shade800,
                                            ),
                                          );
                                        }
                                      } finally {
                                        setState(() => _isUpgrading = false);
                                      }
                                    },
                            ),
                          );
                        },
                      ),

                    // Play / generate button — deliberately kept out of the
                    // scrollable content above and anchored here instead
                    // (T122): when _photoMode hides everything else, a
                    // scroll view's remaining content aligns to its top, not
                    // the bottom of the screen — the button used to float
                    // awkwardly over the middle of the photo instead of
                    // sitting at the bottom like a real control, matching
                    // player_screen.dart's own playback controls.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                      // Scoped to just this row: canSkip flips as the
                      // service's own playback state changes (e.g. synthesis
                      // finishing for a script-only entry), and the skip
                      // buttons need to appear when it does — but nothing
                      // else in this screen (photo, gradient, script text)
                      // needs to rebuild on every AudioGuideService change.
                      child: Consumer<AudioGuideService>(
                        builder: (context, guide, _) {
                          final showSkip = _canSkip(live, guide);
                          return Row(
                            children: [
                              // Skip only when the current playback is
                              // seekable — see _canSkip.
                              if (showSkip) ...[
                                // #147: shared with player_screen.dart.
                                SkipIconButton(
                                  forward: false,
                                  onPressed: () => _skip(-10000),
                                ),
                                const SizedBox(width: 4),
                              ],
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _toggleAudio,
                                  icon: Icon(_isPlaying
                                      ? Icons.stop
                                      : ((live.hasAudio ||
                                              live.hasLowQualityTts)
                                          ? Icons.play_arrow
                                          : Icons.auto_awesome)),
                                  label: Text(_isPlaying
                                      ? l10n.historyStop
                                      : ((live.hasAudio ||
                                              live.hasLowQualityTts)
                                          ? l10n.historyListen
                                          : l10n.historyGenerateAudio)),
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(0, 52),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(14)),
                                  ),
                                ),
                              ),
                              if (showSkip) ...[
                                const SizedBox(width: 4),
                                SkipIconButton(
                                  forward: true,
                                  onPressed: () => _skip(10000),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// #235: the overflow menu for `HistoryDetailScreen`'s top bar — the 5
/// actions that don't need to be always-visible (add to collection,
/// rotate, regenerate, info, delete), moved out of a horizontally-
/// scrollable icon row that was pushing the least-recently-added ones
/// (info, delete) off-screen. Each callback is fired from `onSelected`
/// rather than baked into the item itself, so the caller keeps full
/// control of context/mounted-checks the same way the inlined
/// `ScrimIconButton.onPressed`s used to.
enum _DetailMenuAction { addToCollection, rotate, regenerate, info, delete }

class _DetailOverflowMenu extends StatelessWidget {
  final VoidCallback onAddToCollection;
  final VoidCallback onRotate;
  final VoidCallback onRegenerate;
  final VoidCallback onInfo;
  final VoidCallback onDelete;
  final bool regenerateEnabled;

  const _DetailOverflowMenu({
    required this.onAddToCollection,
    required this.onRotate,
    required this.onRegenerate,
    required this.onInfo,
    required this.onDelete,
    this.regenerateEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // #145: stays fixed black regardless of app theme, matching
        // ScrimIconButton — see that class's doc.
        color: Colors.black.withValues(alpha: 0.35),
      ),
      child: PopupMenuButton<_DetailMenuAction>(
        tooltip: l10n.historyMoreActions,
        icon: const Icon(Icons.more_vert, color: Colors.white70),
        onSelected: (action) {
          switch (action) {
            case _DetailMenuAction.addToCollection:
              onAddToCollection();
              break;
            case _DetailMenuAction.rotate:
              onRotate();
              break;
            case _DetailMenuAction.regenerate:
              onRegenerate();
              break;
            case _DetailMenuAction.info:
              onInfo();
              break;
            case _DetailMenuAction.delete:
              onDelete();
              break;
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: _DetailMenuAction.addToCollection,
            child: _MenuRow(
                icon: Icons.playlist_add, label: l10n.historyAddToCollection),
          ),
          PopupMenuItem(
            value: _DetailMenuAction.rotate,
            child: _MenuRow(
                icon: Icons.rotate_90_degrees_cw_outlined,
                label: l10n.historyRotatePhoto),
          ),
          PopupMenuItem(
            value: _DetailMenuAction.regenerate,
            // #246: disabled while a play/generate operation is already
            // in flight, to avoid racing it with a fresh analysis.
            enabled: regenerateEnabled,
            child: _MenuRow(
                icon: Icons.tune,
                label: l10n.historyRegenerateTooltip,
                color: regenerateEnabled ? null : Colors.black38),
          ),
          PopupMenuItem(
            value: _DetailMenuAction.info,
            child: _MenuRow(
                icon: Icons.info_outline, label: l10n.aboutAnalysisTitle),
          ),
          const PopupMenuDivider(),
          PopupMenuItem(
            value: _DetailMenuAction.delete,
            child: _MenuRow(
              icon: Icons.delete_outline,
              label: l10n.historyDeleteTitle,
              color: Colors.redAccent,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _MenuRow({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label,
              style: TextStyle(color: color), overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}
