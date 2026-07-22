import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/audio_guide_service.dart';
import '../services/remote_config_service.dart';
import 'package:intl/intl.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _apiKeyController = TextEditingController();
  bool _obscure = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final guide = context.read<AudioGuideService>();
    _apiKeyController.text = guide.geminiApiKey ?? '';
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final guide = context.read<AudioGuideService>();
    await guide.setGeminiApiKey(_apiKeyController.text.trim());
    setState(() => _saving = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paramètres sauvegardés')),
      );
    }
  }

  Future<void> _clear() async {
    _apiKeyController.clear();
    final guide = context.read<AudioGuideService>();
    await guide.setGeminiApiKey('');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clé API supprimée')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final guide = context.watch<AudioGuideService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Paramètres'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Provider status
          _SectionHeader('Moteur IA actif'),
          const SizedBox(height: 8),
          _ProviderCard(
            icon: Icons.phone_android,
            name: 'Gemini Nano',
            description: 'Traitement local, offline, ~180 mots',
            isActive: guide.activeProvider == AIProvider.geminiNano,
            isAvailable: guide.nanoAvailable,
            onTap: guide.nanoAvailable
                ? () => guide.setActiveProvider(AIProvider.geminiNano)
                : null,
          ),
          const SizedBox(height: 8),
          _ProviderCard(
            icon: Icons.cloud_outlined,
            name: 'Gemini API',
            description: 'Cloud, reconnaît les œuvres, ~400 mots',
            isActive: guide.activeProvider == AIProvider.geminiApi,
            isAvailable: guide.geminiApiKey?.isNotEmpty == true,
            onTap: guide.geminiApiKey?.isNotEmpty == true
                ? () => guide.setActiveProvider(AIProvider.geminiApi)
                : null,
          ),

          const SizedBox(height: 32),

          // Gemini API key
          _SectionHeader('Clé API Gemini'),
          const SizedBox(height: 8),
          Text(
            'Obtenez une clé gratuite sur aistudio.google.com',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyController,
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
                    icon: Icon(_obscure
                        ? Icons.visibility_off
                        : Icons.visibility),
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
                : const Text('Sauvegarder'),
          ),

          const SizedBox(height: 32),

          // Active config section
          _SectionHeader('Configuration active'),
          const SizedBox(height: 8),
          Builder(builder: (context) {
            final cfg = RemoteConfigService.current;
            final loadedAt = RemoteConfigService.loadedAt;
            final fromRemote = RemoteConfigService.loadedFromRemote;
            return Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
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
                      fromRemote ? 'Config chargée depuis GitHub' : 'Config par défaut (hors ligne)',
                      style: TextStyle(
                        color: fromRemote ? Colors.greenAccent : Colors.orange,
                        fontSize: 12,
                      ),
                    ),
                  ]),
                  if (loadedAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Mise à jour : ${DateFormat("dd/MM/yyyy à HH:mm").format(loadedAt)}',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                  const Divider(height: 20, color: Colors.white12),
                  _ConfigRow('Modèle IA', cfg.geminiModel),
                  _ConfigRow('Fallbacks', cfg.geminiModelFallbacks.join(', ')),
                  _ConfigRow('Modèle TTS', cfg.geminiTtsModel),
                  _ConfigRow('Voix TTS', cfg.geminiTtsVoice),
                  _ConfigRow('Tokens max', cfg.geminiMaxTokens.toString()),
                  _ConfigRow('Thinking budget', cfg.geminiThinkingBudget.toString()),
                  _ConfigRow('Rayon Wikipedia', '${cfg.wikipediaRadiusMeters}m'),
                  _ConfigRow('Vitesse TTS', cfg.ttsSpeed.toString()),
                ],
              ),
            );
          }),

          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Rafraîchir la config'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
            ),
            onPressed: () async {
              await RemoteConfigService.forceRefresh();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(
                    RemoteConfigService.loadedFromRemote
                        ? 'Config mise à jour depuis GitHub'
                        : 'Impossible de joindre GitHub, config par défaut',
                  )),
                );
                (context as Element).markNeedsBuild();
              }
            },
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
                  const Icon(Icons.info_outline, size: 16, color: Colors.white54),
                  const SizedBox(width: 8),
                  Text('À propos de Gemini API',
                      style: theme.textTheme.labelMedium),
                ]),
                const SizedBox(height: 8),
                const Text(
                  '• Gratuit : 15 requêtes/min, 1500/jour\n'
                  '• Reconnaît les œuvres d\'art et monuments\n'
                  '• Textes 2× plus longs et précis\n'
                  '• Nécessite une connexion internet\n'
                  '• Clé stockée uniquement sur cet appareil',
                  style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.6),
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
    return Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Colors.white38,
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

  const _ProviderCard({
    required this.icon,
    required this.name,
    required this.description,
    required this.isActive,
    required this.isAvailable,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: isActive
            ? theme.colorScheme.primaryContainer.withOpacity(0.3)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? theme.colorScheme.primary
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: ListTile(
        leading: Icon(
          icon,
          color: isActive
              ? theme.colorScheme.primary
              : isAvailable
                  ? Colors.white70
                  : Colors.white24,
        ),
        title: Text(
          name,
          style: TextStyle(
            color: isAvailable ? Colors.white : Colors.white38,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(
          isAvailable ? description : '$description\n(non configuré)',
          style: TextStyle(
            color: isAvailable ? Colors.white54 : Colors.white24,
            fontSize: 12,
          ),
        ),
        trailing: isActive
            ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
            : isAvailable
                ? const Icon(Icons.radio_button_unchecked, color: Colors.white38)
                : const Icon(Icons.lock_outline, color: Colors.white24),
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
