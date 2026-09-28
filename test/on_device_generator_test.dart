import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:promptlist/models/library_song.dart';
import 'package:promptlist/services/library_catalog.dart';
import 'package:promptlist/services/on_device_generator.dart';
import 'package:promptlist/services/on_device_model.dart';
import 'package:promptlist/services/playlist_engine.dart';

LibrarySong song(
  String id,
  String title,
  String artist, {
  String? genre,
  int? year,
  int plays = 0,
}) => LibrarySong(
  id: id,
  title: title,
  artist: artist,
  genres: [?genre, 'Music'],
  year: year,
  playCount: plays,
);

final library = [
  song(
    'r1',
    'Paranoid Android',
    'Radiohead',
    genre: 'Alternative',
    year: 1997,
    plays: 50,
  ),
  song(
    'r2',
    'Reckoner',
    'Radiohead',
    genre: 'Alternative',
    year: 2007,
    plays: 2,
  ),
  song(
    'w1',
    'Blinding Lights',
    'The Weeknd',
    genre: 'R&B/Soul',
    year: 2020,
    plays: 90,
  ),
  song('m1', 'Midnight City', 'M83', genre: 'Electronic', year: 2011),
  song(
    'k1',
    'Nightcall',
    'Kavinsky',
    genre: 'Electronic',
    year: 2013,
    plays: 60,
  ),
  song('f1', 'Mykonos', 'Fleet Foxes', genre: 'Folk', year: 2008, plays: 1),
  song('j1', 'So What', 'Miles Davis', genre: 'Jazz', year: 1959, plays: 5),
  song(
    's1',
    'Here Comes the Rain Again',
    'Eurythmics',
    genre: 'Pop',
    year: 1983,
  ),
];

List<String> ids(List<LibrarySong> songs) => [for (final s in songs) s.id];

class FakeModel implements OnDeviceModel {
  FakeModel({required this.plans, this.picks = const [], this.pickError});

  final List<OnDevicePlan> plans;
  final List<List<int>> picks;
  final Object? pickError;
  final planPrompts = <String>[];
  final pickPrompts = <String>[];

  @override
  Future<OnDeviceStatus> status() async => OnDeviceStatus.available;

  @override
  Future<OnDevicePlan> plan({
    required String instructions,
    required String prompt,
  }) async {
    planPrompts.add(prompt);
    return plans[planPrompts.length - 1];
  }

  @override
  Future<List<int>> pick({
    required String instructions,
    required String prompt,
  }) async {
    pickPrompts.add(prompt);
    if (pickError != null) throw pickError!;
    return picks[pickPrompts.length - 1];
  }
}

void main() {
  group('OnDevicePlan.fromMap', () {
    test('cleans up what the model returns', () {
      final plan = OnDevicePlan.fromMap({
        'name': ' Night Drive ',
        'description': 'Synths.',
        'genres': ['Electronic', '  ', 3],
        'artists': null,
        'keywords': ['night'],
        'fromYear': 2010,
        'toYear': 99999,
        'listening': 'Most played',
      });

      expect(plan.name, 'Night Drive');
      expect(plan.genres, ['Electronic']);
      expect(plan.artists, isEmpty);
      expect(plan.fromYear, 2010);
      expect(plan.toYear, 0);
      expect(plan.listening, ListeningPreference.mostPlayed);
      expect(
        OnDevicePlan.fromMap({'listening': 'rarelyPlayed'}).listening,
        ListeningPreference.rarelyPlayed,
      );
      expect(
        OnDevicePlan.fromMap({'listening': 'whatever'}).listening,
        ListeningPreference.any,
      );
    });
  });

  group('rankSongs', () {
    test('artist matches beat genre matches, which must match something', () {
      final ranked = rankSongs(
        library,
        const OnDevicePlan(artists: ['M83'], genres: ['electronic']),
      );

      expect(ids(ranked), ['m1', 'k1']);
    });

    test('ignores a leading "The" and matches whole genre words', () {
      final ranked = rankSongs(
        library,
        const OnDevicePlan(artists: ['weeknd'], genres: ['soul']),
      );

      expect(ids(ranked), ['w1']);
    });

    test('keywords match whole words in titles', () {
      expect(ids(rankSongs(library, const OnDevicePlan(keywords: ['rain']))), [
        's1',
      ]);
      expect(
        rankSongs(library, const OnDevicePlan(keywords: ['ain'])),
        isEmpty,
      );
    });

    test('years filter when nothing else is asked for', () {
      final ranked = rankSongs(
        library,
        const OnDevicePlan(fromYear: 2005, toYear: 2012),
      );

      expect(ids(ranked).toSet(), {'r2', 'm1', 'f1'});
    });

    test('years push matching songs down rather than out', () {
      final ranked = rankSongs(
        library,
        const OnDevicePlan(genres: ['Alternative'], toYear: 2000),
      );

      expect(ids(ranked), ['r1']);
      final withArtist = rankSongs(
        library,
        const OnDevicePlan(artists: ['Radiohead'], toYear: 2000),
      );
      expect(ids(withArtist), ['r1', 'r2']);
    });

    test('listening habits order the results', () {
      final most = rankSongs(
        library,
        const OnDevicePlan(listening: ListeningPreference.mostPlayed),
      );
      expect(ids(most).take(3), ['w1', 'k1', 'r1']);

      final rarely = rankSongs(
        library,
        const OnDevicePlan(
          genres: ['Electronic', 'Alternative'],
          listening: ListeningPreference.rarelyPlayed,
        ),
      );
      expect(ids(rarely).first, 'm1');
      expect(ids(rarely).last, anyOf('r1', 'k1'));
    });

    test('an empty plan keeps every song', () {
      expect(
        rankSongs(library, const OnDevicePlan(), random: Random(1)),
        hasLength(library.length),
      );
    });
  });

  test('diversify caps songs per artist but fills up if needed', () {
    final ranked = [
      song('a1', 'A1', 'A'),
      song('a2', 'A2', 'A'),
      song('a3', 'A3', 'A'),
      song('b1', 'B1', 'B'),
    ];

    expect(ids(diversify(ranked, limit: 3, perArtist: 1)), ['a1', 'b1', 'a2']);
    expect(ids(diversify(ranked, limit: 10, perArtist: 2)), [
      'a1',
      'a2',
      'b1',
      'a3',
    ]);
  });

  group('OnDeviceGenerator', () {
    final catalog = LibraryCatalog.build([
      for (var i = 0; i < 40; i++)
        song(
          'e$i',
          'Electronic $i',
          'Artist $i',
          genre: 'Electronic',
          year: 2010,
        ),
      for (var i = 0; i < 10; i++)
        song('j$i', 'Jazz $i', 'Jazz Artist $i', genre: 'Jazz', year: 1960),
    ]);
    const plan = OnDevicePlan(
      name: 'Night Drive',
      description: 'Synths.',
      genres: ['Electronic'],
    );

    test('uses the model\'s picks in order, ignoring bad numbers', () async {
      final model = FakeModel(
        plans: [plan],
        picks: [
          [3, 1, 3, 99, 0, 2],
        ],
      );

      final session = await OnDeviceGenerator(
        model,
        random: Random(1),
      ).generate(catalog: catalog, prompt: ' night drive ', songCount: 3);

      expect(model.planPrompts.single, startsWith('Request: night drive'));
      expect(model.planPrompts.single, contains('Electronic, Jazz'));
      final pickPrompt = model.pickPrompts.single;
      expect(pickPrompt, contains('Choose about 3 songs.'));
      expect(pickPrompt, isNot(contains('Jazz')));
      // 30 candidates: at least 30, at most 80, twice the requested length.
      expect(
        RegExp(r'^\d+\. ', multiLine: true).allMatches(pickPrompt),
        hasLength(30),
      );

      final draft = session.draft;
      expect(draft.name, 'Night Drive');
      expect(draft.description, 'Synths.');
      expect(draft.songs, hasLength(3));
      final lines = pickPrompt.split('\n');
      String titleOf(int n) => lines
          .firstWhere((l) => l.startsWith('$n. '))
          .split(' — ')
          .first
          .substring('$n. '.length);
      expect(
        [for (final s in draft.songs) s.title],
        [titleOf(3), titleOf(1), titleOf(2)],
      );
      expect(draft.note, isEmpty);
    });

    test('tops up short picks and survives a failing pick step', () async {
      final short = await OnDeviceGenerator(
        FakeModel(
          plans: [plan],
          picks: [
            [5],
          ],
        ),
        random: Random(1),
      ).generate(catalog: catalog, prompt: 'x', songCount: 10);
      expect(short.draft.songs, hasLength(10));
      expect(short.draft.songs.toSet(), hasLength(10));

      final failed = await OnDeviceGenerator(
        FakeModel(plans: [plan], pickError: Exception('context too long')),
        random: Random(1),
      ).generate(catalog: catalog, prompt: 'x', songCount: 10);
      expect(failed.draft.songs, hasLength(10));
      expect(failed.draft.songs.every((s) => s.id.startsWith('e')), isTrue);
    });

    test('skips the pick step when every candidate fits', () async {
      final model = FakeModel(
        plans: [
          const OnDevicePlan(genres: ['Jazz']),
        ],
      );

      final session = await OnDeviceGenerator(model)
          .generate(catalog: catalog, prompt: 'jazz', songCount: 25);

      expect(model.pickPrompts, isEmpty);
      expect(session.draft.songs, hasLength(10));
      expect(session.draft.name, 'New Playlist');
      expect(
        session.draft.note,
        'Only 10 songs in your library fit this request.',
      );
    });

    test('says so when nothing matches', () async {
      await expectLater(
        OnDeviceGenerator(
          FakeModel(
            plans: [
              const OnDevicePlan(genres: ['Polka']),
            ],
          ),
        ).generate(catalog: catalog, prompt: 'polka', songCount: 10),
        throwsA(isA<GenerationException>()),
      );
    });

    test('refining re-plans with the feedback added', () async {
      final model = FakeModel(
        plans: [
          plan,
          const OnDevicePlan(name: 'Jazz Night', genres: ['Jazz']),
        ],
        picks: [
          [1, 2],
          [2, 1],
        ],
      );
      final generator = OnDeviceGenerator(model, random: Random(1));
      final session = await generator.generate(
        catalog: catalog,
        prompt: 'night drive',
        songCount: 5,
      );

      final draft = await generator.refine(
        session: session,
        current: session.draft,
        feedback: 'make it jazz',
      );

      expect(
        model.planPrompts.last,
        startsWith('Request: night drive\nAlso: make it jazz'),
      );
      expect(draft.name, 'Jazz Night');
      expect(draft.songs.every((s) => s.id.startsWith('j')), isTrue);
      expect(session.draft, same(draft));
      expect(session.prompt, 'night drive\nAlso: make it jazz');
    });
  });
}
