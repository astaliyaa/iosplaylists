import '../models/library_song.dart';
import 'library_catalog.dart';

class PlaylistDraft {
  const PlaylistDraft({
    required this.name,
    required this.description,
    required this.songs,
    this.note = '',
  });

  final String name;
  final String description;
  final List<LibrarySong> songs;

  /// Optional remark for the listener, e.g. that the library ran short.
  final String note;
}

class GenerationException implements Exception {
  GenerationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A generated playlist plus what's needed to refine it later.
class PlaylistSession {
  PlaylistSession({
    required this.catalog,
    required this.prompt,
    required this.songCount,
    required this.draft,
    this.state,
  });

  final LibraryCatalog catalog;

  /// The request so far, including any refinements.
  String prompt;
  final int songCount;
  PlaylistDraft draft;

  /// Engine-specific state, e.g. Claude's conversation so far.
  final Object? state;
}

/// Something that turns a prompt into a playlist from the user's library.
abstract class PlaylistEngine {
  Future<PlaylistSession> generate({
    required LibraryCatalog catalog,
    required String prompt,
    required int songCount,
    void Function(String status)? onStatus,
  });

  /// Revises [session]'s playlist. [current] is the playlist as the user sees
  /// it now, including any songs they removed or reordered by hand.
  Future<PlaylistDraft> refine({
    required PlaylistSession session,
    required PlaylistDraft current,
    required String feedback,
  });
}
