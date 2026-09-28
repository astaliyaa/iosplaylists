import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../services/claude_client.dart';
import '../services/library_catalog.dart';
import '../services/playlist_generator.dart';
import '../services/settings_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _apiKey;
  late Engine _engine;
  late ClaudeModel _model;
  late Effort _effort;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.settings;
    _engine = settings.engine;
    _apiKey = TextEditingController(text: settings.apiKey);
    _model = settings.model;
    _effort = settings.effort;
  }

  @override
  void dispose() {
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.controller.saveSettings(
        widget.controller.settings.copyWith(
          engine: _engine,
          apiKey: _apiKey.text.trim(),
          model: _model,
          effort: _effort,
        ),
      );
      navigator.pop();
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn’t save: $error')));
    }
  }

  String? _costHint() {
    final songs = widget.controller.songs;
    if (songs == null || songs.isEmpty) return null;
    final tokens = LibraryCatalog.estimateTokens(
      widget.controller.catalog(allowExplicit: true).renderSongs(),
    );
    const budget = PlaylistGenerator.defaultFullCatalogTokenBudget;
    final sent = tokens > budget ? budget : tokens;
    // Cache writes cost 1.25× the base input price.
    final dollars = sent * 1.25 * _model.inputUsdPerMTok / 1e6;
    final size = '${(tokens / 1000).round()}k';
    final large = tokens > budget
        ? ' It’s large, so Claude first shortlists artists and only sees '
              'their songs.'
        : '';
    return 'Your library listing is about $size tokens.$large '
        'A new playlist costs roughly \$${dollars.toStringAsFixed(2)} in input '
        'with ${_model.label}; refining within 5 minutes reuses the cached '
        'listing and costs much less.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final costHint = _costHint();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Who picks the songs', style: theme.textTheme.titleMedium),
          _option(
            selected: _engine == Engine.onDevice,
            title: 'Apple Intelligence (free)',
            subtitle:
                widget.controller.onDeviceStatus.problem ??
                'Runs privately on this iPhone. Simpler picks: it can’t see '
                    'your whole library at once.',
            onTap: () => setState(() => _engine = Engine.onDevice),
          ),
          _option(
            selected: _engine == Engine.claude,
            title: 'Claude (paid)',
            subtitle:
                'Best picks: reads your whole library. Needs an Anthropic API '
                'key; roughly 5–40¢ per new playlist.',
            onTap: () => setState(() => _engine = Engine.claude),
          ),
          if (_engine == Engine.claude) ..._claudeSettings(theme, costHint),
        ],
      ),
    );
  }

  Widget _option({
    required bool selected,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? theme.colorScheme.primary : null,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }

  List<Widget> _claudeSettings(ThemeData theme, String? costHint) => [
    const SizedBox(height: 24),
    TextField(
      controller: _apiKey,
      obscureText: !_showKey,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: 'Anthropic API key',
        hintText: 'sk-ant-…',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          tooltip: _showKey ? 'Hide key' : 'Show key',
          icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _showKey = !_showKey),
        ),
      ),
    ),
    const SizedBox(height: 8),
    Text(
      'Create one at console.anthropic.com › API Keys. It’s stored in '
      'the Keychain on this device and only sent to api.anthropic.com.',
      style: theme.textTheme.bodySmall,
    ),
    const SizedBox(height: 24),
    Text('Model', style: theme.textTheme.titleMedium),
    for (final model in ClaudeModel.values)
      _option(
        selected: model == _model,
        title: model.label,
        subtitle: model.blurb,
        onTap: () => setState(() => _model = model),
      ),
    const SizedBox(height: 16),
    Text('Thinking effort', style: theme.textTheme.titleMedium),
    const SizedBox(height: 8),
    SegmentedButton<Effort>(
      segments: const [
        ButtonSegment(value: Effort.low, label: Text('Low')),
        ButtonSegment(value: Effort.medium, label: Text('Medium')),
        ButtonSegment(value: Effort.high, label: Text('High')),
      ],
      selected: {_effort},
      onSelectionChanged: _model.supportsEffort
          ? (selection) => setState(() => _effort = selection.first)
          : null,
    ),
    const SizedBox(height: 8),
    Text(
      _model.supportsEffort
          ? 'Lower effort answers faster and costs less; higher effort '
                'thinks harder about each pick.'
          : '${_model.label} doesn’t use this setting.',
      style: theme.textTheme.bodySmall,
    ),
    if (costHint != null) ...[
      const SizedBox(height: 24),
      Text('Cost', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      Text(costHint, style: theme.textTheme.bodyMedium),
    ],
  ];
}
