import 'dart:io';
import 'package:exif/exif.dart';

class ImageUtils {
  /// Returns quarter-turn rotation needed to display image upright
  /// based on EXIF orientation tag. Does NOT modify the file.
  static Future<int> getRotationQuarterTurns(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final data = await readExifFromBytes(bytes);
      final orientation = data['Image Orientation'];
      if (orientation == null) return 0;
      final value = orientation.printable;
      if (value.contains('Rotated 90 CW')) return 3;
      if (value.contains('Rotated 180')) return 2;
      if (value.contains('Rotated 270') || value.contains('Rotated 90 CCW')) return 1;
      if (value.contains('90')) return 3;
      if (value.contains('180')) return 2;
      if (value.contains('270')) return 1;
    } catch (_) {}
    return 0;
  }
}
