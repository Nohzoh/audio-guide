import 'dart:io';
import 'package:exif/exif.dart';

class ExifLocationService {
  static Future<({double lat, double lon})?> readGpsFromImage(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final data = await readExifFromBytes(bytes);

      if (data.isEmpty) return null;

      final latTag = data['GPS GPSLatitude'];
      final lonTag = data['GPS GPSLongitude'];
      final latRef = data['GPS GPSLatitudeRef'];
      final lonRef = data['GPS GPSLongitudeRef'];

      if (latTag == null || lonTag == null) return null;

      final lat = _parseCoordinate(latTag.printable);
      final lon = _parseCoordinate(lonTag.printable);

      if (lat == null || lon == null) return null;

      final latFinal = latRef?.printable == 'S' ? -lat : lat;
      final lonFinal = lonRef?.printable == 'W' ? -lon : lon;

      return (lat: latFinal, lon: lonFinal);
    } catch (_) {
      return null;
    }
  }

  /// Parse GPS coordinate from EXIF printable string
  /// Format: "[52, 21, 5443/100]" or "52/1, 21/1, 5443/100"
  static double? _parseCoordinate(String? printable) {
    if (printable == null) return null;
    try {
      // Remove brackets and split
      final clean = printable.replaceAll('[', '').replaceAll(']', '');
      final parts = clean.split(',').map((s) => s.trim()).toList();
      if (parts.length < 3) return null;

      double parseRatio(String s) {
        if (s.contains('/')) {
          final nums = s.split('/');
          return double.parse(nums[0]) / double.parse(nums[1]);
        }
        return double.parse(s);
      }

      final degrees = parseRatio(parts[0]);
      final minutes = parseRatio(parts[1]);
      final seconds = parseRatio(parts[2]);
      return degrees + minutes / 60.0 + seconds / 3600.0;
    } catch (_) {
      return null;
    }
  }
}
