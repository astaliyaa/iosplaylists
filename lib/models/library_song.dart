/// A song in the user's music library.
class LibrarySong {
  const LibrarySong({
    required this.id,
    required this.title,
    required this.artist,
    this.album,
    this.genres = const [],
    this.year,
    this.playCount = 0,
    this.explicit = false,
    this.trackNumber,
    this.discNumber,
    this.durationSeconds,
    this.dateAdded,
    this.lastPlayed,
  });

  /// Builds a song from the map sent over the `promptlist/music_library`
  /// platform channel (see `ios/Runner/MusicLibraryPlugin.swift`).
  factory LibrarySong.fromMap(Map<Object?, Object?> map) {
    int? asInt(Object? value) => value is num ? value.toInt() : null;
    DateTime? asDate(Object? value) => value is num
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : null;
    String? asText(Object? value) {
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return LibrarySong(
      id: map['id'] as String,
      title: asText(map['title']) ?? 'Untitled',
      artist: asText(map['artist']) ?? 'Unknown Artist',
      album: asText(map['album']),
      genres: [
        for (final genre in (map['genres'] as List<Object?>? ?? const []))
          ?asText(genre),
      ],
      year: asInt(map['year']),
      playCount: asInt(map['playCount']) ?? 0,
      explicit: map['explicit'] == true,
      trackNumber: asInt(map['trackNumber']),
      discNumber: asInt(map['discNumber']),
      durationSeconds: asInt(map['durationSeconds']),
      dateAdded: asDate(map['dateAddedMs']),
      lastPlayed: asDate(map['lastPlayedMs']),
    );
  }

  /// MusicKit library ID, used to add the song to a playlist.
  final String id;
  final String title;
  final String artist;
  final String? album;
  final List<String> genres;
  final int? year;
  final int playCount;
  final bool explicit;
  final int? trackNumber;
  final int? discNumber;
  final int? durationSeconds;
  final DateTime? dateAdded;
  final DateTime? lastPlayed;

  /// The genre most useful for describing the song. Apple tags nearly
  /// everything with the catch-all "Music", so that one is skipped.
  String? get primaryGenre {
    for (final genre in genres) {
      if (genre.toLowerCase() != 'music') return genre;
    }
    return null;
  }
}
