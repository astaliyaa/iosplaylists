import 'dart:math';

import '../models/library_song.dart';
import 'library_catalog.dart';
import 'on_device_model.dart';
import 'playlist_engine.dart';

/// Free playlist generation with Apple's on-device model.
///
/// That model only reads a few thousand tokens, so it never sees the whole
/// library. Instead it:
/// 1. turns the request into search criteria (genres, artists, years, ...),
/// 2. the app ranks the library against those criteria, and
/// 3. the model picks and orders songs from the best-ranked candidates.
class OnDeviceGenerator implements PlaylistEngine {
  OnDeviceGenerator(this.model, {Random? random, this.maxCandidates = 80})
    : _random = random ?? Random();

  final OnDeviceModel model;
  final int maxCandidates;
  final Random _random;

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
    final request = prompt.trim();
    final draft = await _generate(catalog, request, songCount, onStatus);
    return PlaylistSession(
      catalog: catalog,
      prompt: request,
      songCount: songCount,
      draft: draft,
    );
  }

  @override
  Future<PlaylistDraft> refine({
    required PlaylistSession session,
    required PlaylistDraft current,
    required String feedback,
  }) async {
    final prompt = '${session.prompt}\nAlso: ${feedback.trim()}';
    final draft = await _generate(
      session.catalog,
      prompt,
      session.songCount,
      null,
    );
    session
      ..prompt = prompt
      ..draft = draft;
    return draft;
  }

  Future<PlaylistDraft> _generate(
    LibraryCatalog catalog,
    String prompt,
    int songCount,
    void Function(String status)? onStatus,
  ) async {
    onStatus?.call('Understanding your request…');
    final plan = await model.plan(
      instructions: planInstructions,
      prompt: buildPlanPrompt(catalog, prompt),
    );

    onStatus?.call('Picking songs…');
    final ranked = rankSongs(catalog.songs, plan, random: _random);
    if (ranked.isEmpty) {
      throw GenerationException(
        'Nothing in your library matched that. Try describing it differently.',
      );
    }
    final focused = plan.artists.isNotEmpty && plan.artists.length <= 2;
    final candidates = diversify(
      ranked,
      limit: (songCount * 2).clamp(30, maxCandidates),
      perArtist: focused ? songCount : 4,
    );

    final chosen = <LibrarySong>[];
    if (candidates.length > songCount) {
      try {
        final numbers = await model.pick(
          instructions: pickInstructions,
          prompt: buildPickPrompt(prompt, candidates, songCount),
        );
        for (final n in numbers) {
          if (n < 1 || n > candidates.length) continue;
          final song = candidates[n - 1];
          if (!chosen.contains(song)) chosen.add(song);
        }
      } on Object {
        // Fall back to the ranking below.
      }
    }
    // Fill up to the requested length with the best-ranked songs left.
    for (final song in candidates) {
      if (chosen.length >= songCount) break;
      if (!chosen.contains(song)) chosen.add(song);
    }

    final songs = chosen.take(songCount).toList();
    return PlaylistDraft(
      name: plan.name.isEmpty ? 'New Playlist' : plan.name,
      description: plan.description,
      songs: songs,
      note: songs.length < songCount / 2
          ? 'Only ${songs.length} songs in your library fit this request.'
          : '',
    );
  }
}

const planInstructions =
    'You turn a request for a music playlist into search criteria for the '
    'listener\'s own music library. Only use genres from the listener\'s genre '
    'list. Prefer artists from the listener\'s artist list, and only name '
    'artists that clearly fit. Leave a list empty when it doesn\'t apply.';

const pickInstructions =
    'You are a music curator. From a numbered list of songs, choose the ones '
    'that best fit the playlist request, and put them in an order that flows '
    'well. Only use numbers from the list.';

/// The request plus a sample of what the library contains, so the model's
/// criteria use names that actually match.
String buildPlanPrompt(
  LibraryCatalog catalog,
  String prompt, {
  int maxGenres = 40,
  int maxArtists = 60,
}) {
  final genreCounts = <String, int>{};
  for (final song in catalog.songs) {
    if (song.primaryGenre case final genre?) {
      genreCounts[genre] = (genreCounts[genre] ?? 0) + 1;
    }
  }
  final genres = genreCounts.keys.toList()
    ..sort((a, b) => genreCounts[b]!.compareTo(genreCounts[a]!));
  final artists = [...catalog.artists]
    ..sort((a, b) {
      final byPlays = b.totalPlays.compareTo(a.totalPlays);
      return byPlays != 0 ? byPlays : b.songCount.compareTo(a.songCount);
    });

  return [
    'Request: $prompt',
    'Genres in the library: ${genres.take(maxGenres).join(', ')}',
    'Some artists in the library: '
        '${artists.take(maxArtists).map((a) => a.name).join(', ')}',
  ].join('\n\n');
}

String buildPickPrompt(
  String prompt,
  List<LibrarySong> candidates,
  int songCount,
) {
  final lines = [
    for (final (index, song) in candidates.indexed)
      '${index + 1}. ${_clip(song.title)} — ${song.artist}'
          '${_details(song)}',
  ];
  return 'Playlist request: $prompt\n'
      'Choose about $songCount songs.\n\n'
      '${lines.join('\n')}';
}

String _details(LibrarySong song) {
  final parts = [?song.primaryGenre, if (song.year != null) '${song.year}'];
  return parts.isEmpty ? '' : ' (${parts.join(', ')})';
}

String _clip(String text) =>
    text.length <= 60 ? text : '${text.substring(0, 57)}…';

/// Library songs that fit [plan], best first. Songs must match at least one
/// artist, genre or keyword when the plan names any; years and listening
/// habits then adjust the order.
List<LibrarySong> rankSongs(
  Iterable<LibrarySong> songs,
  OnDevicePlan plan, {
  Random? random,
}) {
  final artists = _normalized(plan.artists);
  final genres = _normalized(plan.genres);
  final keywords = _normalized(plan.keywords).where((k) => k.length >= 3);
  final needsMatch =
      artists.isNotEmpty || genres.isNotEmpty || keywords.isNotEmpty;
  final hasYears = plan.fromYear > 0 || plan.toYear > 0;
  final maxPlays = songs.fold(0, (m, s) => max(m, s.playCount));

  final scored = <(LibrarySong, double)>[];
  for (final song in songs) {
    var score = 0.0;
    var matched = false;

    final artist = _normalize(song.artist);
    if (artists.any((a) => _similar(a, artist))) {
      score += 4;
      matched = true;
    }
    final songGenres = song.genres.map(_normalize).where((g) => g != 'music');
    if (songGenres.any((g) => genres.any((x) => _similar(x, g)))) {
      score += 2;
      matched = true;
    }
    final text = _normalize('${song.title} ${song.album ?? ''}');
    final hits = keywords.where((k) => ' $text '.contains(' $k ')).length;
    if (hits > 0) {
      score += min(hits, 2).toDouble();
      matched = true;
    }
    if (needsMatch && !matched) continue;

    if (hasYears && song.year != null) {
      final from = plan.fromYear > 0 ? plan.fromYear : -1;
      final to = plan.toYear > 0 ? plan.toYear : 1 << 20;
      final inRange = song.year! >= from && song.year! <= to;
      if (!inRange && !needsMatch) continue;
      score += inRange ? 1.5 : -3;
    }

    switch (plan.listening) {
      case ListeningPreference.mostPlayed:
        if (maxPlays > 0) {
          score += 3 * log(1 + song.playCount) / log(1 + maxPlays);
        }
      case ListeningPreference.rarelyPlayed:
        score += song.playCount == 0
            ? 2
            : song.playCount <= 2
            ? 1
            : 0;
      case ListeningPreference.any:
        break;
    }

    // A little randomness so asking twice doesn't give identical playlists.
    score += (random?.nextDouble() ?? 0) * 0.5;
    if (needsMatch && score <= 0) continue;
    scored.add((song, score));
  }

  scored.sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final (song, _) in scored) song];
}

/// The first [limit] songs of [ranked], at most [perArtist] per artist unless
/// that would leave the list short.
List<LibrarySong> diversify(
  List<LibrarySong> ranked, {
  required int limit,
  required int perArtist,
}) {
  final perArtistCount = <String, int>{};
  final picked = <LibrarySong>[];
  final skipped = <LibrarySong>[];
  for (final song in ranked) {
    if (picked.length >= limit) break;
    final key = _normalize(song.artist);
    final count = perArtistCount[key] ?? 0;
    if (count >= perArtist) {
      skipped.add(song);
      continue;
    }
    perArtistCount[key] = count + 1;
    picked.add(song);
  }
  for (final song in skipped) {
    if (picked.length >= limit) break;
    picked.add(song);
  }
  return picked;
}

String _normalize(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'^the\s+'), '')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

Set<String> _normalized(List<String> values) =>
    {for (final v in values) _normalize(v)}..remove('');

/// Equal, or one contains the other as whole words ("rock" ~ "indie rock").
bool _similar(String a, String b) {
  if (a == b) return true;
  final (short, long) = a.length <= b.length ? (a, b) : (b, a);
  return short.length >= 3 && ' $long '.contains(' $short ');
}
