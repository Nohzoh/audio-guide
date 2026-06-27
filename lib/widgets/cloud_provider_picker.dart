import 'package:flutter/material.dart';
import '../models/app_settings.dart';

class CloudProviderPickerPage extends StatefulWidget {
  final Function(Map<String, String>) onKeysUpdated;
  final VoidCallback onFinish;
  const CloudProviderPickerPage({super.key, required this.onKeysUpdated, required this.onFinish});

  @override
  State<CloudProviderPickerPage> createState() => _CloudProviderPickerPageState();
}

class _CloudProviderPickerPageState extends State<CloudProviderPickerPage> {
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    for (final p in availableProviders) {
      _controllers[p.name] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) c.dispose();
    super.dispose();
  }

  bool get _hasAtLeastOneKey =>
      _controllers.values.any((c) => c.text.trim().isNotEmpty);

  void _finish() {
    final keys = <String, String>{};
    for (final p in availableProviders) {
      final val = _controllers[p.name]?.text.trim() ?? '';
      if (val.isNotEmpty) keys[p.name] = val;
    }
    widget.onKeysUpdated(keys);
    widget.onFinish();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          Text('🔑', style: const TextStyle(fontSize: 48)),
          const SizedBox(height: 16),
          Text(
            'Vos clés API',
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Entrez au moins une clé. Elles sont stockées uniquement sur votre téléphone.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.6),
            ),
          ),
          const SizedBox(height: 32),
          ...availableProviders.map((provider) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(provider.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: _controllers[provider.name],
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: provider.apiKeyHint,
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHigh,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: const Icon(Icons.visibility_off, size: 18),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          )),
          const Spacer(),
          FilledButton(
            onPressed: _hasAtLeastOneKey ? _finish : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text('C\'est parti !', style: TextStyle(fontSize: 18)),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
