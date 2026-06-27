import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService extends ChangeNotifier {
  late SharedPreferences _prefs;
  bool _isOnboardingComplete = false;
  String _geminiApiKey = '';

  bool get isOnboardingComplete => _isOnboardingComplete;
  String get geminiApiKey => _geminiApiKey;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _isOnboardingComplete = _prefs.getBool('onboarding_complete') ?? false;
    _geminiApiKey = _prefs.getString('gemini_api_key') ?? '';
  }

  Future<void> completeOnboarding({required String apiKey}) async {
    _geminiApiKey = apiKey;
    _isOnboardingComplete = true;
    await _prefs.setString('gemini_api_key', apiKey);
    await _prefs.setBool('onboarding_complete', true);
    notifyListeners();
  }

  Future<void> resetOnboarding() async {
    await _prefs.clear();
    _isOnboardingComplete = false;
    _geminiApiKey = '';
    notifyListeners();
  }
}
