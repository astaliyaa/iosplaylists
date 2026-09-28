import 'package:flutter_test/flutter_test.dart';
import 'package:promptlist/models/library_song.dart';
import 'package:promptlist/services/library_catalog.dart';

LibrarySong song(
  String id,
  String title,
  String artist, {
  String? album,
  List<String> genres = const [],
  int? year,
  int plays = 0,
  int? track,
  bool explicit = false,
}) => LibrarySong(
  id: id,
  title: title,
  artist: artist,
  album: album,
  genres: genres,
  year: year,
  playCount: plays,
  trackNumber: track,
  explicit: explicit,
);

void main() {
  final library = [
    song(
      'r2',
      'Paranoid Android',
      'Radiohead',
      album: 'OK Computer',
      genres: ['Music', 'Alternative'],
      year: 1997,
      plays: 58,
      track: 2,
    ),
    song('m1', 'Midnight City', 'M83', genres: ['Electronic'], year: 2011),
    song(
      'r1',
      'Airbag',
      'Radiohead',
      album: 'OK Computer',
      genres: ['Alternative'],
      year: 1997,
      plays: 12,
      track: 1,
    ),
    song(
      'r3',
      'Reckoner',
      'radiohead',
      album: 'In Rainbows',
      genres: ['Alternative', 'Rock'],
      year: 2007,
      plays: 1,
    ),
    song(
      'r0',
      'Creep',
      'Radiohead',
      album: 'Pablo Honey',
      genres: ['Rock'],
      year: 1993,
    ),
  ];

  test('groups songs by artist and album with sequential ids', () {
    final catalog = LibraryCatalog.build(library);

    expect(
      catalog.renderSongs(),
      '## M83\n'
      '# (no album) (2011) · Electronic\n'
      '1 Midnight City\n'
      '## Radiohead\n'
      '# Pablo Honey (1993) · Rock\n'
      '2 Creep\n'
      '# OK Computer (1997) · Alternative\n'
      '3 Airbag [12]\n'
      '4 Paranoid Android [58]\n'
      '# In Rainbows (2007) · Alternative\n'
      '5 Reckoner [1]\n',
    );
    expect(catalog.songForId(4)!.id, 'r2');
    expect(catalog.songForId(0), isNull);
    expect(catalog.songForId(6), isNull);
    expect(catalog.idForSong(library.first), 4);
  });

  test('summarises artists on one line each', () {
    final catalog = LibraryCatalog.build(library);

    expect(
      catalog.renderArtists(),
      '1 M83 — Electronic · 1 song · 2011\n'
      '2 Radiohead — Alternative, Rock · 4 songs · 71 plays · 1993–2007\n',
    );
  });

  test('renders only the requested artists', () {
    final catalog = LibraryCatalog.build(library);
    final m83 = catalog.artistForId(1)!;

    expect(
      catalog.renderSongs(onlyArtists: [m83]),
      '## M83\n# (no album) (2011) · Electronic\n1 Midnight City\n',
    );
  });

  test('is deterministic regardless of input order', () {
    final forward = LibraryCatalog.build(library).renderSongs();
    final backward = LibraryCatalog.build(library.reversed).renderSongs();

    expect(backward, forward);
  });

  test('parses platform channel maps', () {
    final parsed = LibrarySong.fromMap({
      'id': 'i.abc',
      'title': '  Nights ',
      'artist': 'Frank Ocean',
      'album': '',
      'genres': ['Music', 'R&B/Soul', ''],
      'year': 2016,
      'playCount': 64.0,
      'explicit': true,
      'dateAddedMs': 0,
    });

    expect(parsed.title, 'Nights');
    expect(parsed.album, isNull);
    expect(parsed.genres, ['Music', 'R&B/Soul']);
    expect(parsed.primaryGenre, 'R&B/Soul');
    expect(parsed.playCount, 64);
    expect(parsed.explicit, isTrue);
    expect(parsed.dateAdded, DateTime.fromMillisecondsSinceEpoch(0));
  });
}
