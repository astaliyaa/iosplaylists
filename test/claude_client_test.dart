import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:promptlist/services/claude_client.dart';

const schema = {
  'type': 'object',
  'properties': {
    'ok': {'type': 'boolean'},
  },
  'required': ['ok'],
  'additionalProperties': false,
};

String reply(List<Map<String, dynamic>> content, {String stop = 'end_turn'}) =>
    jsonEncode({
      'type': 'message',
      'role': 'assistant',
      'content': content,
      'stop_reason': stop,
      'usage': {'input_tokens': 10, 'output_tokens': 5},
    });

void main() {
  const messages = [
    {'role': 'user', 'content': 'hi'},
  ];

  test('Opus 5 requests use structured output, effort and fallbacks', () {
    final client = ClaudeClient(
      apiKey: 'key',
      model: ClaudeModel.opus5,
      effort: Effort.medium,
    );

    final body = client.buildBody(
      system: 'sys',
      messages: messages,
      schema: schema,
    );
    expect(body['model'], 'claude-opus-5');
    expect(body['fallbacks'], 'default');
    expect(body['output_config'], {
      'format': {'type': 'json_schema', 'schema': schema},
      'effort': 'medium',
    });
    expect(body.containsKey('thinking'), isFalse);
    expect(
      client.buildHeaders()['anthropic-beta'],
      'server-side-fallback-2026-07-01',
    );
  });

  test('Haiku requests leave out effort and fallbacks', () {
    final client = ClaudeClient(apiKey: 'key', model: ClaudeModel.haiku45);

    final body = client.buildBody(
      system: 'sys',
      messages: messages,
      schema: schema,
    );
    expect(body['output_config'], {
      'format': {'type': 'json_schema', 'schema': schema},
    });
    expect(body.containsKey('fallbacks'), isFalse);
    expect(client.buildHeaders().containsKey('anthropic-beta'), isFalse);
  });

  test('parses JSON from text blocks and keeps content for replay', () {
    final parsed = ClaudeClient.parseResponse(
      200,
      reply([
        {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
        {'type': 'text', 'text': '{"ok":'},
        {'type': 'text', 'text': 'true}'},
      ]),
    );

    expect(parsed.json, {'ok': true});
    expect(parsed.content, hasLength(3));
  });

  test('drops the declined model\'s blocks before a fallback marker', () {
    final parsed = ClaudeClient.parseResponse(
      200,
      reply([
        {'type': 'thinking', 'thinking': '', 'signature': 'a'},
        {
          'type': 'fallback',
          'from': {'model': 'claude-opus-5'},
          'to': {'model': 'claude-opus-4-8'},
        },
        {'type': 'thinking', 'thinking': '', 'signature': 'b'},
        {'type': 'text', 'text': '{"ok":true}'},
      ]),
    );

    expect(parsed.content.map((b) => (b as Map)['type']), [
      'fallback',
      'thinking',
      'text',
    ]);
  });

  test('turns refusals, truncation and HTTP errors into messages', () {
    expect(
      () => ClaudeClient.parseResponse(200, reply([], stop: 'refusal')),
      throwsA(
        isA<ClaudeException>().having(
          (e) => e.message,
          'message',
          contains('declined'),
        ),
      ),
    );
    expect(
      () => ClaudeClient.parseResponse(200, reply([], stop: 'max_tokens')),
      throwsA(isA<ClaudeException>()),
    );
    expect(
      () => ClaudeClient.parseResponse(
        401,
        jsonEncode({
          'type': 'error',
          'error': {'type': 'authentication_error', 'message': 'bad key'},
        }),
      ),
      throwsA(
        isA<ClaudeException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.message, 'message', contains('API key')),
      ),
    );
    expect(
      () => ClaudeClient.parseResponse(
        200,
        reply([
          {'type': 'text', 'text': 'not json'},
        ]),
      ),
      throwsA(isA<ClaudeException>()),
    );
  });

  test('retries overloaded responses, then succeeds', () async {
    var calls = 0;
    late http.Request lastRequest;
    final client = ClaudeClient(
      apiKey: 'secret',
      model: ClaudeModel.sonnet5,
      retryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        calls++;
        lastRequest = request;
        if (calls == 1) return http.Response('{"type":"error"}', 529);
        return http.Response(
          reply([
            {'type': 'text', 'text': '{"ok":true}'},
          ]),
          200,
        );
      }),
    );

    final result = await client.createJson(
      system: 'sys',
      messages: messages,
      schema: schema,
    );

    expect(result.json, {'ok': true});
    expect(calls, 2);
    expect(lastRequest.headers['x-api-key'], 'secret');
    expect(lastRequest.headers['anthropic-version'], '2023-06-01');
    expect(jsonDecode(lastRequest.body)['model'], 'claude-sonnet-5');
  });

  test('does not retry client errors', () async {
    var calls = 0;
    final client = ClaudeClient(
      apiKey: 'secret',
      model: ClaudeModel.opus5,
      retryDelay: Duration.zero,
      httpClient: MockClient((_) async {
        calls++;
        return http.Response('{}', 400);
      }),
    );

    await expectLater(
      client.createJson(system: 's', messages: messages, schema: schema),
      throwsA(isA<ClaudeException>()),
    );
    expect(calls, 1);
  });
}
