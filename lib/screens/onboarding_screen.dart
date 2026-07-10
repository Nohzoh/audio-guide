import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/settings_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final key = _controller.text.trim();
    if (key.isEmpty) {
      setState(() => _error = 'Entrez votre clé API');
      return;
    }
    setState(() { _loading = true; _error = null; });
    await context.read<SettingsService>().completeOnboarding(apiKey: key);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              Text('🎧', style: const TextStyle(fontSize: 48))
                  .animate().fadeIn().slideY(begin: -0.2),
              const SizedBox(height: 16),
              Text('AudioLens',
                style: theme.textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold),
              ).animate(delay: 100.ms).fadeIn(),
              const SizedBox(height: 8),
              Text(
                'Prenez une photo d\'un lieu,\nobtenez une explication audio instantanée.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ).animate(delay: 200.ms).fadeIn(),
              const SizedBox(height: 48),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Text('🔑', style: TextStyle(fontSize: 20)),
                      const SizedBox(width: 8),
                      Text('Clé API Anthropic',
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Text(
                      'Obtenez votre clé sur console.anthropic.com\nRubrique "API Keys"',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ).animate(delay: 300.ms).fadeIn(),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: 'sk-ant-...',
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  errorText: _error,
                  suffixIcon: const Icon(Icons.visibility_off, size: 18),
                ),
                onChanged: (_) => setState(() => _error = null),
              ).animate(delay: 400.ms).fadeIn(),
              const SizedBox(height: 32),
              FilledButton(
                onPressed: _loading ? null : _finish,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                child: _loading
                    ? const SizedBox(width: 24, height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('C\'est parti !', style: TextStyle(fontSize: 18)),
              ).animate(delay: 500.ms).fadeIn(),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  '🔒 Clé stockée uniquement sur votre téléphone',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.4),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
