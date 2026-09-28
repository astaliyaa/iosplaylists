import 'dart:async';

import 'package:http/http.dart' as http;

/// A structured reply: the parsed JSON plus the raw assistant content, which
/// must be sent back unchanged to continue the conversation.
class ModelReply {
  const ModelReply({required this.json, required this.content, this.usage});

  final Map<String, dynamic> json;
  final List<dynamic> content;
  final Map<String, dynamic>? usage;
}

/// Something that answers a conversation with JSON matching a schema.
///
/// Messages use the Claude Messages API shape: `{role: user|assistant,
/// content: String | [{type: text, text: ...}, ...]}`; assistant turns carry
/// a previous [ModelReply.content] unchanged.
abstract class JsonModel {
  Future<ModelReply> createJson({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
  });
}

/// An error from an AI service, with a message fit to show the user.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// POSTs [body], retrying network errors and responses matching [retryWhen]
/// (by default 429 and 5xx) with exponential backoff.
Future<http.Response> postWithRetries({
  required http.Client client,
  required Uri url,
  required Map<String, String> headers,
  required String body,
  required String serviceName,
  required Duration timeout,
  required int maxRetries,
  required Duration retryDelay,
  required ApiException Function(String message) error,
  bool Function(http.Response response)? retryWhen,
}) async {
  final shouldRetry =
      retryWhen ?? (r) => r.statusCode == 429 || r.statusCode >= 500;
  for (var attempt = 0; ; attempt++) {
    http.Response? response;
    Object? networkError;
    try {
      response = await client
          .post(url, headers: headers, body: body)
          .timeout(timeout);
    } on TimeoutException {
      throw error('$serviceName took too long to answer. Try again.');
    } on http.ClientException catch (e) {
      networkError = e;
    }

    final retryable = networkError != null || shouldRetry(response!);
    if (!retryable || attempt >= maxRetries) {
      if (networkError != null) {
        throw error(
          'Could not reach $serviceName. Check your connection. '
          '($networkError)',
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
