import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'claude_client.dart';

/// Which AI builds the playlists.
enum Engine {
  /// Apple Intelligence on the iPhone: free and private.
  onDevice,

  /// Claude via the Anthropic API: better picks, paid per use.
  claude,
}

class Settings {
  const Settings({
    this.engine = Engine.onDevice,
    this.apiKey = '',
    this.model = ClaudeModel.opus5,
    this.effort = Effort.high,
  });

  final Engine engine;
  final String apiKey;
  final ClaudeModel model;
  final Effort effort;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  Settings copyWith({
    Engine? engine,
    String? apiKey,
    ClaudeModel? model,
    Effort? effort,
  }) => Settings(
    engine: engine ?? this.engine,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    effort: effort ?? this.effort,
  );
}

/// Persists settings in the iOS Keychain (browser storage on web).
class SettingsStore {
  SettingsStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _engine = 'engine';
  static const _apiKey = 'anthropic_api_key';
  static const _model = 'claude_model';
  static const _effort = 'claude_effort';

  final FlutterSecureStorage _storage;

  Future<Settings> load() async {
    final values = await _storage.readAll();
    return Settings(
      engine: Engine.values.firstWhere(
        (e) => e.name == values[_engine],
        orElse: () => Engine.onDevice,
      ),
      apiKey: values[_apiKey] ?? '',
      model: ClaudeModel.fromId(values[_model]),
      effort: Effort.values.firstWhere(
        (e) => e.name == values[_effort],
        orElse: () => Effort.high,
      ),
    );
  }

  Future<void> save(Settings settings) async {
    await _storage.write(key: _engine, value: settings.engine.name);
    await _storage.write(key: _apiKey, value: settings.apiKey.trim());
    await _storage.write(key: _model, value: settings.model.id);
    await _storage.write(key: _effort, value: settings.effort.name);
  }
}
