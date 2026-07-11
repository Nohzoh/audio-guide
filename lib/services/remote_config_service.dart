import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class RemoteConfig {
  // Gemini API
  final String geminiModel;
  final String geminiApiUrl;
  final int geminiMaxTokens;
  final double geminiTemperature;

  // Gemini Nano
  final int geminiNanoMaxTokens;
  final int geminiNanoCascadeSegments;

  // Wikipedia
  final int wikipediaRadiusMeters;
  final int wikipediaMaxResults;
  final int wikipediaExtractChars;

  // TTS
  final double ttsSpeed;
  final int ttsSid;
  final int ttsNumThreads;

  // Location
  final int locationTimeoutSeconds;

  // Image
  final int imageMaxWidth;
  final int imageQuality;

  // App
  final int timingHistorySize;
  final int progressSimulationIntervalMs;

  const RemoteConfig({
    this.geminiModel = 'gemini-2.0-flash',
    this.geminiApiUrl = 'https://generativelanguage.googleapis.com/v1beta',
    this.geminiMaxTokens = 1024,
    this.geminiTemperature = 0.7,
    this.geminiNanoMaxTokens = 256,
    this.geminiNanoCascadeSegments = 3,
    this.wikipediaRadiusMeters = 200,
    this.wikipediaMaxResults = 3,
    this.wikipediaExtractChars = 1500,
    this.ttsSpeed = 1.2,
    this.ttsSid = 0,
    this.ttsNumThreads = 2,
    this.locationTimeoutSeconds = 10,
    this.imageMaxWidth = 1280,
    this.imageQuality = 85,
    this.timingHistorySize = 5,
    this.progressSimulationIntervalMs = 150,
  });

  factory RemoteConfig.fromJson(Map<String, dynamic> json) {
    return RemoteConfig(
      geminiModel: json['gemini_model'] as String? ?? 'gemini-2.0-flash-latest',
      geminiApiUrl: json['gemini_api_url'] as String?
          ?? 'https://generativelanguage.googleapis.com/v1beta',
      geminiMaxTokens: json['gemini_max_tokens'] as int? ?? 1024,
      geminiTemperature: (json['gemini_temperature'] as num?)?.toDouble() ?? 0.7,
      geminiNanoMaxTokens: json['gemini_nano_max_tokens'] as int? ?? 256,
      geminiNanoCascadeSegments: json['gemini_nano_cascade_segments'] as int? ?? 3,
      wikipediaRadiusMeters: json['wikipedia_radius_meters'] as int? ?? 200,
      wikipediaMaxResults: json['wikipedia_max_results'] as int? ?? 3,
      wikipediaExtractChars: json['wikipedia_extract_chars'] as int? ?? 1500,
      ttsSpeed: (json['tts_speed'] as num?)?.toDouble() ?? 1.2,
      ttsSid: json['tts_sid'] as int? ?? 0,
      ttsNumThreads: json['tts_num_threads'] as int? ?? 2,
      locationTimeoutSeconds: json['location_timeout_seconds'] as int? ?? 10,
      imageMaxWidth: json['image_max_width'] as int? ?? 1280,
      imageQuality: json['image_quality'] as int? ?? 85,
      timingHistorySize: json['timing_history_size'] as int? ?? 5,
      progressSimulationIntervalMs:
          json['progress_simulation_interval_ms'] as int? ?? 150,
    );
  }

  Map<String, dynamic> toJson() => {
    'gemini_model': geminiModel,
    'gemini_api_url': geminiApiUrl,
    'gemini_max_tokens': geminiMaxTokens,
    'gemini_temperature': geminiTemperature,
    'gemini_nano_max_tokens': geminiNanoMaxTokens,
    'gemini_nano_cascade_segments': geminiNanoCascadeSegments,
    'wikipedia_radius_meters': wikipediaRadiusMeters,
    'wikipedia_max_results': wikipediaMaxResults,
    'wikipedia_extract_chars': wikipediaExtractChars,
    'tts_speed': ttsSpeed,
    'tts_sid': ttsSid,
    'tts_num_threads': ttsNumThreads,
    'location_timeout_seconds': locationTimeoutSeconds,
    'image_max_width': imageMaxWidth,
    'image_quality': imageQuality,
    'timing_history_size': timingHistorySize,
    'progress_simulation_interval_ms': progressSimulationIntervalMs,
  };
}

class RemoteConfigService {
  static const _configUrl =
      'https://raw.githubusercontent.com/Nohzoh/audio-guide/main/config.json';
  static const _cacheKey = 'remote_config_cache';
  static const _cacheAgeKey = 'remote_config_cache_age';
  static const _cacheTtlHours = 6;

  static RemoteConfig _current = const RemoteConfig();
  static RemoteConfig get current => _current;

  /// Load config: try remote first, fall back to cache, then defaults.
  static Future<void> load() async {
    // Try remote
    try {
      final response = await http.get(Uri.parse(_configUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        _current = RemoteConfig.fromJson(json);
        // Cache it
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, response.body);
        await prefs.setInt(
            _cacheAgeKey, DateTime.now().millisecondsSinceEpoch);
        return;
      }
    } catch (_) {}

    // Fall back to cache
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null) {
        final json = jsonDecode(cached) as Map<String, dynamic>;
        _current = RemoteConfig.fromJson(json);
        return;
      }
    } catch (_) {}

    // Fall back to defaults (already set)
  }
}
