import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_settings.dart';

class SettingsService extends ChangeNotifier {
  late SharedPreferences _prefs;

  bool _isOnboardingComplete = false;
  AIMode _aiMode = AIMode.cloud;
  String? _selectedModelId;
  String? _selectedProviderId;
  Map<String, String> _apiKeys = {};

  bool get isOnboardingComplete => _isOnboardingComplete;
  AIMode get aiMode => _aiMode;
  String? get selectedModelId => _selectedModelId;
  Map<String, String> get apiKeys => _apiKeys;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _isOnboardingComplete = _prefs.getBool('onboarding_complete') ?? false;
    _aiMode = AIMode.values[_prefs.getInt('ai_mode') ?? 0];
    _selectedModelId = _prefs.getString('selected_model');
    _selectedProviderId = _prefs.getString('selected_provider');
    final keys = _prefs.getStringList('api_key_names') ?? [];
    for (final key in keys) {
      _apiKeys[key] = _prefs.getString('api_key_$key') ?? '';
    }
  }

  Future<void> completeOnboarding({
    required AIMode mode,
    String? modelId,
    Map<String, String>? apiKeys,
  }) async {
    _aiMode = mode;
    _selectedModelId = modelId;
    if (apiKeys != null) _apiKeys = apiKeys;
    _isOnboardingComplete = true;

    await _prefs.setInt('ai_mode', mode.index);
    await _prefs.setBool('onboarding_complete', true);
    if (modelId != null) await _prefs.setString('selected_model', modelId);
    if (apiKeys != null) {
      await _prefs.setStringList('api_key_names', apiKeys.keys.toList());
      for (final entry in apiKeys.entries) {
        await _prefs.setString('api_key_${entry.key}', entry.value);
      }
    }
    notifyListeners();
  }

  Future<void> resetOnboarding() async {
    await _prefs.clear();
    _isOnboardingComplete = false;
    notifyListeners();
  }
}
