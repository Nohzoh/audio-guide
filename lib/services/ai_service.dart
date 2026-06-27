import 'dart:io';

/// Résultat d'une analyse d'image
class AudioGuideResult {
  final String title;
  final String script;
  final String? locationName;

  const AudioGuideResult({
    required this.title,
    required this.script,
    this.locationName,
  });
}

/// Interface abstraite — tous les providers l'implémentent
abstract class AIService {
  /// Nom affiché à l'utilisateur
  String get displayName;

  /// Est-ce que ce service est disponible sur cet appareil ?
  Future<bool> isAvailable();

  /// Initialisation (chargement du modèle, etc.)
  Future<void> initialize();

  /// Analyse une image et retourne un script audio
  Future<AudioGuideResult> analyzeImage(File imageFile);

  /// Libère les ressources
  void dispose();
}
