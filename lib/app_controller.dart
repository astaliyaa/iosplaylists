import 'package:flutter/foundation.dart';

import 'models/library_song.dart';
import 'services/claude_client.dart';
import 'services/library_catalog.dart';
import 'services/music_library.dart';
import 'services/playlist_generator.dart';
import 'services/settings_store.dart';

/// App-wide state: settings, library access and the loaded songs.
class AppController extends ChangeNotifier {
  AppController({
    required this.library,
    required this.settingsStore,
    this.createModel = _defaultModel,
  });

  final MusicLibrary library;
  final SettingsStore settingsStore;
  final JsonModel Function(Settings settings) createModel;

  Settings settings = const Settings();
  MusicAccess? access;
  List<LibrarySong>? songs;
  bool loadingLibrary = false;
  String? libraryError;

  final Map<bool, LibraryCatalog> _catalogs = {};

  static JsonModel _defaultModel(Settings settings) => ClaudeClient(
    apiKey: settings.apiKey,
    model: settings.model,
    effort: settings.effort,
  );

  Future<void> init() async {
    try {
      settings = await settingsStore.load();
    } on Object catch (error) {
      debugPrint('Could not load settings: $error');
    }
    notifyListeners();
    await _guard(() async {
      access = await library.accessStatus();
      if (access == MusicAccess.authorized) await _loadSongs();
    });
  }

  Future<void> connectLibrary() => _guard(() async {
    access = await library.requestAccess();
    if (access == MusicAccess.authorized) await _loadSongs();
  });

  Future<void> reloadLibrary() => _guard(_loadSongs);

  Future<void> saveSettings(Settings updated) async {
    await settingsStore.save(updated);
    settings = updated;
    notifyListeners();
  }

  /// The catalog Claude chooses from; explicit songs can be left out.
  LibraryCatalog catalog({required bool allowExplicit}) =>
      _catalogs[allowExplicit] ??= LibraryCatalog.build(
        allowExplicit
            ? songs ?? const []
            : (songs ?? const []).where((song) => !song.explicit),
      );

  PlaylistGenerator newGenerator() => PlaylistGenerator(createModel(settings));

  Future<void> savePlaylist(PlaylistDraft draft) => library.createPlaylist(
    name: draft.name,
    description: draft.description,
    songIds: [for (final song in draft.songs) song.id],
  );

  Future<void> _loadSongs() async {
    songs = await library.fetchSongs();
    _catalogs.clear();
  }

  Future<void> _guard(Future<void> Function() action) async {
    loadingLibrary = true;
    libraryError = null;
    notifyListeners();
    try {
      await action();
    } on Object catch (error) {
      libraryError = error.toString();
    } finally {
      loadingLibrary = false;
      notifyListeners();
    }
  }
}
