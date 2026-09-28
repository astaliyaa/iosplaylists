import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../services/music_library.dart';
import '../services/settings_store.dart';
import 'draft_page.dart';
import 'settings_page.dart';

const _ideas = [
  'Late-night drive: synthy, moody, a bit cinematic',
  'Sunday morning coffee — acoustic and mellow',
  'High-energy gym mix from my most played songs',
  'Deep cuts I’ve barely listened to',
  'Songs that sound like the end of summer',
];

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _prompt = TextEditingController();
  double _songCount = 25;
  bool _allowExplicit = true;
  bool _busy = false;
  String _status = '';

  AppController get _controller => widget.controller;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _status = 'Reading your library…';
    });
    try {
      final generator = _controller.newGenerator();
      final session = await generator.generate(
        catalog: _controller.catalog(allowExplicit: _allowExplicit),
        prompt: _prompt.text,
        songCount: _songCount.round(),
        onStatus: (status) {
          if (mounted) setState(() => _status = status);
        },
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DraftPage(
            controller: _controller,
            generator: generator,
            session: session,
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) _showError('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(controller: _controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final settings = _controller.settings;
        final problem = _controller.engineProblem;
        final ready =
            problem == null && (_controller.songs?.isNotEmpty ?? false);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Promptlist'),
            actions: [
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: _openSettings,
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _LibraryCard(controller: _controller),
                if (problem != null)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        settings.engine == Engine.claude
                            ? Icons.key_outlined
                            : Icons.phone_iphone,
                      ),
                      title: Text(
                        settings.engine == Engine.claude
                            ? 'Add your Anthropic API key'
                            : 'Free mode isn’t available',
                      ),
                      subtitle: Text(
                        settings.engine == Engine.claude
                            ? 'Claude picks the songs, so it needs a key. Or '
                                  'switch to the free on-device mode.'
                            : '$problem You can use Claude instead in '
                                  'Settings.',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _openSettings,
                    ),
                  ),
                const SizedBox(height: 16),
                TextField(
                  controller: _prompt,
                  minLines: 3,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'What should the playlist be?',
                    hintText:
                        'e.g. Rainy afternoon reading — calm, instrumental-ish, '
                        'nothing too sad',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final idea in _ideas)
                      ActionChip(
                        label: Text(idea),
                        onPressed: () => _prompt.text = idea,
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'About ${_songCount.round()} songs',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Slider(
                  value: _songCount,
                  min: 10,
                  max: 100,
                  divisions: 18,
                  label: '${_songCount.round()}',
                  onChanged: (value) => setState(() => _songCount = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include explicit songs'),
                  value: _allowExplicit,
                  onChanged: (value) => setState(() => _allowExplicit = value),
                ),
                const SizedBox(height: 16),
                if (_busy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(_status, textAlign: TextAlign.center),
                ] else
                  ValueListenableBuilder(
                    valueListenable: _prompt,
                    builder: (context, value, _) => FilledButton.icon(
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('Create playlist'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: ready && value.text.trim().isNotEmpty
                          ? _generate
                          : null,
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  settings.engine == Engine.claude
                      ? 'Using ${settings.model.label}'
                      : 'Using Apple Intelligence on this iPhone (free)',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LibraryCard extends StatelessWidget {
  const _LibraryCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.loadingLibrary) {
      return const Card(
        child: ListTile(
          leading: SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          title: Text('Loading your library…'),
        ),
      );
    }

    if (controller.libraryError case final error?) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: const Text('Couldn’t read your library'),
          subtitle: Text(error),
          trailing: TextButton(
            onPressed: controller.access == MusicAccess.authorized
                ? controller.reloadLibrary
                : controller.connectLibrary,
            child: const Text('Retry'),
          ),
        ),
      );
    }

    switch (controller.access) {
      case MusicAccess.authorized:
        final count = controller.songs?.length ?? 0;
        return Card(
          child: ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: Text(
              controller.library.isDemo
                  ? '$count sample songs'
                  : '$count songs in your library',
            ),
            subtitle: controller.library.isDemo
                ? const Text('Demo library — Apple Music is only on iPhone')
                : null,
            trailing: IconButton(
              tooltip: 'Reload library',
              icon: const Icon(Icons.refresh),
              onPressed: controller.reloadLibrary,
            ),
          ),
        );
      case MusicAccess.denied:
      case MusicAccess.restricted:
        return const Card(
          child: ListTile(
            leading: Icon(Icons.lock_outline),
            title: Text('Apple Music access is off'),
            subtitle: Text(
              'Turn it on in the Settings app › Apps › Promptlist › '
              'Media & Apple Music, then reopen Promptlist.',
            ),
          ),
        );
      case MusicAccess.notDetermined:
      case null:
        return Card(
          child: ListTile(
            leading: const Icon(Icons.library_music_outlined),
            title: const Text('Connect Apple Music'),
            subtitle: const Text('Needed to see which songs you have.'),
            trailing: FilledButton(
              onPressed: controller.connectLibrary,
              child: const Text('Connect'),
            ),
          ),
        );
    }
  }
}
