import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:gal/gal.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/audio_guide_service.dart';
import '../services/settings_service.dart';
import '../services/history_service.dart';
import '../services/location_service.dart';
import 'player_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  LocationPermissionStatus _permissionStatus = LocationPermissionStatus.granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLocationPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check permission when user comes back from settings
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkLocationPermission();
    }
  }

  Future<void> _checkLocationPermission() async {
    final status = await LocationService.checkPermission();
    if (mounted) setState(() => _permissionStatus = status);
  }

  Future<void> _pickImage(ImageSource source) async {
    final guide = context.read<AudioGuideService>();
    final history = context.read<HistoryService>();

    final picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1280,
    );
    if (xFile == null || !mounted) return;

    final imageFile = File(xFile.path);

    Navigator.push(context, MaterialPageRoute(
      builder: (_) => PlayerScreen(imageFile: imageFile),
    ));

    final result = await guide.analyzeAndPlay(imageFile);

    // Update permission status after analysis
    setState(() => _permissionStatus = guide.lastLocationStatus);

    if (result != null) {
      final entry = await history.addEntry(
        imagePath: imageFile.path,
        title: result.title,
        script: result.script,
        locationName: result.locationName,
      );
      // Save generated audio so replay doesn't regenerate
      final audioPath = guide.lastAudioPath;
      if (audioPath != null && entry.id != null) {
        await history.saveAudioPath(entry.id!, audioPath);
      }
    }
  }

  void _showLocationDeniedForeverDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Géolocalisation désactivée'),
        content: const Text(
          'La géolocalisation améliore la précision des descriptions.\n\n'
          'Pour l\'activer, allez dans les paramètres de l\'application.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Plus tard'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              LocationService.openSettings();
            },
            child: const Text('Ouvrir les paramètres'),
          ),
        ],
      ),
    );
  }

  Future<void> _showImageSourceDialog() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.white24,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choisir depuis la galerie'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (source != null) _pickImage(source);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surface,
              theme.colorScheme.surfaceContainerHigh,
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text('🎧 AudioLens',
                      style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.history),
                      onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const HistoryScreen()),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const SettingsScreen()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Provider + location status row
                Row(
                  children: [
                    Consumer<AudioGuideService>(
                      builder: (context, guide, _) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer
                              .withOpacity(0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              guide.providerName.contains('Nano')
                                  ? Icons.phone_android
                                  : Icons.cloud_outlined,
                              size: 14,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              guide.providerName.isEmpty
                                  ? 'Initialisation...'
                                  : guide.providerName,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Location status badge
                    if (_permissionStatus ==
                        LocationPermissionStatus.deniedForever)
                      GestureDetector(
                        onTap: _showLocationDeniedForeverDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.location_off,
                                  size: 14, color: Colors.orange),
                              SizedBox(width: 4),
                              Text('GPS désactivé',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.orange)),
                            ],
                          ),
                        ),
                      )
                    else if (_permissionStatus ==
                        LocationPermissionStatus.denied)
                      GestureDetector(
                        onTap: () async {
                          await _checkLocationPermission();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.location_off,
                                  size: 14, color: Colors.orange),
                              SizedBox(width: 4),
                              Text('Autoriser GPS',
                                  style: TextStyle(
                                      fontSize: 11, color: Colors.orange)),
                            ],
                          ),
                        ),
                      )
                    else if (_permissionStatus ==
                        LocationPermissionStatus.granted)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.location_on,
                                size: 14, color: Colors.green),
                            SizedBox(width: 4),
                            Text('GPS actif',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.green)),
                          ],
                        ),
                      ),
                  ],
                ),

                // History preview
                Consumer<HistoryService>(
                  builder: (context, history, _) {
                    if (history.entries.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('Récemment visité',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: Colors.white38,
                                ),
                              ),
                              const Spacer(),
                              GestureDetector(
                                onTap: () => Navigator.push(context,
                                  MaterialPageRoute(
                                      builder: (_) => const HistoryScreen()),
                                ),
                                child: Text('Voir tout',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 8,
                              mainAxisSpacing: 8,
                              childAspectRatio: 1.0,
                            ),
                            itemCount: history.entries.take(6).length,
                            itemBuilder: (context, i) {
                              final entry = history.entries[i];
                              return GestureDetector(
                                onTap: () => Navigator.push(context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        HistoryDetailScreen(entry: entry),
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      File(entry.imagePath).existsSync()
                                          ? Image.file(File(entry.imagePath),
                                              fit: BoxFit.cover)
                                          : Container(
                                              color: theme.colorScheme.surfaceContainerHigh,
                                              child: const Icon(Icons.image,
                                                  color: Colors.white24)),
                                      // Title overlay at bottom
                                      Positioned(
                                        bottom: 0, left: 0, right: 0,
                                        child: Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.bottomCenter,
                                              end: Alignment.topCenter,
                                              colors: [
                                                Colors.black.withOpacity(0.7),
                                                Colors.transparent,
                                              ],
                                            ),
                                          ),
                                          child: Text(
                                            entry.title,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 9,
                                              height: 1.2,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),

                const Expanded(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.camera_alt_outlined,
                            size: 80, color: Colors.white12),
                        SizedBox(height: 16),
                        Text(
                          'Pointez votre appareil\nvers un lieu ou un monument',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white38,
                              fontSize: 15,
                              height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ),

                FilledButton.icon(
                  onPressed: _showImageSourceDialog,
                  icon: const Icon(Icons.camera_alt, size: 24),
                  label: const Text('Prendre une photo',
                      style: TextStyle(fontSize: 18)),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 64),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                  ),
                ).animate().scale(delay: 200.ms),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

