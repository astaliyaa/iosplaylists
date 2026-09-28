import 'package:flutter/foundation.dart';

import 'models/library_song.dart';
import 'services/claude_client.dart';
import 'services/library_catalog.dart';
import 'services/music_library.dart';
import 'services/on_device_generator.dart';
import 'services/on_device_model.dart';
import 'services/playlist_generator.dart';
import 'services/settings_store.dart';

/// App-wide state: settings, library access and the loaded songs.
class AppController extends ChangeNotifier {
  AppController({
    required this.library,
    required this.settingsStore,
    OnDeviceModel? onDeviceModel,
    this.createModel = _defaultModel,
  }) : onDeviceModel = onDeviceModel ?? createOnDeviceModel();

  final MusicLibrary library;
  final SettingsStore settingsStore;
  final OnDeviceModel onDeviceModel;
  final JsonModel Function(Settings settings) createModel;

  Settings settings = const Settings();
  OnDeviceStatus onDeviceStatus = OnDeviceStatus.unavailable;
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
    await refreshOnDeviceStatus();
    await _guard(() async {
      access = await library.accessStatus();
      if (access == MusicAccess.authorized) await _loadSongs();
    });
  }

  Future<void> refreshOnDeviceStatus() async {
    try {
      onDeviceStatus = await onDeviceModel.status();
    } on Object {
      onDeviceStatus = OnDeviceStatus.unavailable;
    }
    notifyListeners();
  }

  /// Why playlists can't be generated with the current settings, or null.
  String? get engineProblem => switch (settings.engine) {
    Engine.onDevice => onDeviceStatus.problem,
    Engine.claude =>
      settings.hasApiKey ? null : 'Add your Anthropic API key in Settings.',
  };

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

  /// The songs playlists are drawn from; explicit songs can be left out.
  LibraryCatalog catalog({required bool allowExplicit}) =>
      _catalogs[allowExplicit] ??= LibraryCatalog.build(
        allowExplicit
            ? songs ?? const []
            : (songs ?? const []).where((song) => !song.explicit),
      );

  PlaylistEngine newGenerator() => switch (settings.engine) {
    Engine.onDevice => OnDeviceGenerator(onDeviceModel),
    Engine.claude => PlaylistGenerator(createModel(settings)),
  };

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
