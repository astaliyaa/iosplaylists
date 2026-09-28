import '../models/library_song.dart';
import 'claude_client.dart';
import 'library_catalog.dart';
import 'playlist_engine.dart';

export 'playlist_engine.dart';

/// Uses Claude to turn a prompt into a playlist drawn from the user's library.
///
/// Normally the whole library listing is sent in one request (and cached, so
/// follow-ups are cheap). Libraries whose listing would exceed
/// [fullCatalogTokenBudget] are narrowed down first: Claude picks promising
/// artists from a one-line-per-artist summary, then chooses songs from those
/// artists only.
class PlaylistGenerator implements PlaylistEngine {
  PlaylistGenerator(
    this.model, {
    this.fullCatalogTokenBudget = defaultFullCatalogTokenBudget,
    this.maxShortlistArtists = 150,
  });

  /// Roughly 6,000 songs.
  static const defaultFullCatalogTokenBudget = 60000;

  final JsonModel model;
  final int fullCatalogTokenBudget;
  final int maxShortlistArtists;

  @override
  Future<PlaylistSession> generate({
    required LibraryCatalog catalog,
    required String prompt,
    required int songCount,
    void Function(String status)? onStatus,
  }) async {
    if (catalog.songs.isEmpty) {
      throw GenerationException('Your library has no songs to choose from.');
    }

    var listing = catalog.renderSongs();
    var isSubset = false;
    if (LibraryCatalog.estimateTokens(listing) > fullCatalogTokenBudget) {
      onStatus?.call('Narrowing down ${catalog.artists.length} artists…');
      final artists = await _shortlistArtists(catalog, prompt);
      listing = catalog.renderSongs(onlyArtists: artists);
      isSubset = true;
    }

    onStatus?.call('Picking songs…');
    final messages = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [
          {
            'type': 'text',
            'text': '<library>\n$listing</library>',
            'cache_control': {'type': 'ephemeral'},
          },
          {
            'type': 'text',
            'text': [
              if (isSubset)
                'The listing above is only part of the library: the artists '
                    'most likely to fit this request.',
              'Playlist request: ${prompt.trim()}',
              'Length: about $songCount songs.',
            ].join('\n\n'),
          },
        ],
      },
    ];

    final reply = await model.createJson(
      system: playlistSystemPrompt,
      messages: messages,
      schema: playlistSchema,
    );
    messages.add({'role': 'assistant', 'content': reply.content});
    return PlaylistSession(
      catalog: catalog,
      prompt: prompt,
      songCount: songCount,
      draft: _toDraft(catalog, reply.json),
      state: messages,
    );
  }

  @override
  Future<PlaylistDraft> refine({
    required PlaylistSession session,
    required PlaylistDraft current,
    required String feedback,
  }) async {
    final catalog = session.catalog;
    final history = session.state! as List<Map<String, dynamic>>;
    final currentIds = [
      for (final song in current.songs) ?catalog.idForSong(song),
    ];
    final messages = [
      ...history,
      {
        'role': 'user',
        'content':
            'Revise the playlist based on this feedback: ${feedback.trim()}\n\n'
            'Here is the current version after my own edits.\n'
            'Name: ${current.name}\n'
            'Songs in order: ${currentIds.join(', ')}\n\n'
            'Reply with the complete updated playlist.',
      },
    ];

    final reply = await model.createJson(
      system: playlistSystemPrompt,
      messages: messages,
      schema: playlistSchema,
    );
    final draft = _toDraft(catalog, reply.json);
    history
      ..clear()
      ..addAll(messages)
      ..add({'role': 'assistant', 'content': reply.content});
    session.draft = draft;
    return draft;
  }

  Future<List<CatalogArtist>> _shortlistArtists(
    LibraryCatalog catalog,
    String prompt,
  ) async {
    final reply = await model.createJson(
      system: artistSystemPrompt,
      messages: [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': '<artists>\n${catalog.renderArtists()}</artists>',
              'cache_control': {'type': 'ephemeral'},
            },
            {
              'type': 'text',
              'text':
                  'Playlist request: ${prompt.trim()}\n\n'
                  'Return at most $maxShortlistArtists artist ids.',
            },
          ],
        },
      ],
      schema: artistSchema,
    );

    final seen = <int>{};
    final picked = <CatalogArtist>[];
    var tokens = 0;
    for (final id in _intList(reply.json['artist_ids'])) {
      final artist = catalog.artistForId(id);
      if (artist == null || !seen.add(id)) continue;
      final size = LibraryCatalog.estimateTokens(
        catalog.renderSongs(onlyArtists: [artist]),
      );
      if (picked.isNotEmpty && tokens + size > fullCatalogTokenBudget) break;
      picked.add(artist);
      tokens += size;
      if (picked.length >= maxShortlistArtists) break;
    }
    if (picked.isEmpty) {
      throw GenerationException(
        'Claude couldn’t find any artists in your library for that request.',
      );
    }
    return picked;
  }

  static PlaylistDraft _toDraft(
    LibraryCatalog catalog,
    Map<String, dynamic> json,
  ) {
    final seen = <int>{};
    final songs = <LibrarySong>[];
    for (final id in _intList(json['song_ids'])) {
      final song = catalog.songForId(id);
      if (song != null && seen.add(id)) songs.add(song);
    }
    final note = (json['note'] as String? ?? '').trim();
    if (songs.isEmpty) {
      throw GenerationException(
        note.isNotEmpty
            ? note
            : 'Claude didn’t pick any songs. Try rephrasing your request.',
      );
    }
    final name = (json['name'] as String? ?? '').trim();
    return PlaylistDraft(
      name: name.isEmpty ? 'New Playlist' : name,
      description: (json['description'] as String? ?? '').trim(),
      songs: songs,
      note: note,
    );
  }

  static Iterable<int> _intList(Object? value) =>
      value is List ? value.whereType<num>().map((n) => n.toInt()) : const [];
}

const playlistSystemPrompt = '''
You are a music curator. You build playlists for one listener using only songs that are already in their Apple Music library.

The library listing is formatted like this:
- "## Name" starts an artist.
- "# Album (year) · Genre" starts one of that artist's albums. The year or genre is left out when unknown.
- Each song line is "<id> <title>", optionally followed by "[N]": the number of times the listener has played it. No [N] means they have never played it.

Choosing songs:
- Use only ids that appear in the listing. Never invent songs or ids.
- Read the request for mood, energy, era, genre, activity and any explicit constraints (artists to include or avoid, "songs I haven't played much", "my favorites", and so on). Use play counts when the request is about listening habits.
- Draw on what you know about each song's sound, tempo, lyrics and reputation, not just its genre tag. If you don't know a song, judge it by its artist, album and genre.
- Unless the request says otherwise, keep it varied: no more than a few songs per artist, and no near-duplicates such as the same song on two albums or live and studio versions of one track.
- Order the songs so the playlist flows well from start to finish.
- Aim for the requested length. If the library can't fill it with good matches, return fewer songs rather than weak fits, and say so in the note.

Reply fields:
- name: a short, evocative playlist title.
- description: one or two sentences for the playlist's description in Apple Music.
- song_ids: the chosen song ids, in play order.
- note: a one-sentence remark for the listener if something needs flagging (for example, that the library ran short), otherwise an empty string.''';

const artistSystemPrompt = '''
You help build a playlist from a listener's very large Apple Music library. The library is too big to show in full, so first you choose which artists to look at more closely.

Each line of the artist listing is "<id> <name> — <main genres> · <song count> · <total plays> · <years>". Plays is how often the listener has played that artist's songs; it is left out when zero.

Pick the artists whose songs could fit the playlist request, most promising first. Be inclusive: a borderline artist costs little, while leaving out a good one means their songs can't be chosen. Skip artists that clearly don't fit.''';

const playlistSchema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'name': {'type': 'string'},
    'description': {'type': 'string'},
    'song_ids': {
      'type': 'array',
      'items': {'type': 'integer'},
    },
    'note': {'type': 'string'},
  },
  'required': ['name', 'description', 'song_ids', 'note'],
  'additionalProperties': false,
};

const artistSchema = <String, dynamic>{
  'type': 'object',
  'properties': {
    'artist_ids': {
      'type': 'array',
      'items': {'type': 'integer'},
    },
  },
  'required': ['artist_ids'],
  'additionalProperties': false,
};
