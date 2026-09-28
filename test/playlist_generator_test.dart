import 'package:flutter_test/flutter_test.dart';
import 'package:promptlist/models/library_song.dart';
import 'package:promptlist/services/claude_client.dart';
import 'package:promptlist/services/library_catalog.dart';
import 'package:promptlist/services/playlist_generator.dart';

class Call {
  Call(this.system, this.messages, this.schema);

  final String system;
  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> schema;
}

/// Replies with queued JSON objects and records every request.
class FakeModel implements JsonModel {
  FakeModel(this.replies);

  final List<Map<String, dynamic>> replies;
  final calls = <Call>[];
  final contents = <List<dynamic>>[];

  @override
  Future<ModelReply> createJson({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
  }) async {
    calls.add(Call(system, List.of(messages), schema));
    final json = replies.removeAt(0);
    final content = [
      {'type': 'text', 'text': '$json'},
    ];
    contents.add(content);
    return ModelReply(json: json, content: content);
  }
}

List<LibrarySong> makeLibrary(int artists, int songsPerArtist) => [
  for (var a = 0; a < artists; a++)
    for (var s = 0; s < songsPerArtist; s++)
      LibrarySong(
        id: 'a$a-s$s',
        title: 'Song $s by artist $a',
        artist: 'Artist ${a.toString().padLeft(3, '0')}',
        album: 'Album $a',
        genres: const ['Rock'],
        year: 2000 + a % 20,
        trackNumber: s + 1,
      ),
];

String textOf(Map<String, dynamic> message) {
  final content = message['content'];
  if (content is String) return content;
  return (content as List).map((b) => (b as Map)['text']).join('\n');
}

void main() {
  test('sends the whole library and maps ids back to songs', () async {
    final catalog = LibraryCatalog.build(makeLibrary(3, 4));
    final model = FakeModel([
      {
        'name': 'Test Mix',
        'description': 'A mix.',
        'song_ids': [5, 1, 5, 999, 12],
        'note': '',
      },
    ]);

    final session = await PlaylistGenerator(model)
        .generate(catalog: catalog, prompt: '  rainy day  ', songCount: 20);

    expect(model.calls, hasLength(1));
    final call = model.calls.single;
    expect(call.system, playlistSystemPrompt);
    expect(call.schema, playlistSchema);
    final blocks = call.messages.single['content'] as List;
    expect(
      blocks.first['text'],
      '<library>\n${catalog.renderSongs()}</library>',
    );
    expect(blocks.first['cache_control'], {'type': 'ephemeral'});
    expect(blocks.last['text'], contains('Playlist request: rainy day'));
    expect(blocks.last['text'], contains('about 20 songs'));

    final draft = session.draft;
    expect(draft.name, 'Test Mix');
    // Duplicates and unknown ids are dropped; order is kept.
    expect(draft.songs.map((s) => s.id), ['a1-s0', 'a0-s0', 'a2-s3']);
  });

  test('refine continues the conversation with the edited playlist', () async {
    final catalog = LibraryCatalog.build(makeLibrary(2, 3));
    final model = FakeModel([
      {
        'name': 'First',
        'description': '',
        'song_ids': [1, 2, 3],
        'note': '',
      },
      {
        'name': 'Second',
        'description': 'Better.',
        'song_ids': [4, 1],
        'note': 'Swapped a few.',
      },
    ]);
    final generator = PlaylistGenerator(model);
    final session = await generator.generate(
      catalog: catalog,
      prompt: 'x',
      songCount: 10,
    );

    final edited = PlaylistDraft(
      name: 'My Name',
      description: '',
      songs: [session.draft.songs[2], session.draft.songs[0]],
    );
    final draft = await generator.refine(
      session: session,
      current: edited,
      feedback: 'more energy',
    );

    final messages = model.calls.last.messages;
    expect(messages.map((m) => m['role']), ['user', 'assistant', 'user']);
    // Claude's earlier reply is replayed exactly as received.
    expect(messages[1]['content'], same(model.contents.first));
    expect(textOf(messages[2]), contains('more energy'));
    expect(textOf(messages[2]), contains('Name: My Name'));
    expect(textOf(messages[2]), contains('Songs in order: 3, 1'));

    expect(draft.name, 'Second');
    expect(draft.note, 'Swapped a few.');
    expect(draft.songs.map((s) => s.id), ['a1-s0', 'a0-s0']);
    expect(session.draft, same(draft));

    // A second refinement builds on the whole history.
    model.replies.add({
      'name': 'Third',
      'description': '',
      'song_ids': [2],
      'note': '',
    });
    await generator.refine(session: session, current: draft, feedback: 'x');
    expect(model.calls.last.messages, hasLength(5));
  });

  test('a failed refinement leaves the conversation untouched', () async {
    final catalog = LibraryCatalog.build(makeLibrary(1, 2));
    final model = FakeModel([
      {
        'name': 'A',
        'description': '',
        'song_ids': [1],
        'note': '',
      },
      {
        'name': 'B',
        'description': '',
        'song_ids': <int>[],
        'note': 'Nothing fits.',
      },
      {
        'name': 'C',
        'description': '',
        'song_ids': [2],
        'note': '',
      },
    ]);
    final generator = PlaylistGenerator(model);
    final session = await generator.generate(
      catalog: catalog,
      prompt: 'x',
      songCount: 10,
    );

    await expectLater(
      generator.refine(session: session, current: session.draft, feedback: 'y'),
      throwsA(
        isA<GenerationException>().having(
          (e) => e.message,
          'message',
          'Nothing fits.',
        ),
      ),
    );
    expect(session.draft.name, 'A');

    await generator.refine(
      session: session,
      current: session.draft,
      feedback: 'z',
    );
    expect(model.calls.last.messages, hasLength(3));
  });

  test('large libraries are shortlisted by artist first', () async {
    final catalog = LibraryCatalog.build(makeLibrary(40, 10));
    final fullTokens = LibraryCatalog.estimateTokens(catalog.renderSongs());
    final model = FakeModel([
      {
        'artist_ids': [7, 3, 7, 9999, 12],
      },
      {
        'name': 'Shortlisted',
        'description': '',
        'song_ids': [
          catalog.idForSong(catalog.artistForId(3)!.albums.first.songs.first)!,
        ],
        'note': '',
      },
    ]);
    final statuses = <String>[];

    final session =
        await PlaylistGenerator(
          model,
          fullCatalogTokenBudget: fullTokens ~/ 4,
        ).generate(
          catalog: catalog,
          prompt: 'rock',
          songCount: 15,
          onStatus: statuses.add,
        );

    expect(model.calls, hasLength(2));
    expect(model.calls.first.system, artistSystemPrompt);
    expect(model.calls.first.schema, artistSchema);
    expect(
      textOf(model.calls.first.messages.single),
      contains(catalog.renderArtists()),
    );

    final listing = textOf(model.calls.last.messages.single);
    final expected = catalog.renderSongs(
      onlyArtists: [
        catalog.artistForId(3)!,
        catalog.artistForId(7)!,
        catalog.artistForId(12)!,
      ],
    );
    expect(listing, contains(expected));
    expect(listing, contains('only part of the library'));
    expect(listing, isNot(contains('## Artist 000')));

    expect(session.draft.songs.single.artist, 'Artist 002');
    expect(statuses, ['Narrowing down 40 artists…', 'Picking songs…']);
  });

  test('shortlist stops adding artists once over budget', () async {
    final catalog = LibraryCatalog.build(makeLibrary(10, 10));
    int size(int artistId) => LibraryCatalog.estimateTokens(
      catalog.renderSongs(onlyArtists: [catalog.artistForId(artistId)!]),
    );
    final model = FakeModel([
      {
        'artist_ids': [1, 2, 3, 4, 5],
      },
      {
        'name': 'N',
        'description': '',
        'song_ids': [1],
        'note': '',
      },
    ]);

    await PlaylistGenerator(
      model,
      fullCatalogTokenBudget: size(1) + size(2),
    ).generate(catalog: catalog, prompt: 'x', songCount: 10);

    final listing = textOf(model.calls.last.messages.single);
    expect(listing, contains('## Artist 000'));
    expect(listing, contains('## Artist 001'));
    expect(listing, isNot(contains('## Artist 002')));
  });

  test('empty libraries fail before calling Claude', () async {
    final model = FakeModel([]);

    await expectLater(
      PlaylistGenerator(model).generate(
        catalog: LibraryCatalog.build(const []),
        prompt: 'x',
        songCount: 10,
      ),
      throwsA(isA<GenerationException>()),
    );
    expect(model.calls, isEmpty);
  });
}
