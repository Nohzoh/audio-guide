import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'logs_screen.dart';
import 'nano_prompt_lab_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../constants/output_languages.dart';
import '../l10n/app_localizations.dart';
import '../services/audio_guide_service.dart';
import '../services/feedback_service.dart';
import '../services/gemini_nano_service.dart' show NanoDeviceStatus;
import '../services/history_service.dart';
import '../services/remote_config_service.dart';
import '../services/secure_key_storage.dart';
import '../services/settings_service.dart';
import '../widgets/kofi_button.dart';
import '../utils/build_info.dart';
import '../utils/date_format_utils.dart';
import '../utils/exif_strip.dart';

const _ttsPreviewSample =
    'Voici un exemple de la voix qui sera utilisée pour vos guides audio. '
    'Remarquez le rythme et l\'intonation sur cette phrase.';

class SettingsScreen extends StatefulWidget {
  // #294: overridable for tests — a plain `flutter test` run has no
  // --dart-define TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID (those only exist
  // in a CI build), so FeedbackService() alone would always be
  // unconfigured under test.
  const SettingsScreen({super.key, FeedbackService? feedbackService})
      : _feedbackService = feedbackService;

  final FeedbackService? _feedbackService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final FeedbackService _feedback =
      widget._feedbackService ?? FeedbackService();
  final _apiKeyController = TextEditingController();
  final _apiKeyFocusNode = FocusNode();
  // #278: the "Gemini API" provider card used to just render disabled
  // (grey, no tap target) until a key was saved, with the explanation of
  // how to get one only visible several sections further down — nothing
  // told the user where to look. Tapping the card now scrolls this
  // section (header + "get a free key" text + field, wrapped together so
  // the explanation stays visible, not just the field) into view and
  // focuses the field, instead of silently doing nothing.
  final _apiKeySectionKey = GlobalKey();
  bool _obscure = true;
  bool _saving = false;
  String? _appVersion;
  // #283: null while the check is in flight — the card falls back to the
  // old generic "(not configured)" wording for that brief window rather
  // than blocking on it.
  NanoDeviceStatus? _nanoStatus;

  @override
  void initState() {
    super.initState();
    final guide = context.read<AudioGuideService>();
    _apiKeyController.text = guide.geminiApiKey ?? '';
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = '${info.version} (${info.buildNumber})');
    });
    guide.nanoService.checkDeviceStatus().then((status) {
      if (mounted) setState(() => _nanoStatus = status);
    });
    // #325: checkDeviceStatus() above only refreshes the display string —
    // this re-checks the actual gate the provider card's onTap/isAvailable
    // uses, so Nano finishing its download mid-session (revealed by the
    // status above) actually unlocks the card instead of requiring an app
    // restart. notifyListeners() inside triggers this screen's own
    // context.watch<AudioGuideService>() rebuild.
    guide.refreshNanoAvailability();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _apiKeyFocusNode.dispose();
    super.dispose();
  }

  // #283: null falls back to _ProviderCard's generic "(not configured)"
  // suffix — used while the check is still in flight, when Nano is
  // actually available (nothing to explain), or when the platform
  // returned an unrecognized/error status (nothing more specific to say).
  String? _nanoUnavailableReason(AppLocalizations l10n) {
    switch (_nanoStatus) {
      case NanoDeviceStatus.unavailable:
        return l10n.settingsNanoUnavailableDevice;
      case NanoDeviceStatus.downloadable:
        return l10n.settingsNanoDownloadable;
      case NanoDeviceStatus.downloading:
        return l10n.settingsNanoDownloading;
      case NanoDeviceStatus.available:
        // The device reports Nano ready, yet AiProviderManager.init()'s
        // own initialize() call still failed at startup (a transient
        // error, not a device-support boundary) — distinct enough from
        // the other cases to say so rather than the generic suffix.
        return l10n.settingsNanoInitError;
      case NanoDeviceStatus.unknown:
      case null:
        return null;
    }
  }

  Future<void> _showFeedbackDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _FeedbackDialog(
        feedback: _feedback,
        appVersion: _appVersion,
        history: context.read<HistoryService>(),
      ),
    );
  }

  Future<void> _focusApiKeySection() async {
    final sectionContext = _apiKeySectionKey.currentContext;
    if (sectionContext != null) {
      await Scrollable.ensureVisible(
        sectionContext,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
    if (!mounted) return;
    _apiKeyFocusNode.requestFocus();
  }

  Future<void> _testVoice() async {
    final guide = context.read<AudioGuideService>();
    final played = await guide.nativeTtsService
        .speakAndWaitForResult(_ttsPreviewSample, speed: guide.playbackSpeed);
    if (!played && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.settingsNoVoiceProduced),
        ),
      );
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final guide = context.read<AudioGuideService>();
    try {
      await guide.setGeminiApiKey(_apiKeyController.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.settingsSaved)),
        );
      }
    } on SecureStorageUnavailableException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.secureStorageUnavailable),
            backgroundColor: Colors.orange.shade800,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    _apiKeyController.clear();
    final guide = context.read<AudioGuideService>();
    await guide.setGeminiApiKey('');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.settingsApiKeyDeleted)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final guide = context.watch<AudioGuideService>();
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsTitle),
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
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // #145
          _SectionHeader(l10n.settingsAppearanceSection),
          const SizedBox(height: 8),
          Consumer<SettingsService>(
            builder: (context, settings, _) => SegmentedButton<ThemeMode>(
              // #216: needs BOTH of these, not just one — dropping only the
              // per-segment icons still left the selected segment's
              // checkmark (showSelectedIcon defaults to true) eating into
              // "Système"'s width on a real device, confirmed by the user
              // after the first attempt (icons removed alone) still
              // wrapped. Selection is already unambiguous from the
              // segment's own background/text color change.
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text(l10n.settingsThemeSystem),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text(l10n.settingsThemeLight),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text(l10n.settingsThemeDark),
                ),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (selection) =>
                  settings.setThemeMode(selection.first),
            ),
          ),
          const SizedBox(height: 32),

          // App interface language, independent of the narration language
          // below — lets testers switch it without touching Android's
          // system or per-app language settings.
          _SectionHeader(l10n.settingsLanguageSection),
          const SizedBox(height: 8),
          Consumer<SettingsService>(
            builder: (context, settings, _) => SegmentedButton<String?>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: null,
                  label: Text(l10n.settingsThemeSystem),
                ),
                const ButtonSegment(value: 'fr', label: Text('Français')),
                const ButtonSegment(value: 'en', label: Text('English')),
              ],
              selected: {settings.appLocale},
              onSelectionChanged: (selection) =>
                  settings.setAppLocale(selection.first),
            ),
          ),
          const SizedBox(height: 32),

          // Provider status
          _SectionHeader(l10n.settingsActiveAiEngine),
          const SizedBox(height: 8),
          _ProviderCard(
            icon: Icons.phone_android,
            // #253: "IA locale" / "Local AI", not the brand name — since
            // TTS now always follows this choice too (native voice,
            // never the cloud), the label describes what the option
            // actually guarantees rather than which Google product
            // happens to power the analysis step.
            name: l10n.settingsLocalAiName,
            description: l10n.settingsNanoDescription,
            isActive: guide.activeProvider == AIProvider.geminiNano,
            isAvailable: guide.nanoAvailable,
            onTap: guide.nanoAvailable
                ? () => guide.setActiveProvider(AIProvider.geminiNano)
                : null,
            unavailableReason: _nanoUnavailableReason(l10n),
          ),
          const SizedBox(height: 8),
          _ProviderCard(
            icon: Icons.cloud_outlined,
            name: 'Gemini API',
            description: l10n.settingsApiDescription,
            isActive: guide.activeProvider == AIProvider.geminiApi,
            isAvailable: guide.geminiApiKey?.isNotEmpty == true,
            // #278: previously null (dead tap target) when no key was
            // saved yet, leaving the user with a greyed-out option and no
            // indication of what to do about it. Now guides them straight
            // to where the key is entered instead.
            onTap: guide.geminiApiKey?.isNotEmpty == true
                ? () => guide.setActiveProvider(AIProvider.geminiApi)
                : _focusApiKeySection,
          ),

          const SizedBox(height: 32),

          // Gemini API key — wrapped in a Column (rather than left as
          // separate ListView children) so _focusApiKeySection's
          // Scrollable.ensureVisible brings the section header and the
          // "get a free key" explanation into view together with the
          // field itself (#278), not just the field alone.
          Column(
            key: _apiKeySectionKey,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionHeader(l10n.settingsApiKeySectionTitle),
              const SizedBox(height: 8),
              Text(
                l10n.settingsGetFreeKey,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.54)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                focusNode: _apiKeyFocusNode,
                obscureText: _obscure,
                decoration: InputDecoration(
                  hintText: 'AIza...',
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                            _obscure ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      if (_apiKeyController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: _clear,
                        ),
                    ],
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(l10n.settingsSave),
          ),

          const SizedBox(height: 32),

          // Active config section
          _SectionHeader(l10n.settingsActiveConfig),
          const SizedBox(height: 8),
          Builder(builder: (context) {
            final cfg = RemoteConfigService.current;
            final loadedAt = RemoteConfigService.loadedAt;
            final fromRemote = RemoteConfigService.loadedFromRemote;
            final theme = Theme.of(context);
            final dimText = theme.colorScheme.onSurface.withValues(alpha: 0.38);
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(
                      fromRemote ? Icons.cloud_done : Icons.cloud_off,
                      size: 14,
                      color: fromRemote ? Colors.greenAccent : Colors.orange,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      fromRemote
                          ? l10n.settingsConfigFromGithub
                          : l10n.settingsConfigDefaultOffline,
                      style: TextStyle(
                        color: fromRemote ? Colors.greenAccent : Colors.orange,
                        fontSize: 12,
                      ),
                    ),
                  ]),
                  if (loadedAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      l10n.settingsUpdatedAt(formatLocalDateTime(
                          loadedAt, Localizations.localeOf(context).toString())),
                      style: TextStyle(color: dimText, fontSize: 11),
                    ),
                  ],
                  if (_appVersion != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      l10n.settingsVersionLabel(_appVersion!),
                      style: TextStyle(color: dimText, fontSize: 11),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    l10n.settingsBuildLabel(formatBuildDate(
                        buildDate,
                        Localizations.localeOf(context).toString(),
                        l10n.settingsBuildDateUnavailable)),
                    style: TextStyle(color: dimText, fontSize: 11),
                  ),
                  Divider(
                      height: 20,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.12)),
                  _ConfigRow(l10n.settingsConfigModel, cfg.geminiModel),
                  _ConfigRow(l10n.settingsConfigFallbacks, cfg.geminiModelFallbacks.join(', ')),
                  _ConfigRow(l10n.settingsConfigTtsModel, cfg.geminiTtsModel),
                  _ConfigRow(l10n.settingsConfigTtsVoice, cfg.geminiTtsVoice),
                  _ConfigRow(l10n.settingsConfigMaxTokens, cfg.geminiMaxTokens.toString()),
                  _ConfigRow(
                      l10n.settingsConfigThinkingBudget, cfg.geminiThinkingBudget.toString()),
                  _ConfigRow(
                      l10n.settingsConfigWikipediaRadius, '${cfg.wikipediaRadiusMeters}m'),
                  _ConfigRow(l10n.settingsConfigTtsSpeed, cfg.ttsSpeed.toString()),
                ],
              ),
            );
          }),

          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            label: Text(l10n.settingsRefreshConfig),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
            ),
            onPressed: () async {
              await RemoteConfigService.forceRefresh();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(
                    RemoteConfigService.loadedFromRemote
                        ? l10n.settingsConfigUpdatedFromGithub
                        : l10n.settingsConfigUnreachable,
                  )),
                );
                (context as Element).markNeedsBuild();
              }
            },
          ),

          const SizedBox(height: 32),

          // Developer tools
          _SectionHeader(l10n.settingsTools),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.terminal, size: 16),
            label: Text(l10n.settingsViewLogs),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
            ),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const LogsScreen())),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.code, size: 16),
            label: Text(l10n.settingsViewSourceCode),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
            ),
            onPressed: () => launchUrl(
              Uri.parse('https://github.com/Nohzoh/AudioLens'),
              mode: LaunchMode.externalApplication,
            ),
          ),
          // #294: only shown when this build actually has the Telegram
          // secrets baked in (real CI builds only) — a local/dev build
          // has nothing to send to, so the button would just fail.
          if (_feedback.isConfigured) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.feedback_outlined, size: 16),
              label: Text(l10n.settingsSendFeedback),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
              ),
              onPressed: _showFeedbackDialog,
            ),
          ],
          // Only shown when Nano is actually usable on this device — no
          // point offering a tool to iterate against inference that can't
          // run here at all.
          if (guide.nanoAvailable) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.science_outlined, size: 16),
              label: Text(l10n.settingsNanoPromptLab),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
              ),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const NanoPromptLabScreen())),
            ),
          ],
          const SizedBox(height: 16),
          Consumer<SettingsService>(
            builder: (context, settings, _) => SwitchListTile(
              title: Text(l10n.settingsShowKofiButton),
              subtitle: Text(l10n.settingsKofiButtonSubtitle),
              value: settings.showKofiButton,
              onChanged: (value) => settings.setShowKofiButton(value),
            ),
          ),
          // #309
          Consumer<SettingsService>(
            builder: (context, settings, _) => SwitchListTile(
              title: Text(l10n.settingsShowTips),
              subtitle: Text(l10n.settingsShowTipsSubtitle),
              value: settings.tipsEnabled,
              onChanged: (value) => settings.setTipsEnabled(value),
            ),
          ),
          Consumer<SettingsService>(
            builder: (context, settings, _) => SwitchListTile(
              title: Text(l10n.settingsAutoGenerateAudio),
              subtitle: Text(l10n.settingsAutoGenerateAudioSubtitle),
              value: settings.autoGenerateAudio,
              onChanged: (value) => settings.setAutoGenerateAudio(value),
            ),
          ),
          Consumer<SettingsService>(
            builder: (context, settings, _) => Column(
              children: [
                SwitchListTile(
                  title: Text(l10n.settingsAutoPurge),
                  subtitle: Text(l10n.settingsAutoPurgeSubtitle),
                  value: settings.autoPurgeEnabled,
                  onChanged: (value) => settings.setAutoPurgeEnabled(value),
                ),
                if (settings.autoPurgeEnabled)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final days in const [7, 14, 30, 90])
                          ChoiceChip(
                            label: Text(l10n.settingsAutoPurgeDaysOption(days)),
                            selected: settings.autoPurgeDays == days,
                            onSelected: (_) => settings.setAutoPurgeDays(days),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          _SectionHeader(l10n.settingsVoiceSection),
          const SizedBox(height: 8),
          Consumer<AudioGuideService>(
            builder: (context, guide, _) => SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'female',
                  label: Text(l10n.settingsVoiceFemale),
                  icon: const Icon(Icons.face_3),
                ),
                ButtonSegment(
                  value: 'male',
                  label: Text(l10n.settingsVoiceMale),
                  icon: const Icon(Icons.face_6),
                ),
              ],
              selected: {guide.ttsVoiceGender},
              onSelectionChanged: (selection) =>
                  guide.setTtsVoiceGender(selection.first),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.play_arrow, size: 16),
            label: Text(l10n.settingsTestVoice),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
            ),
            onPressed: _testVoice,
          ),

          const SizedBox(height: 32),

          _SectionHeader(l10n.settingsPlaybackSpeed),
          const SizedBox(height: 8),
          Consumer<AudioGuideService>(
            builder: (context, guide, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in const [
                  (speed: 0.75, label: '0.75x'),
                  (speed: 1.0, label: '1x'),
                  (speed: 1.25, label: '1.25x'),
                  (speed: 1.5, label: '1.5x'),
                ])
                  ChoiceChip(
                    label: Text(option.label),
                    selected: guide.playbackSpeed == option.speed,
                    onSelected: (_) => guide.setPlaybackSpeed(option.speed),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          _SectionHeader(l10n.settingsScriptStyleSection),
          const SizedBox(height: 4),
          Text(
            l10n.settingsScriptStyleSubtitle,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Consumer<SettingsService>(
            builder: (context, settings, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: Text(l10n.settingsStyleImmersive),
                  selected: settings.scriptStyle == 'immersive',
                  onSelected: (_) => settings.setScriptStyle('immersive'),
                ),
                ChoiceChip(
                  label: Text(l10n.settingsStyleAcademic),
                  selected: settings.scriptStyle == 'academic',
                  onSelected: (_) => settings.setScriptStyle('academic'),
                ),
                ChoiceChip(
                  label: Text(l10n.settingsStyleAnecdotal),
                  selected: settings.scriptStyle == 'anecdotal',
                  onSelected: (_) => settings.setScriptStyle('anecdotal'),
                ),
                ChoiceChip(
                  label: Text(l10n.settingsStyleConcise),
                  selected: settings.scriptStyle == 'concise',
                  onSelected: (_) => settings.setScriptStyle('concise'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // #130
          _SectionHeader(l10n.settingsOutputLanguageSection),
          const SizedBox(height: 4),
          Text(
            l10n.settingsOutputLanguageSubtitle,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Consumer<SettingsService>(
            builder: (context, settings, _) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // #260 follow-up: mirrors the app's own interface language
                // (English/French) instead of a fixed pick — stays in sync
                // whenever settings.appLocale changes.
                ChoiceChip(
                  avatar: const Icon(Icons.sync, size: 18),
                  label: Text(l10n.settingsOutputLanguageFollowApp),
                  selected: settings.outputLanguageFollowsApp,
                  onSelected: (_) => settings.setOutputLanguageFollowsApp(true),
                ),
                for (final language in outputLanguageLocales.keys)
                  ChoiceChip(
                    label: Text(language),
                    selected: !settings.outputLanguageFollowsApp &&
                        settings.outputLanguage == language,
                    onSelected: (_) => settings.setOutputLanguage(language),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // Info box
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.54)),
                  const SizedBox(width: 8),
                  Text(l10n.settingsAboutGeminiApi,
                      style: theme.textTheme.labelMedium),
                ]),
                const SizedBox(height: 8),
                Text(
                  l10n.settingsGeminiApiBullets,
                  style: TextStyle(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                      fontSize: 13,
                      height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

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

class _ProviderCard extends StatelessWidget {
  final IconData icon;
  final String name;
  final String description;
  final bool isActive;
  final bool isAvailable;
  final VoidCallback? onTap;
  // #283: when set, replaces the generic "(not configured)" suffix — for
  // Nano specifically, "not configured" is misleading (there's nothing
  // to configure; it's a device capability or a pending download).
  final String? unavailableReason;

  const _ProviderCard({
    required this.icon,
    required this.name,
    required this.description,
    required this.isActive,
    required this.isAvailable,
    this.onTap,
    this.unavailableReason,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: isActive
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? theme.colorScheme.primary : Colors.transparent,
          width: 1.5,
        ),
      ),
      // ListTile paints its background/ink splashes on the nearest Material
      // ancestor — without this, the outer DecoratedBox (from this
      // AnimatedContainer) hides them, making the tap ripple invisible
      // (Flutter's own debug assertion catches this; surfaced by T105's
      // new settings_screen_test.dart, which actually exercises a tap).
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          leading: Icon(
            icon,
            color: isActive
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface
                    .withValues(alpha: isAvailable ? 0.70 : 0.24),
          ),
          title: Text(
            name,
            style: TextStyle(
              color: theme.colorScheme.onSurface
                  .withValues(alpha: isAvailable ? 1.0 : 0.38),
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            isAvailable
                ? description
                : '$description\n${unavailableReason ?? l10n.settingsNotConfiguredSuffix}',
            style: TextStyle(
              color: theme.colorScheme.onSurface
                  .withValues(alpha: isAvailable ? 0.54 : 0.24),
              fontSize: 12,
            ),
          ),
          trailing: isActive
              ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
              : isAvailable
                  ? Icon(Icons.radio_button_unchecked,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.38))
                  : Icon(Icons.lock_outline,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.24)),
          onTap: onTap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }
}

class _ConfigRow extends StatelessWidget {
  final String label;
  final String value;
  const _ConfigRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.54),
                    fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.70),
                    fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// #294
class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog({
    required this.feedback,
    required this.appVersion,
    required this.history,
  });

  final FeedbackService feedback;
  final String? appVersion;
  final HistoryService history;

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  final _controller = TextEditingController();
  bool _sending = false;
  String? _error;
  // #296: e.g. a screenshot of the problem being reported.
  File? _image;
  // #315: an analysis picked from history instead of a manual screenshot —
  // mutually exclusive with _image (Telegram only takes one photo per
  // message), see _pickImage/_pickAnalysis.
  HistoryEntry? _selectedEntry;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final xFile = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (xFile == null || !mounted) return;
    setState(() {
      _image = File(xFile.path);
      _selectedEntry = null;
    });
  }

  Future<void> _pickAnalysis() async {
    final l10n = AppLocalizations.of(context)!;
    // #318: pending/captured/failed entries have an empty script and null
    // model/timing details (never populated until an analysis actually
    // completes) — attaching one would silently send a feedback report
    // with a photo but no exploitable content, defeating the point of the
    // feature. Only a finished analysis has something worth attaching.
    final entries = widget.history.entries
        .where((e) => e.status == AnalysisStatus.complete)
        .toList();
    final selected = await showDialog<HistoryEntry>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.feedbackDialogSelectAnalysisTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: entries.isEmpty
              ? Text(l10n.feedbackDialogNoAnalyses)
              : SizedBox(
                  height: 320,
                  child: ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(File(entry.imagePath),
                              width: 40, height: 40, fit: BoxFit.cover),
                        ),
                        title: Text(entry.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(formatLocalDateTime(
                            entry.createdAt, Localizations.localeOf(context).toString())),
                        onTap: () => Navigator.of(dialogContext).pop(entry),
                      );
                    },
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.feedbackDialogCancel),
          ),
        ],
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _selectedEntry = selected;
        _image = null;
      });
    }
  }

  /// #315: appended to the typed message so the report carries the same
  /// details (model used, timing, etc.) visible in About analysis, without
  /// asking the user to copy them by hand.
  String _formatAttachedAnalysis(HistoryEntry entry) {
    final lines = <String>['', '--- Analyse jointe : ${entry.title} ---'];
    if (entry.aiModel != null) {
      lines.add('Modèle IA : ${entry.aiModel}${entry.aiFallback ? ' (secours)' : ''}');
    }
    if (entry.ttsModel != null) {
      lines.add('Voix : ${entry.ttsModel}${entry.ttsFallback ? ' (secours)' : ''}');
    }
    if (entry.analysisSource != null) lines.add('Source : ${entry.analysisSource}');
    if (entry.analysisDurationMs != null) {
      lines.add('Durée : ${entry.analysisDurationMs} ms');
    }
    if (entry.wordCount != null) lines.add('Mots : ${entry.wordCount}');
    lines.add('Wikipedia : ${entry.wikipediaUsed ? 'oui' : 'non'}');
    if (entry.scriptStyle != null) lines.add('Style : ${entry.scriptStyle}');
    if (entry.outputLanguage != null) lines.add('Langue : ${entry.outputLanguage}');
    if (entry.gpsSource != null) lines.add('GPS : ${entry.gpsSource}');
    lines.addAll(['', 'Script :', entry.script]);
    return lines.join('\n');
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() {
      _sending = true;
      _error = null;
    });

    final analysisEntry = _selectedEntry;
    final fullText =
        analysisEntry != null ? '$text\n${_formatAttachedAnalysis(analysisEntry)}' : text;

    // #319: an attached analysis's photo can be gone from disk (external
    // storage cleanup, a manual deletion, an orphaned DB row after a file
    // loss outside deleteEntry's normal flow) — without this check,
    // MultipartFile.fromPath below throws and the user only sees the
    // generic send-failed error, with no hint that removing the attached
    // analysis is what would fix it.
    if (analysisEntry != null && !File(analysisEntry.imagePath).existsSync()) {
      setState(() {
        _sending = false;
        _error = AppLocalizations.of(context)!.feedbackDialogAnalysisImageMissing;
      });
      return;
    }

    try {
      // #328: the details text above deliberately omits GPS coordinates —
      // the photo itself must not silently reintroduce them via EXIF.
      final image = analysisEntry != null
          ? File(await imagePathWithExifStripped(analysisEntry.imagePath))
          : _image;
      await widget.feedback.send(
        fullText,
        appVersion: widget.appVersion ?? 'unknown',
        platform: defaultTargetPlatform.name,
        image: image,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.feedbackDialogSuccess)),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = AppLocalizations.of(context)!.feedbackDialogError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.feedbackDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            maxLines: 5,
            minLines: 3,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.feedbackDialogHint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (_image != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(_image!, width: 40, height: 40, fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.image_outlined, size: 16),
                  label: Text(_image == null
                      ? l10n.feedbackDialogAttachScreenshot
                      : l10n.feedbackDialogChangeScreenshot),
                  onPressed: _sending || _selectedEntry != null ? null : _pickImage,
                ),
              ),
              if (_image != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.feedbackDialogRemoveScreenshot,
                  onPressed: _sending ? null : () => setState(() => _image = null),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (_selectedEntry != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(_selectedEntry!.imagePath),
                      width: 40, height: 40, fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.history, size: 16),
                  label: Text(_selectedEntry == null
                      ? l10n.feedbackDialogAttachAnalysis
                      : l10n.feedbackDialogChangeAnalysis),
                  onPressed: _sending || _image != null ? null : _pickAnalysis,
                ),
              ),
              if (_selectedEntry != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.feedbackDialogRemoveAnalysis,
                  onPressed: _sending ? null : () => setState(() => _selectedEntry = null),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.feedbackDialogCancel),
        ),
        FilledButton(
          onPressed: _sending ? null : _send,
          child: Text(_sending ? l10n.feedbackDialogSending : l10n.feedbackDialogSend),
        ),
      ],
    );
  }
}
