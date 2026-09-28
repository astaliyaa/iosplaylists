import '../models/library_song.dart';

/// A compact, deterministic text listing of a library that Claude can pick
/// songs from.
///
/// Songs get short numeric IDs (1, 2, 3, ...) in listing order so replies stay
/// small; [songForId] maps them back. The listing is grouped by artist and
/// album so each album's year and genre are written once:
///
/// ```text
/// ## Radiohead
/// # OK Computer (1997) · Alternative
/// 17 Airbag [12]
/// 18 Paranoid Android [58]
/// ```
///
/// `[N]` is the play count; songs never played have none. Rendering is fully
/// deterministic so repeated requests hit the prompt cache.
class LibraryCatalog {
  LibraryCatalog._(this.songs, this.artists);

  factory LibraryCatalog.build(Iterable<LibrarySong> library) {
    final byArtist = <String, List<LibrarySong>>{};
    for (final song in library) {
      byArtist.putIfAbsent(_key(song.artist), () => []).add(song);
    }

    final artistKeys = byArtist.keys.toList()..sort();
    final songs = <LibrarySong>[];
    final artists = <CatalogArtist>[];

    for (final artistKey in artistKeys) {
      final artistSongs = byArtist[artistKey]!;
      final byAlbum = <String, List<LibrarySong>>{};
      for (final song in artistSongs) {
        byAlbum.putIfAbsent(_key(song.album ?? ''), () => []).add(song);
      }

      final albums = <CatalogAlbum>[];
      for (final albumSongs in byAlbum.values) {
        albumSongs.sort(_compareTracks);
        albums.add(
          CatalogAlbum(
            title: albumSongs.first.album,
            year: _minYear(albumSongs),
            genre: _topGenres(albumSongs, 1).firstOrNull,
            songIds: const [],
            songs: albumSongs,
          ),
        );
      }
      albums.sort(_compareAlbums);

      final numberedAlbums = <CatalogAlbum>[];
      for (final album in albums) {
        final ids = <int>[];
        for (final song in album.songs) {
          songs.add(song);
          ids.add(songs.length);
        }
        numberedAlbums.add(album._withIds(ids));
      }

      final years = artistSongs.map((s) => s.year).whereType<int>();
      artists.add(
        CatalogArtist(
          id: artists.length + 1,
          name: artistSongs.first.artist,
          albums: numberedAlbums,
          genres: _topGenres(artistSongs, 3),
          songCount: artistSongs.length,
          totalPlays: artistSongs.fold(0, (sum, s) => sum + s.playCount),
          firstYear: years.isEmpty ? null : years.reduce(_min),
          lastYear: years.isEmpty ? null : years.reduce(_max),
        ),
      );
    }

    return LibraryCatalog._(
      List.unmodifiable(songs),
      List.unmodifiable(artists),
    );
  }

  /// Songs in listing order; song ID `n` is `songs[n - 1]`.
  final List<LibrarySong> songs;
  final List<CatalogArtist> artists;

  String? _fullListing;
  Map<String, int>? _idsByLibraryId;

  LibrarySong? songForId(int id) =>
      id >= 1 && id <= songs.length ? songs[id - 1] : null;

  /// The catalog ID of [song], or null if it isn't in this catalog.
  int? idForSong(LibrarySong song) => (_idsByLibraryId ??= {
    for (final (index, s) in songs.indexed) s.id: index + 1,
  })[song.id];

  CatalogArtist? artistForId(int id) =>
      id >= 1 && id <= artists.length ? artists[id - 1] : null;

  /// The song listing for every artist, or only for [onlyArtists] (in library
  /// order) when given.
  String renderSongs({Iterable<CatalogArtist>? onlyArtists}) {
    if (onlyArtists == null) {
      return _fullListing ??= _renderSongs(artists);
    }
    final wanted = onlyArtists.map((a) => a.id).toSet();
    return _renderSongs(artists.where((a) => wanted.contains(a.id)));
  }

  /// One line per artist, for narrowing down very large libraries:
  /// `12 Radiohead — Alternative, Rock · 84 songs · 1203 plays · 1993–2016`.
  String renderArtists() {
    final buffer = StringBuffer();
    for (final artist in artists) {
      buffer.write('${artist.id} ${artist.name}');
      if (artist.genres.isNotEmpty) {
        buffer.write(' — ${artist.genres.join(', ')}');
      }
      buffer.write(
        ' · ${artist.songCount} ${_plural(artist.songCount, 'song')}',
      );
      if (artist.totalPlays > 0) {
        buffer.write(
          ' · ${artist.totalPlays} ${_plural(artist.totalPlays, 'play')}',
        );
      }
      if (artist.firstYear != null) {
        buffer.write(
          artist.firstYear == artist.lastYear
              ? ' · ${artist.firstYear}'
              : ' · ${artist.firstYear}–${artist.lastYear}',
        );
      }
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// Rough token count for [text]; good enough for budgeting.
  static int estimateTokens(String text) => (text.length / 3.5).ceil();

  static String _renderSongs(Iterable<CatalogArtist> artists) {
    final buffer = StringBuffer();
    for (final artist in artists) {
      buffer.writeln('## ${artist.name}');
      for (final album in artist.albums) {
        buffer.write('# ${album.title ?? '(no album)'}');
        if (album.year != null) buffer.write(' (${album.year})');
        if (album.genre != null) buffer.write(' · ${album.genre}');
        buffer.writeln();
        for (final (index, song) in album.songs.indexed) {
          buffer.write('${album.songIds[index]} ${song.title}');
          if (song.playCount > 0) buffer.write(' [${song.playCount}]');
          buffer.writeln();
        }
      }
    }
    return buffer.toString();
  }

  static String _key(String text) => text.trim().toLowerCase();

  static int _min(int a, int b) => a < b ? a : b;
  static int _max(int a, int b) => a > b ? a : b;

  static String _plural(int count, String word) =>
      count == 1 ? word : '${word}s';

  static int? _minYear(List<LibrarySong> songs) {
    final years = songs.map((s) => s.year).whereType<int>();
    return years.isEmpty ? null : years.reduce(_min);
  }

  /// The [count] most common genres, ties broken by first appearance.
  static List<String> _topGenres(List<LibrarySong> songs, int count) {
    final counts = <String, int>{};
    for (final song in songs) {
      final genre = song.primaryGenre;
      if (genre != null) counts[genre] = (counts[genre] ?? 0) + 1;
    }
    final ranked = counts.keys.toList();
    final order = {for (final (i, g) in ranked.indexed) g: i};
    ranked.sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      return byCount != 0 ? byCount : order[a]!.compareTo(order[b]!);
    });
    return ranked.take(count).toList();
  }

  static int _compareTracks(LibrarySong a, LibrarySong b) {
    final disc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
    if (disc != 0) return disc;
    final track = (a.trackNumber ?? 1 << 20).compareTo(
      b.trackNumber ?? 1 << 20,
    );
    if (track != 0) return track;
    final title = _key(a.title).compareTo(_key(b.title));
    return title != 0 ? title : a.id.compareTo(b.id);
  }

  static int _compareAlbums(CatalogAlbum a, CatalogAlbum b) {
    final year = (a.year ?? 1 << 20).compareTo(b.year ?? 1 << 20);
    if (year != 0) return year;
    return _key(a.title ?? '').compareTo(_key(b.title ?? ''));
  }
}

class CatalogArtist {
  const CatalogArtist({
    required this.id,
    required this.name,
    required this.albums,
    required this.genres,
    required this.songCount,
    required this.totalPlays,
    this.firstYear,
    this.lastYear,
  });

  /// Artist ID used in the artist listing (independent of song IDs).
  final int id;
  final String name;
  final List<CatalogAlbum> albums;
  final List<String> genres;
  final int songCount;
  final int totalPlays;
  final int? firstYear;
  final int? lastYear;
}

class CatalogAlbum {
  const CatalogAlbum({
    required this.title,
    required this.year,
    required this.genre,
    required this.songIds,
    required this.songs,
  });

  final String? title;
  final int? year;
  final String? genre;

  /// Catalog song IDs, parallel to [songs].
  final List<int> songIds;
  final List<LibrarySong> songs;

  CatalogAlbum _withIds(List<int> ids) => CatalogAlbum(
    title: title,
    year: year,
    genre: genre,
    songIds: List.unmodifiable(ids),
    songs: List.unmodifiable(songs),
  );
}
