import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../models/library_song.dart';
import '../services/playlist_generator.dart';

const _refineIdeas = [
  'More upbeat',
  'Mellower',
  'Fewer obvious hits',
  'Add more variety',
  'Make it longer',
];

/// Shows a generated playlist for editing, refining and saving.
class DraftPage extends StatefulWidget {
  const DraftPage({
    super.key,
    required this.controller,
    required this.generator,
    required this.session,
  });

  final AppController controller;
  final PlaylistGenerator generator;
  final PlaylistSession session;

  @override
  State<DraftPage> createState() => _DraftPageState();
}

class _DraftPageState extends State<DraftPage> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  List<LibrarySong> _songs = [];
  String _note = '';
  String? _busyLabel;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _apply(widget.session.draft);
    _name.addListener(_markEdited);
    _description.addListener(_markEdited);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _apply(PlaylistDraft draft) {
    _saved = false;
    _name.text = draft.name;
    _description.text = draft.description;
    _songs = [...draft.songs];
    _note = draft.note;
  }

  void _markEdited() {
    if (_saved) setState(() => _saved = false);
  }

  PlaylistDraft get _current => PlaylistDraft(
    name: _name.text.trim().isEmpty ? 'New Playlist' : _name.text.trim(),
    description: _description.text.trim(),
    songs: _songs,
  );

  Future<void> _refine() async {
    final feedback = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _RefineSheet(),
    );
    if (feedback == null || feedback.trim().isEmpty || !mounted) return;

    setState(() => _busyLabel = 'Updating playlist…');
    try {
      final draft = await widget.generator.refine(
        session: widget.session,
        current: _current,
        feedback: feedback,
      );
      if (mounted) setState(() => _apply(draft));
    } on Object catch (error) {
      if (mounted) _snack('$error');
    } finally {
      if (mounted) setState(() => _busyLabel = null);
    }
  }

  Future<void> _save() async {
    final draft = _current;
    setState(() => _busyLabel = 'Saving to Apple Music…');
    try {
      await widget.controller.savePlaylist(draft);
      if (!mounted) return;
      setState(() => _saved = true);
      _snack(
        widget.controller.library.isDemo
            ? 'Demo mode: “${draft.name}” wasn’t really saved.'
            : 'Saved “${draft.name}” to your library.',
      );
    } on Object catch (error) {
      if (mounted) _snack('Couldn’t save: $error');
    } finally {
      if (mounted) setState(() => _busyLabel = null);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  String get _summary {
    final count = '${_songs.length} ${_songs.length == 1 ? 'song' : 'songs'}';
    final seconds = _songs.fold<int>(0, (t, s) => t + (s.durationSeconds ?? 0));
    if (seconds == 0) return count;
    final minutes = (seconds / 60).round();
    final length = minutes >= 60
        ? '${minutes ~/ 60} hr ${minutes % 60} min'
        : '$minutes min';
    return '$count · $length';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _busyLabel != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Preview')),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        header: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                style: theme.textTheme.headlineSmall,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: _description,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              if (_note.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  color: theme.colorScheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_note),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '$_summary · swipe to remove, hold to reorder',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        itemCount: _songs.length,
        onReorderItem: (from, to) => setState(() {
          _songs.insert(to, _songs.removeAt(from));
          _saved = false;
        }),
        itemBuilder: (context, index) {
          final song = _songs[index];
          return Dismissible(
            key: ValueKey(song.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              color: theme.colorScheme.errorContainer,
              child: Icon(
                Icons.delete_outline,
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            onDismissed: (_) => setState(() {
              _songs.removeAt(index);
              _saved = false;
            }),
            child: ListTile(
              title: Text(
                song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [song.artist, if (song.album != null) song.album].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: busy
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(_busyLabel!),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.tune),
                        label: const Text('Refine'),
                        onPressed: _refine,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        icon: Icon(_saved ? Icons.check : Icons.playlist_add),
                        label: Text(_saved ? 'Saved' : 'Save to Music'),
                        onPressed: _saved || _songs.isEmpty ? null : _save,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _RefineSheet extends StatefulWidget {
  const _RefineSheet();

  @override
  State<_RefineSheet> createState() => _RefineSheetState();
}

class _RefineSheetState extends State<_RefineSheet> {
  final _feedback = TextEditingController();

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_feedback.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _feedback,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'What should change?',
              hintText: 'e.g. Less rap, more 90s, end on something calm',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final idea in _refineIdeas)
                ActionChip(
                  label: Text(idea),
                  onPressed: () => _feedback.text = idea,
                ),
            ],
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder(
            valueListenable: _feedback,
            builder: (context, value, _) => FilledButton(
              onPressed: value.text.trim().isEmpty ? null : _submit,
              child: const Text('Update playlist'),
            ),
          ),
        ],
      ),
    );
  }
}
