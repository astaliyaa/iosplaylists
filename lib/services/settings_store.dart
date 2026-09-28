import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'claude_client.dart';
import 'gemini_client.dart';

/// Which AI builds the playlists.
enum Engine {
  /// Apple Intelligence on the iPhone: free and private.
  onDevice,

  /// Gemini via Google's API: reads the whole library, free with limits.
  gemini,

  /// Claude via the Anthropic API: better picks, paid per use.
  claude,
}

class Settings {
  const Settings({
    this.engine = Engine.onDevice,
    this.apiKey = '',
    this.model = ClaudeModel.opus5,
    this.effort = Effort.high,
    this.geminiApiKey = '',
    this.geminiModel = GeminiModel.defaultId,
  });

  final Engine engine;

  /// Anthropic API key, for Claude.
  final String apiKey;
  final ClaudeModel model;
  final Effort effort;

  final String geminiApiKey;
  final String geminiModel;

  bool get hasApiKey => apiKey.trim().isNotEmpty;
  bool get hasGeminiApiKey => geminiApiKey.trim().isNotEmpty;

  Settings copyWith({
    Engine? engine,
    String? apiKey,
    ClaudeModel? model,
    Effort? effort,
    String? geminiApiKey,
    String? geminiModel,
  }) => Settings(
    engine: engine ?? this.engine,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    effort: effort ?? this.effort,
    geminiApiKey: geminiApiKey ?? this.geminiApiKey,
    geminiModel: geminiModel ?? this.geminiModel,
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
  static const _geminiApiKey = 'gemini_api_key';
  static const _geminiModel = 'gemini_model';

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
      geminiApiKey: values[_geminiApiKey] ?? '',
      geminiModel: (values[_geminiModel] ?? '').trim().isEmpty
          ? GeminiModel.defaultId
          : values[_geminiModel]!.trim(),
    );
  }

  Future<void> save(Settings settings) async {
    await _storage.write(key: _engine, value: settings.engine.name);
    await _storage.write(key: _apiKey, value: settings.apiKey.trim());
    await _storage.write(key: _model, value: settings.model.id);
    await _storage.write(key: _effort, value: settings.effort.name);
    await _storage.write(
      key: _geminiApiKey,
      value: settings.geminiApiKey.trim(),
    );
    await _storage.write(key: _geminiModel, value: settings.geminiModel.trim());
  }
}
