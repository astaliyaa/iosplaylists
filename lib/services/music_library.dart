import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/library_song.dart';
import 'demo_library.dart';

enum MusicAccess { authorized, denied, restricted, notDetermined }

class MusicLibraryException implements Exception {
  MusicLibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Read access to the user's songs and the ability to save playlists.
abstract class MusicLibrary {
  /// True when this is sample data rather than the real Apple Music library.
  bool get isDemo;

  Future<MusicAccess> accessStatus();

  Future<MusicAccess> requestAccess();

  Future<List<LibrarySong>> fetchSongs();

  Future<void> createPlaylist({
    required String name,
    required String description,
    required List<String> songIds,
  });
}

/// Uses Apple Music on iOS and sample data everywhere else, so the UI can be
/// worked on from Windows with `flutter run -d chrome`.
MusicLibrary createMusicLibrary() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return AppleMusicLibrary();
  }
  return DemoMusicLibrary();
}

/// Talks to `ios/Runner/MusicLibraryPlugin.swift` over a method channel.
class AppleMusicLibrary implements MusicLibrary {
  AppleMusicLibrary({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('promptlist/music_library');

  final MethodChannel _channel;

  @override
  bool get isDemo => false;

  @override
  Future<MusicAccess> accessStatus() => _invokeAccess('authorizationStatus');

  @override
  Future<MusicAccess> requestAccess() => _invokeAccess('requestAuthorization');

  @override
  Future<List<LibrarySong>> fetchSongs() async {
    final raw = await _invoke(
      () => _channel.invokeListMethod<Map<Object?, Object?>>('fetchSongs'),
    );
    return [for (final map in raw ?? const []) LibrarySong.fromMap(map)];
  }

  @override
  Future<void> createPlaylist({
    required String name,
    required String description,
    required List<String> songIds,
  }) async {
    await _invoke(
      () => _channel.invokeMethod<String>('createPlaylist', {
        'name': name,
        'description': description,
        'songIds': songIds,
      }),
    );
  }

  Future<MusicAccess> _invokeAccess(String method) async {
    final status = await _invoke(() => _channel.invokeMethod<String>(method));
    return MusicAccess.values.firstWhere(
      (value) => value.name == status,
      orElse: () => MusicAccess.denied,
    );
  }

  Future<T> _invoke<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (error) {
      throw MusicLibraryException(error.message ?? error.code);
    }
  }
}
