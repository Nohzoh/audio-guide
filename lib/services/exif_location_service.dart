import 'dart:io';
import 'package:exif/exif.dart';

class ExifLocationService {
  /// Read GPS coordinates from image EXIF metadata
  /// Returns null if no GPS data found
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

      final lat = _parseGpsCoordinate(latTag.values);
      final lon = _parseGpsCoordinate(lonTag.values);

      if (lat == null || lon == null) return null;

      final latFinal = latRef?.printable == 'S' ? -lat : lat;
      final lonFinal = lonRef?.printable == 'W' ? -lon : lon;

      return (lat: latFinal, lon: lonFinal);
    } catch (_) {
      return null;
    }
  }

  static double? _parseGpsCoordinate(dynamic values) {
    try {
      // EXIF GPS is stored as [degrees, minutes, seconds] as ratios
      final list = values as IfdValues;
      if (list.length < 3) return null;

      double parse(dynamic v) {
        if (v is IfdRatioValue) return v.numerator / v.denominator;
        return (v as num).toDouble();
      }

      final degrees = parse(list.toList()[0]);
      final minutes = parse(list.toList()[1]);
      final seconds = parse(list.toList()[2]);

      return degrees + minutes / 60.0 + seconds / 3600.0;
    } catch (_) {
      return null;
    }
  }
}
