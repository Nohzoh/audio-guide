import 'dart:convert';
import 'package:http/http.dart' as http;

class WikipediaResult {
  final String title;
  final String extract;
  final String? coordinates;

  const WikipediaResult({
    required this.title,
    required this.extract,
    this.coordinates,
  });
}

class WikipediaService {
  /// Search Wikipedia articles near GPS coordinates
  static Future<List<WikipediaResult>> searchNearby({
    required double lat,
    required double lon,
    int radius = 200, // meters
    int limit = 3,
  }) async {
    try {
      // GeoSearch: find articles near coordinates
      final geoUri = Uri.parse(
        'https://fr.wikipedia.org/w/api.php'
        '?action=query'
        '&list=geosearch'
        '&gscoord=$lat|$lon'
        '&gsradius=$radius'
        '&gslimit=$limit'
        '&format=json'
        '&origin=*'
      );

      final geoResp = await http.get(geoUri,
        headers: {'User-Agent': 'AudioLens/1.0'})
          .timeout(const Duration(seconds: 6));

      if (geoResp.statusCode != 200) return [];

      final geoData = jsonDecode(geoResp.body) as Map<String, dynamic>;
      final pages = geoData['query']?['geosearch'] as List? ?? [];

      if (pages.isEmpty) return [];

      // Get extracts for found pages
      final pageIds = pages.map((p) => p['pageid'].toString()).join('|');

      final extractUri = Uri.parse(
        'https://fr.wikipedia.org/w/api.php'
        '?action=query'
        '&pageids=$pageIds'
        '&prop=extracts'
        '&exintro=true'
        '&explaintext=true'
        '&exsectionformat=plain'
        '&exchars=1500'
        '&format=json'
        '&origin=*'
      );

      final extractResp = await http.get(extractUri,
        headers: {'User-Agent': 'AudioLens/1.0'})
          .timeout(const Duration(seconds: 6));

      if (extractResp.statusCode != 200) return [];

      final extractData = jsonDecode(extractResp.body) as Map<String, dynamic>;
      final queryPages = extractData['query']?['pages'] as Map? ?? {};

      return queryPages.values.map((page) {
        final extract = (page['extract'] as String? ?? '').trim();
        // Clean up the extract
        final cleaned = extract
            .replaceAll(RegExp(r'\n+'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        return WikipediaResult(
          title: page['title'] as String? ?? '',
          extract: cleaned.length > 1200
              ? '${cleaned.substring(0, 1200)}...'
              : cleaned,
        );
      }).where((r) => r.extract.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  /// Build context string for AI prompt
  static String buildContext(List<WikipediaResult> results) {
    if (results.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('Informations factuelles sur les lieux à proximité (source Wikipedia) :');
    for (final r in results) {
      buffer.writeln('- ${r.title} : ${r.extract}');
    }
    return buffer.toString();
  }
}
