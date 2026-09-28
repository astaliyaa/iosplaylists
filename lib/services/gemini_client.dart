import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'json_model.dart';

/// Gemini models offered in Settings. Any other model ID can be typed in.
enum GeminiModel {
  flash('gemini-3.8-flash', 'Gemini 3.8 Flash', 'Best free picks'),
  flashLite(
    'gemini-3.5-flash-lite',
    'Gemini 3.5 Flash-Lite',
    'Faster, simpler',
  );

  const GeminiModel(this.id, this.label, this.blurb);

  final String id;
  final String label;
  final String blurb;

  static const defaultId = 'gemini-3.8-flash';
}

class GeminiException extends ApiException {
  GeminiException(super.message, {super.statusCode});
}

/// Minimal client for the Gemini API (`models.generateContent`) with JSON
/// output. Accepts the Claude-shaped conversation [JsonModel] uses and
/// translates it.
class GeminiClient implements JsonModel {
  GeminiClient({
    required this.apiKey,
    this.model = GeminiModel.defaultId,
    http.Client? httpClient,
    this.timeout = const Duration(minutes: 5),
    this.maxRetries = 2,
    this.retryDelay = const Duration(seconds: 2),
  }) : _http = httpClient ?? http.Client();

  final String apiKey;
  final String model;
  final Duration timeout;
  final int maxRetries;
  final Duration retryDelay;
  final http.Client _http;

  Uri get endpoint => Uri.https(
    'generativelanguage.googleapis.com',
    '/v1beta/models/${Uri.encodeComponent(model)}:generateContent',
  );

  @visibleForTesting
  Map<String, dynamic> buildBody({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
  }) => {
    'systemInstruction': {
      'parts': [
        {'text': system},
      ],
    },
    'contents': [
      for (final message in messages)
        {
          'role': message['role'] == 'assistant' ? 'model' : 'user',
          'parts': _parts(message['content']),
        },
    ],
    'generationConfig': {
      'responseMimeType': 'application/json',
      'responseSchema': toGeminiSchema(schema),
    },
  };

  @visibleForTesting
  Map<String, String> buildHeaders() => {
    'content-type': 'application/json',
    'x-goog-api-key': apiKey,
  };

  @override
  Future<ModelReply> createJson({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
  }) async {
    final response = await postWithRetries(
      client: _http,
      url: endpoint,
      headers: buildHeaders(),
      body: jsonEncode(
        buildBody(system: system, messages: messages, schema: schema),
      ),
      serviceName: 'Gemini',
      timeout: timeout,
      maxRetries: maxRetries,
      retryDelay: retryDelay,
      error: GeminiException.new,
      // A 429 means a free-tier quota is used up; retrying right away won't
      // help.
      retryWhen: (r) => r.statusCode >= 500,
    );
    return parseResponse(response.statusCode, response.body, model: model);
  }

  /// Claude-style content (a string or text blocks) becomes Gemini parts.
  /// Earlier Gemini replies are already parts and pass through unchanged,
  /// keeping any thought signatures Gemini needs to continue the chat.
  static List<dynamic> _parts(Object? content) {
    if (content is String) {
      return [
        {'text': content},
      ];
    }
    return [
      for (final block in content as List<dynamic>)
        if (block is Map && block['type'] == 'text')
          {'text': block['text']}
        else
          block,
    ];
  }

  /// Converts a JSON Schema to the OpenAPI-style subset `responseSchema`
  /// takes: upper-case types and no `additionalProperties`.
  @visibleForTesting
  static Map<String, dynamic> toGeminiSchema(Map<String, dynamic> schema) => {
    for (final MapEntry(:key, :value) in schema.entries)
      if (key != 'additionalProperties')
        key: switch (key) {
          'type' => (value as String).toUpperCase(),
          'items' => toGeminiSchema(value as Map<String, dynamic>),
          'properties' => {
            for (final p in (value as Map<String, dynamic>).entries)
              p.key: toGeminiSchema(p.value as Map<String, dynamic>),
          },
          _ => value,
        },
  };

  @visibleForTesting
  static ModelReply parseResponse(
    int statusCode,
    String body, {
    String model = GeminiModel.defaultId,
  }) {
    Map<String, dynamic>? decoded;
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map<String, dynamic>) decoded = parsed;
    } on FormatException {
      decoded = null;
    }

    if (statusCode != 200) {
      final error = decoded?['error'];
      final message = error is Map ? '${error['message'] ?? ''}' : '';
      throw GeminiException(
        _describeHttpError(statusCode, message, model),
        statusCode: statusCode,
      );
    }
    if (decoded == null) {
      throw GeminiException('Gemini sent a response that could not be read.');
    }

    final blocked = decoded['promptFeedback']?['blockReason'];
    final candidates = decoded['candidates'] as List<dynamic>? ?? const [];
    if (blocked != null || candidates.isEmpty) {
      throw GeminiException(
        'Gemini declined this request. Try wording it differently.',
      );
    }
    final candidate = candidates.first as Map<String, dynamic>;
    switch (candidate['finishReason']) {
      case 'MAX_TOKENS':
        throw GeminiException(
          'Gemini ran out of room before finishing. Try asking for fewer '
          'songs.',
        );
      case 'SAFETY' ||
          'PROHIBITED_CONTENT' ||
          'BLOCKLIST' ||
          'SPII' ||
          'RECITATION':
        throw GeminiException(
          'Gemini declined this request. Try wording it differently.',
        );
    }

    final parts =
        (candidate['content'] as Map<String, dynamic>?)?['parts']
            as List<dynamic>? ??
        const [];
    final text = parts
        .whereType<Map<String, dynamic>>()
        .where((part) => part['thought'] != true && part['text'] is String)
        .map((part) => part['text'] as String)
        .join();
    try {
      return ModelReply(
        json: jsonDecode(text) as Map<String, dynamic>,
        content: parts,
        usage: decoded['usageMetadata'] as Map<String, dynamic>?,
      );
    } on Object {
      throw GeminiException('Gemini replied in an unexpected format.');
    }
  }

  static String _describeHttpError(int status, String message, String model) {
    final lower = message.toLowerCase();
    if (lower.contains('api key')) {
      return 'Your Gemini API key was rejected. Check it in Settings.';
    }
    if (lower.contains('location is not supported')) {
      return 'Gemini’s API isn’t available in your country.';
    }
    final detail = message.isEmpty ? '' : ' ($message)';
    return switch (status) {
      403 => 'Your Gemini key can’t use this model$detail.',
      404 =>
        'The Gemini model “$model” isn’t available. Pick another one in '
            'Settings.',
      429 =>
        'You’ve hit Gemini’s free-tier limit. Wait a minute and try again, '
            'or try tomorrow if it’s the daily limit.',
      503 => 'Gemini is overloaded right now. Try again shortly.',
      >= 500 => 'Gemini had a server error. Try again shortly.',
      _ => 'Gemini request failed ($status)$detail.',
    };
  }
}
