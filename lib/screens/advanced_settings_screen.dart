import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../services/remote_config_service.dart';
import '../utils/build_info.dart';
import '../utils/date_format_utils.dart';
import '../widgets/section_header.dart';
import 'logs_screen.dart';

/// #366: the raw remote-config dump and developer tools (View logs, View
/// source code) used to sit directly in the main Settings scroll, between
/// "Active AI Engine" and "Voice" — a typical user changing the narration
/// voice had to scroll past "Thinking budget: 512" with no framing. Split
/// out into its own opt-in screen, mirroring how `about_analysis_screen.dart`
/// already handles this kind of technical detail: reached via a single
/// entry point, not part of the everyday settings flow.
class AdvancedSettingsScreen extends StatefulWidget {
  const AdvancedSettingsScreen({super.key});

  @override
  State<AdvancedSettingsScreen> createState() => _AdvancedSettingsScreenState();
}

class _AdvancedSettingsScreenState extends State<AdvancedSettingsScreen> {
  String? _appVersion;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = '${info.version} (${info.buildNumber})');
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsAdvancedTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          SectionHeader(l10n.settingsActiveConfig),
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

          SectionHeader(l10n.settingsTools),
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
        ],
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
