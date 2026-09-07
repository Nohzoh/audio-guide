import 'dart:io';
import 'package:http/http.dart' as http;
import 'exif_location_service.dart';
import 'location_service.dart';
import 'poi_service.dart';
import 'remote_config_service.dart';
import 'wikidata_service.dart';
import 'wikipedia_service.dart';

/// Result of resolving where a photo was taken and enriching it with
/// nearby Wikipedia context.
class LocationContext {
  const LocationContext({
    required this.source,
    required this.status,
    this.latitude,
    this.longitude,
    this.address,
    this.city,
    this.poi,
    this.wikidataInfo,
    this.wikipediaResults = const [],
    this.wikipediaUsed = false,
    this.promptContext,
  });

  /// 'exif' | 'realtime' | 'map' (T87 — picked on a map, gallery photos
  /// with no EXIF GPS) | 'none'
  final String source;
  final LocationPermissionStatus status;
  final double? latitude;
  final double? longitude;
  final String? address;
  final String? city;

  /// Closest tagged point of interest (business, venue, landmark,
  /// memorial...) found nearby (T74), with whatever structured metadata
  /// OSM carries for it (#276) — not just a name.
  final PoiInfo? poi;

  /// Name of the closest tagged POI, if one was found — convenience for
  /// callers that only need the name, not the full [PoiInfo].
  String? get poiName => poi?.name;

  /// Label/description fetched from Wikidata (#276) when [poi] carries a
  /// `wikidata` tag — fills the gap for POIs with no Wikipedia article
  /// (common for small/local memorials) but a structured Wikidata entry.
  final WikidataInfo? wikidataInfo;

  /// The individual Wikipedia articles found (geosearch + name search,
  /// merged and deduped) — exposed alongside the combined [promptContext]
  /// so a caller (e.g. a debug trace view) can show what was actually
  /// found article by article, not just the final merged text.
  final List<WikipediaResult> wikipediaResults;
  final bool wikipediaUsed;

  /// Combined location + Wikipedia text to feed the AI prompt, or null.
  final String? promptContext;
}

/// Resolves a location context — either from a photo (EXIF GPS first, then
/// real-time GPS) or from already-known coordinates — and enriches it with
/// a nearby point of interest and Wikipedia articles.
///
/// T06 — extracted from AudioGuideService.analyzeAndPlay.
/// T74 — added POI lookup + name-based Wikipedia search.
/// T78 — split GPS resolution from enrichment (POI/Wikipedia/reverse
/// geocoding) so a deferred capture can supply coordinates already known
/// from capture time, without repeating the GPS step.
/// #276 — POI lookup now surfaces structured OSM metadata (category,
/// subtype, inscription, Wikidata link) instead of just a bare name, and
/// a Wikidata description is fetched when available.
class LocationContextResolver {
  LocationContextResolver({PoiService? poiService, http.Client? httpClient})
      : _poiService = poiService ?? PoiService(client: httpClient),
        _httpClient = httpClient;

  final PoiService _poiService;
  final http.Client? _httpClient;

  /// #137: repeat visits to the same coordinates (retrying an analysis,
  /// revisiting the same room) used to re-fetch POI/Wikidata/Wikipedia
  /// from scratch every time. In-memory only (lives as long as this
  /// resolver — one instance per app session, see AudioGuideService's
  /// constructor) and keyed on lat/lon rounded to 4 decimal places
  /// (~11m) — good enough for "the same place", not meant to be exact.
  /// Capped with a TTL so a POI's tags or a Wikipedia article changing
  /// doesn't stay stale for the rest of the session.
  static const _cacheTtl = Duration(hours: 24);
  final _enrichmentCache = <String, _CachedEnrichment>{};

  Future<LocationContext> resolve(File imageFile) async {
    final exifCoords = await ExifLocationService.readGpsFromImage(imageFile);
    LocationResult locationResult;
    String source;
    if (exifCoords != null) {
      locationResult = await LocationService.fromCoordinates(exifCoords.lat, exifCoords.lon, client: _httpClient);
      source = 'exif';
    } else {
      locationResult = await LocationService.getCurrentLocation(client: _httpClient);
      source = locationResult.status == LocationPermissionStatus.granted ? 'realtime' : 'none';
    }
    return _enrich(locationResult, source);
  }

  /// Resolves from coordinates already known (e.g. saved at capture time by
  /// a deferred/offline capture) instead of reading them from a photo.
  /// Reverse geocoding, POI lookup, and Wikipedia enrichment all happen
  /// now, at call time — this is the network-heavy part T78's deferred
  /// capture defers until the user explicitly launches the analysis.
  Future<LocationContext> resolveFromCoordinates({
    required double lat,
    required double lon,
    required String source,
  }) async {
    final locationResult = await LocationService.fromCoordinates(lat, lon, client: _httpClient);
    return _enrich(locationResult, source);
  }

  Future<LocationContext> _enrich(LocationResult locationResult, String source) async {
    var latitude = locationResult.info?.latitude;
    var longitude = locationResult.info?.longitude;
    var address = locationResult.info?.contextForPrompt;
    if (locationResult.info == null || locationResult.status != LocationPermissionStatus.granted) {
      latitude = null;
      longitude = null;
      address = null;
      source = 'none';
    }

    final cfg = RemoteConfigService.current;

    PoiInfo? poi;
    WikidataInfo? wikidataInfo;
    String? wikiContext;
    var wikiResults = <WikipediaResult>[];
    var wikipediaUsed = false;
    if (locationResult.info != null) {
      final lat = locationResult.info!.latitude;
      final lon = locationResult.info!.longitude;
      final cacheKey = '${lat.toStringAsFixed(4)},${lon.toStringAsFixed(4)}';
      final cached = _enrichmentCache[cacheKey];

      if (cached != null && DateTime.now().difference(cached.fetchedAt) < _cacheTtl) {
        poi = cached.poi;
        wikidataInfo = cached.wikidataInfo;
        wikiResults = cached.wikiResults;
      } else {
        // #137: POI lookup and the Wikipedia geosearch only need lat/lon
        // — neither depends on the other's result — so both are kicked
        // off together instead of waiting on each other. Wikidata and
        // the name-matched Wikipedia search *do* depend on the POI (its
        // wikidataId / name), so they can only start once it resolves,
        // but they're independent of *each other* and of the geosearch
        // still in flight, so they're kicked off together too.
        final poiFuture = _poiService.findNearby(
          lat: lat,
          lon: lon,
          radius: cfg.poiRadiusMeters,
          timeoutSeconds: cfg.poiTimeoutSeconds,
          maxAttempts: cfg.poiMaxAttempts,
        );
        final wikiNearbyFuture = WikipediaService.searchNearby(
          lat: lat,
          lon: lon,
          radius: cfg.wikipediaRadiusMeters,
          limit: cfg.wikipediaMaxResults,
          extractChars: cfg.wikipediaExtractChars,
          client: _httpClient,
        );

        poi = await poiFuture;
        // Captured into a local so the null-checks below promote reliably
        // — `poi` itself is a mutable outer variable, reassigned above
        // across an `await`, which the analyzer won't promote through.
        final resolvedPoi = poi;

        final wikidataFuture = resolvedPoi?.wikidataId != null
            ? WikidataService.fetchInfo(resolvedPoi!.wikidataId!, client: _httpClient)
            : Future<WikidataInfo?>.value(null);
        final nameQuery = resolvedPoi != null
            ? [resolvedPoi.name, locationResult.info!.city].where((s) => s != null && s.isNotEmpty).join(' ')
            : null;
        final wikiNameFuture = nameQuery != null
            ? WikipediaService.searchByName(
                query: nameQuery,
                limit: cfg.wikipediaMaxResults,
                extractChars: cfg.wikipediaExtractChars,
                client: _httpClient,
              )
            : Future<List<WikipediaResult>>.value(const []);

        wikiResults = await wikiNearbyFuture;
        wikidataInfo = await wikidataFuture;
        final nameResults = await wikiNameFuture;

        if (poi != null) {
          // #247: name-matched results first, not appended after the
          // generic-proximity ones — searchNearby's geosearch ranks purely
          // by distance, which can put a broader article (e.g. the
          // surrounding town) ahead of the specific place actually being
          // photographed if the town's own Wikipedia geotag happens to sit
          // just as close. A downstream character budget (Nano's prompt,
          // GeminiNanoService._maxLocationContextChars) can then truncate
          // away the more relevant, name-matched extract entirely — this
          // ordering makes sure it isn't the one paying that cost.
          wikiResults = WikipediaService.merge(nameResults, wikiResults);
        }

        _enrichmentCache[cacheKey] = _CachedEnrichment(
          fetchedAt: DateTime.now(),
          poi: poi,
          wikidataInfo: wikidataInfo,
          wikiResults: wikiResults,
        );
      }

      if (wikiResults.isNotEmpty) {
        wikiContext = WikipediaService.buildContext(wikiResults);
        wikipediaUsed = true;
      }
    }

    final promptContext = [
      poi != null ? 'Lieu identifié à proximité : ${_poiLine(poi)}' : null,
      wikidataInfo != null ? 'Selon Wikidata : ${wikidataInfo.summary}' : null,
      locationResult.info?.contextForPrompt,
      wikiContext,
    ].where((s) => s != null && s.isNotEmpty).join('\n\n');

    return LocationContext(
      source: source,
      status: locationResult.status,
      latitude: latitude,
      longitude: longitude,
      address: address,
      city: locationResult.info?.city,
      poi: poi,
      wikidataInfo: wikidataInfo,
      wikipediaResults: wikiResults,
      wikipediaUsed: wikipediaUsed,
      promptContext: promptContext.isNotEmpty ? promptContext : null,
    );
  }

  /// #276: folds [PoiInfo.subtype] and [PoiInfo.inscription] into the
  /// same "Lieu identifié" line the prompt already had a slot for,
  /// rather than adding new top-level promptContext sections per field
  /// — keeps the addition proportional (most POIs still have neither).
  static String _poiLine(PoiInfo poi) {
    final parts = <String>[poi.name];
    if (poi.subtype != null && poi.subtype!.isNotEmpty) {
      parts.add('(${poi.subtype})');
    }
    var line = parts.join(' ');
    if (poi.inscription != null && poi.inscription!.isNotEmpty) {
      line += '. Inscription : "${poi.inscription}"';
    }
    return line;
  }
}

/// #137: a past enrichment result, cached by coordinates.
class _CachedEnrichment {
  const _CachedEnrichment({
    required this.fetchedAt,
    required this.poi,
    required this.wikidataInfo,
    required this.wikiResults,
  });

  final DateTime fetchedAt;
  final PoiInfo? poi;
  final WikidataInfo? wikidataInfo;
  final List<WikipediaResult> wikiResults;
}
