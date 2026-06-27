import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/app_settings.dart';
import '../services/settings_service.dart';
import '../widgets/mode_card.dart';
import '../widgets/model_picker.dart';
import '../widgets/cloud_provider_picker.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  AIMode? _selectedMode;
  String? _selectedModelId;
  Map<String, String> _apiKeys = {};

  void _nextPage() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
  }

  void _onModeSelected(AIMode mode) {
    setState(() => _selectedMode = mode);
    Future.delayed(const Duration(milliseconds: 200), _nextPage);
  }

  Future<void> _finish() async {
    final settings = context.read<SettingsService>();
    await settings.completeOnboarding(
      mode: _selectedMode!,
      modelId: _selectedModelId,
      apiKeys: _apiKeys.isNotEmpty ? _apiKeys : null,
    );
  }

  List<Widget> get _pages {
    final pages = <Widget>[
      _WelcomePage(onModeSelected: _onModeSelected),
    ];
    if (_selectedMode == AIMode.local || _selectedMode == AIMode.hybrid) {
      pages.add(ModelPickerPage(
        onModelSelected: (id) => setState(() => _selectedModelId = id),
        onNext: _nextPage,
      ));
    }
    if (_selectedMode == AIMode.cloud || _selectedMode == AIMode.hybrid) {
      pages.add(CloudProviderPickerPage(
        onKeysUpdated: (keys) => setState(() => _apiKeys = keys),
        onFinish: _finish,
      ));
    }
    if (_selectedMode == AIMode.local) {
      pages.add(_ReadyPage(onFinish: _finish));
    }
    return pages;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: PageView(
          controller: _pageController,
          physics: const NeverScrollableScrollPhysics(),
          onPageChanged: (i) => setState(() => _currentPage = i),
          children: _pages,
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  final Function(AIMode) onModeSelected;
  const _WelcomePage({required this.onModeSelected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('👋', style: const TextStyle(fontSize: 40))
              .animate().fadeIn().slideY(begin: -0.2),
          const SizedBox(height: 12),
          Text(
            'Bienvenue dans\nAudio Guide',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ).animate(delay: 100.ms).fadeIn().slideY(begin: 0.2),
          const SizedBox(height: 6),
          Text(
            'Prenez une photo d\'un lieu,\nobtenez une explication audio instantanée.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.7),
            ),
          ).animate(delay: 200.ms).fadeIn(),
          const SizedBox(height: 32),
          Text(
            'Comment voulez-vous utiliser l\'app ?',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ).animate(delay: 300.ms).fadeIn(),
          const SizedBox(height: 12),
          ModeCard(
            emoji: '☁️',
            title: 'Utiliser mon compte en ligne',
            subtitle: 'Anthropic, Google ou OpenAI\nMeilleure qualité · nécessite internet',
            onTap: () => onModeSelected(AIMode.cloud),
          ).animate(delay: 400.ms).fadeIn().slideX(begin: 0.1),
          const SizedBox(height: 10),
          ModeCard(
            emoji: '📱',
            title: 'Tout sur mon téléphone',
            subtitle: 'Fonctionne sans internet\nTéléchargement initial requis',
            onTap: () => onModeSelected(AIMode.local),
          ).animate(delay: 500.ms).fadeIn().slideX(begin: 0.1),
          const SizedBox(height: 10),
          ModeCard(
            emoji: '⚡',
            title: 'Les deux (recommandé)',
            subtitle: 'En ligne si disponible,\nhors-ligne sinon',
            isRecommended: true,
            onTap: () => onModeSelected(AIMode.hybrid),
          ).animate(delay: 600.ms).fadeIn().slideX(begin: 0.1),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _ReadyPage extends StatelessWidget {
  final VoidCallback onFinish;
  const _ReadyPage({required this.onFinish});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🎉', style: TextStyle(fontSize: 72)),
          const SizedBox(height: 24),
          Text(
            'Tout est prêt !',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Votre modèle sera téléchargé\nau premier lancement.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withOpacity(0.7),
            ),
          ),
          const SizedBox(height: 48),
          FilledButton(
            onPressed: onFinish,
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 56),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            child: const Text('Commencer', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }
}
