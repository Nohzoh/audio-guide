import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImageUtils {
  /// Decode image and auto-rotate based on EXIF orientation
  /// Returns corrected bytes, or null on error
  static Future<Uint8List?> autoRotate(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      // img.decodeImage automatically applies EXIF rotation
      return Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
    } catch (_) {
      return null;
    }
  }

  /// Fix rotation of an image file in place
  static Future<void> fixRotation(File file) async {
    final corrected = await autoRotate(file);
    if (corrected != null) {
      await file.writeAsBytes(corrected);
    }
  }
}
