import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:promptlist/services/gemini_client.dart';
import 'package:promptlist/services/playlist_generator.dart';

String reply(List<Map<String, dynamic>> parts, {String finish = 'STOP'}) =>
    jsonEncode({
      'candidates': [
        {
          'content': {'role': 'model', 'parts': parts},
          'finishReason': finish,
        },
      ],
      'usageMetadata': {'promptTokenCount': 10},
    });

String error(int code, String status, String message) => jsonEncode({
  'error': {'code': code, 'status': status, 'message': message},
});

void main() {
  test('translates the conversation into a generateContent request', () {
    final client = GeminiClient(apiKey: 'key');
    final previous = [
      {'text': '{"name":"A"}', 'thoughtSignature': 'sig'},
    ];

    final body = client.buildBody(
      system: 'sys',
      messages: [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': 'library',
              'cache_control': {'type': 'ephemeral'},
            },
            {'type': 'text', 'text': 'request'},
          ],
        },
        {'role': 'assistant', 'content': previous},
        {'role': 'user', 'content': 'feedback'},
      ],
      schema: playlistSchema,
    );

    expect(body['systemInstruction'], {
      'parts': [
        {'text': 'sys'},
      ],
    });
    expect(body['contents'], [
      {
        'role': 'user',
        'parts': [
          {'text': 'library'},
          {'text': 'request'},
        ],
      },
      {'role': 'model', 'parts': previous},
      {
        'role': 'user',
        'parts': [
          {'text': 'feedback'},
        ],
      },
    ]);
    expect(body['generationConfig'], {
      'responseMimeType': 'application/json',
      'responseSchema': {
        'type': 'OBJECT',
        'properties': {
          'name': {'type': 'STRING'},
          'description': {'type': 'STRING'},
          'song_ids': {
            'type': 'ARRAY',
            'items': {'type': 'INTEGER'},
          },
          'note': {'type': 'STRING'},
        },
        'required': ['name', 'description', 'song_ids', 'note'],
      },
    });
    expect(client.buildHeaders()['x-goog-api-key'], 'key');
    expect(
      client.endpoint.toString(),
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'gemini-3.8-flash:generateContent',
    );
  });

  test('reads JSON from non-thought parts and keeps parts for replay', () {
    final parsed = GeminiClient.parseResponse(
      200,
      reply([
        {'text': 'thinking…', 'thought': true},
        {'text': '{"ok":', 'thoughtSignature': 'sig'},
        {'text': 'true}'},
      ]),
    );

    expect(parsed.json, {'ok': true});
    expect(parsed.content, hasLength(3));
    expect((parsed.content[1] as Map)['thoughtSignature'], 'sig');
  });

  test('turns blocks, truncation and HTTP errors into messages', () {
    Matcher failsWith(String text) => throwsA(
      isA<GeminiException>().having(
        (e) => e.message,
        'message',
        contains(text),
      ),
    );

    expect(
      () => GeminiClient.parseResponse(
        200,
        jsonEncode({
          'promptFeedback': {'blockReason': 'SAFETY'},
        }),
      ),
      failsWith('declined'),
    );
    expect(
      () => GeminiClient.parseResponse(200, reply([], finish: 'MAX_TOKENS')),
      failsWith('ran out of room'),
    );
    expect(
      () => GeminiClient.parseResponse(
        400,
        error(
          400,
          'INVALID_ARGUMENT',
          'API key not valid. Please pass a valid API key.',
        ),
      ),
      failsWith('API key was rejected'),
    );
    expect(
      () => GeminiClient.parseResponse(
        400,
        error(
          400,
          'FAILED_PRECONDITION',
          'User location is not supported for the API use.',
        ),
      ),
      failsWith('isn’t available in your country'),
    );
    expect(
      () => GeminiClient.parseResponse(
        404,
        error(404, 'NOT_FOUND', 'models/gemini-9 is not found'),
        model: 'gemini-9',
      ),
      failsWith('“gemini-9” isn’t available'),
    );
    expect(
      () => GeminiClient.parseResponse(
        429,
        error(429, 'RESOURCE_EXHAUSTED', 'Quota exceeded'),
      ),
      failsWith('free-tier limit'),
    );
    expect(
      () => GeminiClient.parseResponse(
        200,
        reply([
          {'text': 'not json'},
        ]),
      ),
      failsWith('unexpected format'),
    );
  });

  test('retries server errors but not quota errors', () async {
    var calls = 0;
    final retrying = GeminiClient(
      apiKey: 'k',
      model: 'gemini-3.5-flash-lite',
      retryDelay: Duration.zero,
      httpClient: MockClient((request) async {
        calls++;
        expect(request.url.path, contains('gemini-3.5-flash-lite'));
        if (calls == 1) {
          return http.Response(error(503, 'UNAVAILABLE', 'overloaded'), 503);
        }
        return http.Response(
          reply([
            {'text': '{"ok":true}'},
          ]),
          200,
        );
      }),
    );
    final result = await retrying.createJson(
      system: 's',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      schema: const {'type': 'object'},
    );
    expect(result.json, {'ok': true});
    expect(calls, 2);

    calls = 0;
    final quota = GeminiClient(
      apiKey: 'k',
      retryDelay: Duration.zero,
      httpClient: MockClient((_) async {
        calls++;
        return http.Response(error(429, 'RESOURCE_EXHAUSTED', 'quota'), 429);
      }),
    );
    await expectLater(
      quota.createJson(
        system: 's',
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
        schema: const {'type': 'object'},
      ),
      throwsA(isA<GeminiException>()),
    );
    expect(calls, 1);
  });
}
