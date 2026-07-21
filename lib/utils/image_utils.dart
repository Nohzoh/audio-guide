import 'dart:io';
import 'dart:typed_data';
import 'package:exif/exif.dart';
import 'package:image/image.dart' as img;

class ImageUtils {
  /// Returns quarter-turn rotation needed to display image upright
  /// based on EXIF orientation tag
  static Future<int> getRotationQuarterTurns(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final data = await readExifFromBytes(bytes);
      final orientation = data['Image Orientation'];
      if (orientation == null) return 0;
      final value = orientation.printable;
      // EXIF orientation values
      if (value.contains('Rotated 90 CW') || value.contains('90')) return 3;
      if (value.contains('Rotated 180') || value.contains('180')) return 2;
      if (value.contains('Rotated 270') || value.contains('270')) return 1;
    } catch (_) {}
    return 0;
  }

  /// Fix rotation of an image file in place
  static Future<void> fixRotation(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      // img.decodeImage automatically applies EXIF rotation
      final corrected = img.encodeJpg(decoded, quality: 90);
      await file.writeAsBytes(corrected);
    } catch (_) {}
  }
}
