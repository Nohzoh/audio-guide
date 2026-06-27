enum AIMode { cloud, local, hybrid }

enum ModelSize { light, balanced, powerful }

class CloudProvider {
  final String name;
  final String logoAsset;
  final String apiKeyHint;
  String? apiKey;

  CloudProvider({
    required this.name,
    required this.logoAsset,
    required this.apiKeyHint,
    this.apiKey,
  });
}

class LocalModel {
  final String id;
  final String displayName;
  final String description;
  final ModelSize size;
  final int sizeInMb;
  final String downloadUrl;
  final bool isRecommended;
  bool isDownloaded;
  double downloadProgress;

  LocalModel({
    required this.id,
    required this.displayName,
    required this.description,
    required this.size,
    required this.sizeInMb,
    required this.downloadUrl,
    this.isRecommended = false,
    this.isDownloaded = false,
    this.downloadProgress = 0,
  });

  String get sizeLabel {
    if (sizeInMb < 1000) return '${sizeInMb}MB';
    return '${(sizeInMb / 1000).toStringAsFixed(1)}GB';
  }

  String get speedLabel {
    switch (size) {
      case ModelSize.light:
        return 'Très rapide';
      case ModelSize.balanced:
        return 'Rapide';
      case ModelSize.powerful:
        return 'Précis';
    }
  }

  String get batteryLabel {
    switch (size) {
      case ModelSize.light:
        return '🔋';
      case ModelSize.balanced:
        return '🔋🔋';
      case ModelSize.powerful:
        return '🔋🔋🔋';
    }
  }
}

final List<LocalModel> availableModels = [
  LocalModel(
    id: 'gemma-1b',
    displayName: 'Léger',
    description: 'Idéal pour les téléphones récents.\nRapide et économe en batterie.',
    size: ModelSize.light,
    sizeInMb: 600,
    downloadUrl: 'https://example.com/gemma-1b.gguf',
  ),
  LocalModel(
    id: 'gemma-3b',
    displayName: 'Équilibré',
    description: 'Le meilleur rapport qualité/rapidité.\nRecommandé pour la plupart des usages.',
    size: ModelSize.balanced,
    sizeInMb: 1500,
    downloadUrl: 'https://example.com/gemma-3b.gguf',
    isRecommended: true,
  ),
  LocalModel(
    id: 'phi3-mini',
    displayName: 'Puissant',
    description: 'Descriptions les plus détaillées.\nNécessite un téléphone récent avec 4GB+ de RAM.',
    size: ModelSize.powerful,
    sizeInMb: 3000,
    downloadUrl: 'https://example.com/phi3-mini.gguf',
  ),
];

final List<CloudProvider> availableProviders = [
  CloudProvider(
    name: 'Anthropic (Claude)',
    logoAsset: 'assets/images/anthropic.png',
    apiKeyHint: 'sk-ant-...',
  ),
  CloudProvider(
    name: 'Google (Gemini)',
    logoAsset: 'assets/images/google.png',
    apiKeyHint: 'AIza...',
  ),
  CloudProvider(
    name: 'OpenAI (ChatGPT)',
    logoAsset: 'assets/images/openai.png',
    apiKeyHint: 'sk-...',
  ),
];
