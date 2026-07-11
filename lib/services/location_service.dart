import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class LocationInfo {
  final double latitude;
  final double longitude;
  final String? displayName;
  final String? city;
  final String? country;
  final String? road;
  final String? neighbourhood;

  const LocationInfo({
    required this.latitude,
    required this.longitude,
    this.displayName,
    this.city,
    this.country,
    this.road,
    this.neighbourhood,
  });

  /// Human-readable context string for the AI prompt
  String get contextForPrompt {
    final parts = <String>[];

    if (road != null) parts.add(road!);
    if (neighbourhood != null) parts.add(neighbourhood!);
    if (city != null) parts.add(city!);
    if (country != null) parts.add(country!);

    final locationStr = parts.isNotEmpty ? parts.join(', ') : displayName ?? '';
    return 'Localisation GPS : $latitude, $longitude${locationStr.isNotEmpty ? ' ($locationStr)' : ''}';
  }
}

class LocationService {
  /// Get current position and reverse geocode it via Nominatim
  static Future<LocationInfo?> getCurrentLocation() async {
    try {
      // Check permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return null;
      }
      if (permission == LocationPermission.deniedForever) return null;

      // Get position
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      // Reverse geocode via Nominatim
      final geoInfo = await _reverseGeocode(position.latitude, position.longitude);

      return LocationInfo(
        latitude: position.latitude,
        longitude: position.longitude,
        displayName: geoInfo?['display_name'] as String?,
        city: _extractCity(geoInfo?['address']),
        country: geoInfo?['address']?['country'] as String?,
        road: geoInfo?['address']?['road'] as String?,
        neighbourhood: geoInfo?['address']?['neighbourhood'] as String?
            ?? geoInfo?['address']?['suburb'] as String?,
      );
    } catch (e) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _reverseGeocode(
      double lat, double lon) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?lat=$lat&lon=$lon&format=json&addressdetails=1&accept-language=fr',
      );

      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'AudioLens/1.0 (contact@audiolens.app)',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static String? _extractCity(Map<String, dynamic>? address) {
    if (address == null) return null;
    return address['city'] as String?
        ?? address['town'] as String?
        ?? address['village'] as String?
        ?? address['municipality'] as String?;
  }
}
