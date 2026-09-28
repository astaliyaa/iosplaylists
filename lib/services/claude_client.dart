import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Claude models offered in Settings.
enum ClaudeModel {
  opus5('claude-opus-5', 'Claude Opus 5', 'Best picks', 5),
  sonnet5('claude-sonnet-5', 'Claude Sonnet 5', 'Faster, 60% cheaper', 2),
  haiku45('claude-haiku-4-5', 'Claude Haiku 4.5', 'Fastest, 80% cheaper', 1);

  const ClaudeModel(this.id, this.label, this.blurb, this.inputUsdPerMTok);

  final String id;
  final String label;
  final String blurb;

  /// Standard input price in US dollars per million tokens.
  final double inputUsdPerMTok;

  static ClaudeModel fromId(String? id) =>
      values.firstWhere((m) => m.id == id, orElse: () => opus5);

  /// Haiku 4.5 rejects the `effort` setting.
  bool get supportsEffort => this != haiku45;

  /// Server-side refusal fallback (`fallbacks: "default"`) is offered for
  /// Claude Opus 5.
  bool get supportsDefaultFallback => this == opus5;
}

enum Effort { low, medium, high }

class ClaudeException implements Exception {
  ClaudeException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// A structured reply: the parsed JSON plus the raw assistant content, which
/// must be sent back unchanged to continue the conversation.
class ClaudeReply {
  const ClaudeReply({required this.json, required this.content, this.usage});

  final Map<String, dynamic> json;
  final List<dynamic> content;
  final Map<String, dynamic>? usage;
}

/// Something that answers a conversation with JSON matching a schema.
/// [ClaudeClient] is the real one; tests substitute fakes.
abstract class JsonModel {
  Future<ClaudeReply> createJson({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
  });
}

/// Minimal client for the Claude Messages API using structured outputs.
class ClaudeClient implements JsonModel {
  ClaudeClient({
    required this.apiKey,
    required this.model,
    this.effort = Effort.high,
    http.Client? httpClient,
    this.timeout = const Duration(minutes: 5),
    this.maxRetries = 2,
    this.retryDelay = const Duration(seconds: 2),
  }) : _http = httpClient ?? http.Client();

  static final Uri endpoint = Uri.parse(
    'https://api.anthropic.com/v1/messages',
  );

  final String apiKey;
  final ClaudeModel model;
  final Effort effort;
  final Duration timeout;
  final int maxRetries;
  final Duration retryDelay;
  final http.Client _http;

  /// Builds the request body. Visible for tests.
  @visibleForTesting
  Map<String, dynamic> buildBody({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
  }) => {
    'model': model.id,
    'max_tokens': 16000,
    'system': system,
    'messages': messages,
    'output_config': {
      'format': {'type': 'json_schema', 'schema': schema},
      if (model.supportsEffort) 'effort': effort.name,
    },
    if (model.supportsDefaultFallback) 'fallbacks': 'default',
  };

  @visibleForTesting
  Map<String, String> buildHeaders() => {
    'content-type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': '2023-06-01',
    if (model.supportsDefaultFallback)
      'anthropic-beta': 'server-side-fallback-2026-07-01',
    // Only needed when running in a browser (`flutter run -d chrome`).
    if (kIsWeb) 'anthropic-dangerous-direct-browser-access': 'true',
  };

  @override
  Future<ClaudeReply> createJson({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
  }) async {
    final body = jsonEncode(
      buildBody(system: system, messages: messages, schema: schema),
    );
    final response = await _postWithRetries(body);
    return parseResponse(response.statusCode, response.body);
  }

  Future<http.Response> _postWithRetries(String body) async {
    for (var attempt = 0; ; attempt++) {
      http.Response? response;
      Object? networkError;
      try {
        response = await _http
            .post(endpoint, headers: buildHeaders(), body: body)
            .timeout(timeout);
      } on TimeoutException {
        throw ClaudeException('Claude took too long to answer. Try again.');
      } on http.ClientException catch (error) {
        networkError = error;
      }

      final retryable =
          networkError != null ||
          response!.statusCode == 429 ||
          response.statusCode >= 500;
      if (!retryable || attempt >= maxRetries) {
        if (networkError != null) {
          throw ClaudeException(
            'Could not reach Claude. Check your connection. ($networkError)',
          );
        }
        return response!;
      }

      final retryAfter = int.tryParse(response?.headers['retry-after'] ?? '');
      await Future.delayed(
        retryAfter != null && retryAfter <= 30
            ? Duration(seconds: retryAfter)
            : retryDelay * (1 << attempt),
      );
    }
  }

  /// Turns an HTTP response into a [ClaudeReply] or a readable error.
  @visibleForTesting
  static ClaudeReply parseResponse(int statusCode, String body) {
    Map<String, dynamic>? decoded;
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map<String, dynamic>) decoded = parsed;
    } on FormatException {
      decoded = null;
    }

    if (statusCode != 200) {
      final error = decoded?['error'];
      final apiMessage = error is Map ? error['message'] as String? : null;
      throw ClaudeException(
        _describeHttpError(statusCode, apiMessage),
        statusCode: statusCode,
      );
    }
    if (decoded == null) {
      throw ClaudeException('Claude sent a response that could not be read.');
    }

    switch (decoded['stop_reason']) {
      case 'refusal':
        throw ClaudeException(
          'Claude declined this request. Try wording it differently.',
        );
      case 'max_tokens':
        throw ClaudeException(
          'Claude ran out of room before finishing. Try asking for fewer songs.',
        );
    }

    final content = _echoableContent(
      decoded['content'] as List<dynamic>? ?? const [],
    );
    final text = content
        .whereType<Map<String, dynamic>>()
        .where((block) => block['type'] == 'text')
        .map((block) => block['text'] as String)
        .join();
    try {
      return ClaudeReply(
        json: jsonDecode(text) as Map<String, dynamic>,
        content: content,
        usage: decoded['usage'] as Map<String, dynamic>?,
      );
    } on Object {
      throw ClaudeException('Claude replied in an unexpected format.');
    }
  }

  /// After a server-side fallback, blocks the declined model produced before
  /// the switch must not be echoed back: drop its thinking and tool blocks
  /// that precede the last `fallback` marker.
  static List<dynamic> _echoableContent(List<dynamic> content) {
    final lastFallback = content.lastIndexWhere(
      (block) => block is Map && block['type'] == 'fallback',
    );
    if (lastFallback < 0) return content;
    const dropped = {'thinking', 'redacted_thinking', 'tool_use'};
    return [
      for (final (index, block) in content.indexed)
        if (index > lastFallback ||
            !(block is Map && dropped.contains(block['type'])))
          block,
    ];
  }

  static String _describeHttpError(int statusCode, String? apiMessage) {
    final detail = apiMessage == null ? '' : ' ($apiMessage)';
    return switch (statusCode) {
      401 => 'Your Anthropic API key was rejected. Check it in Settings.',
      402 || 403 => 'Your Anthropic account can’t make this request$detail.',
      404 => 'That Claude model isn’t available to your account$detail.',
      413 => 'Your library is too large to send in one request.',
      429 => 'Claude is rate-limiting your key. Wait a minute and try again.',
      529 => 'Claude is overloaded right now. Try again shortly.',
      >= 500 => 'Claude had a server error. Try again shortly.',
      _ => 'Claude request failed ($statusCode)$detail.',
    };
  }
}
