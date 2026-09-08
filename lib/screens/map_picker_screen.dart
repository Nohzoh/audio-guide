import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../l10n/app_localizations.dart';
import '../services/location_service.dart';

/// Lets the user tap a spot on a map to indicate where a photo was taken
/// (T87) — used when a gallery-picked photo has no GPS in its EXIF, where
/// falling back to the device's current position would be misleading (the
/// photo could be old, or from anywhere).
///
/// Returns the picked [LatLng], or null if the user backed out without
/// picking a spot.
class MapPickerScreen extends StatefulWidget {
  const MapPickerScreen({super.key});

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  static const _defaultCenter = LatLng(48.8566, 2.3522); // Paris fallback

  final _mapController = MapController();
  final _searchController = TextEditingController();
  LatLng? _picked;
  List<GeocodePrediction> _searchResults = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    // Best-effort: center on the device's current position if available,
    // purely as a convenient starting point — never used as the actual
    // answer, unlike the realtime-GPS fallback this screen replaces.
    LocationService.getCurrentLocation().then((result) {
      final info = result.info;
      if (info != null && mounted) {
        _mapController.move(LatLng(info.latitude, info.longitude), 13);
      }
    });
    // Drives the search field's "clear" suffix icon, which only makes sense
    // to show once there's text to clear.
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _searching = true);
    final results = await LocationService.searchPlace(query);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _searchResults = results;
    });
  }

  /// #201: a fixed zoom level didn't fit every result — a precise
  /// address ended up too zoomed out, while a city/region result could
  /// end up zoomed in past what it actually needs. Nominatim's own
  /// `boundingbox` sizes itself to the kind of place matched, so fitting
  /// the camera to it gets the right zoom for free. Falls back to the
  /// old fixed-zoom jump on the rare result with no usable bounding box.
  static const double _maxSearchZoom = 18;

  void _selectPrediction(GeocodePrediction prediction) {
    if (prediction.hasBoundingBox) {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds(
            LatLng(prediction.south!, prediction.west!),
            LatLng(prediction.north!, prediction.east!),
          ),
          maxZoom: _maxSearchZoom,
          padding: const EdgeInsets.all(32),
        ),
      );
    } else {
      _mapController.move(LatLng(prediction.lat, prediction.lon), 15);
    }
    FocusScope.of(context).unfocus();
    setState(() => _searchResults = []);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        // #367: the default single-line AppBar title truncated this
        // (comparatively long) string next to the "Skip" action button —
        // FittedBox scales it down to whatever width is actually left
        // instead of a fixed font size, so it stays correct across
        // locales (French runs longer) and accessibility text scaling.
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(l10n.mapPickerTitle, maxLines: 1),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.mapPickerSkip),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _defaultCenter,
              initialZoom: 5,
              // #123: locked north-up — the two-finger rotate gesture made
              // it easy to accidentally tilt the map while panning/zooming
              // to pick a precise spot, which is disorienting since there's
              // no compass/heading indicator to make sense of the tilt.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onTap: (_, point) => setState(() => _picked = point),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'io.nohzoh.audiolens',
              ),
              if (_picked != null)
                MarkerLayer(markers: [
                  Marker(
                    point: _picked!,
                    width: 40,
                    height: 40,
                    child: const Icon(Icons.location_pin,
                        color: Colors.red, size: 40),
                  ),
                ]),
              // #126: OSM tile usage policy requires visible attribution —
              // was missing entirely (a pre-existing gap, found while
              // adding a second FlutterMap surface — see widgets/mini_map.dart).
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
          Positioned(
            left: 16,
            right: 16,
            top: 16,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(28),
                    child: TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: l10n.mapPickerSearchHint,
                        prefixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : const Icon(Icons.search),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchResults = []);
                                },
                              ),
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(28),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: _runSearch,
                    ),
                  ),
                  if (_searchResults.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      constraints: const BoxConstraints(maxHeight: 200),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(blurRadius: 4, color: Colors.black26)
                        ],
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _searchResults.length,
                        itemBuilder: (context, index) {
                          final prediction = _searchResults[index];
                          return ListTile(
                            leading: const Icon(Icons.place_outlined),
                            title: Text(
                              prediction.displayName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _selectPrediction(prediction),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              child: FilledButton(
                onPressed: _picked == null
                    ? null
                    : () => Navigator.pop(context, _picked),
                child: Text(_picked == null
                    ? l10n.mapPickerHint
                    : l10n.mapPickerConfirm),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
