import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

enum LocationPermissionStatus {
  granted,
  denied,
  deniedForever,
  serviceDisabled,
}

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

  String get contextForPrompt {
    final parts = <String>[];
    if (road != null) parts.add(road!);
    if (neighbourhood != null) parts.add(neighbourhood!);
    if (city != null) parts.add(city!);
    if (country != null) parts.add(country!);
    final locationStr =
        parts.isNotEmpty ? parts.join(', ') : displayName ?? '';
    return 'Localisation GPS : $latitude, $longitude'
        '${locationStr.isNotEmpty ? ' ($locationStr)' : ''}';
  }
}

class LocationResult {
  final LocationInfo? info;
  final LocationPermissionStatus status;

  const LocationResult({this.info, required this.status});
}

class LocationService {
  /// Check permission status without requesting
  static Future<LocationPermissionStatus> checkPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return LocationPermissionStatus.serviceDisabled;

    final permission = await Geolocator.checkPermission();
    return _mapPermission(permission);
  }

  /// Request permission and get location
  static Future<LocationResult> getCurrentLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return const LocationResult(status: LocationPermissionStatus.serviceDisabled);
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      return const LocationResult(status: LocationPermissionStatus.deniedForever);
    }

    if (permission == LocationPermission.denied) {
      return const LocationResult(status: LocationPermissionStatus.denied);
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      final geoInfo =
          await _reverseGeocode(position.latitude, position.longitude);

      return LocationResult(
        status: LocationPermissionStatus.granted,
        info: LocationInfo(
          latitude: position.latitude,
          longitude: position.longitude,
          displayName: geoInfo?['display_name'] as String?,
          city: _extractCity(geoInfo?['address']),
          country: geoInfo?['address']?['country'] as String?,
          road: geoInfo?['address']?['road'] as String?,
          neighbourhood: geoInfo?['address']?['neighbourhood'] as String? ??
              geoInfo?['address']?['suburb'] as String?,
        ),
      );
    } catch (_) {
      return const LocationResult(status: LocationPermissionStatus.granted);
    }
  }

  /// Open app settings so user can grant permission
  static Future<void> openSettings() async {
    await Geolocator.openAppSettings();
  }

  static LocationPermissionStatus _mapPermission(LocationPermission p) {
    switch (p) {
      case LocationPermission.denied:
        return LocationPermissionStatus.denied;
      case LocationPermission.deniedForever:
        return LocationPermissionStatus.deniedForever;
      default:
        return LocationPermissionStatus.granted;
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
        headers: {'User-Agent': 'AudioLens/1.0'},
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  static String? _extractCity(Map<String, dynamic>? address) {
    if (address == null) return null;
    return address['city'] as String? ??
        address['town'] as String? ??
        address['village'] as String? ??
        address['municipality'] as String?;
  }
}
