import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'playlist_engine.dart';

enum OnDeviceStatus {
  available(null),
  deviceNotEligible(
    'This iPhone doesn’t support Apple Intelligence. The free mode needs an '
    'iPhone 15 Pro or newer.',
  ),
  appleIntelligenceNotEnabled(
    'Turn on Apple Intelligence in the Settings app › Apple Intelligence & '
    'Siri, then reopen Promptlist.',
  ),
  modelNotReady(
    'Apple Intelligence is still downloading its model. Try again later.',
  ),
  unsupportedOS('The free mode needs iOS 26 or later.'),
  unavailable('Apple’s on-device AI only runs on iPhone.');

  const OnDeviceStatus(this.problem);

  /// Why the model can't be used, or null when it can.
  final String? problem;

  bool get isAvailable => this == available;
}

enum ListeningPreference { any, mostPlayed, rarelyPlayed }

/// Search criteria the on-device model derives from a playlist request.
class OnDevicePlan {
  const OnDevicePlan({
    this.name = '',
    this.description = '',
    this.genres = const [],
    this.artists = const [],
    this.keywords = const [],
    this.fromYear = 0,
    this.toYear = 0,
    this.listening = ListeningPreference.any,
  });

  factory OnDevicePlan.fromMap(Map<Object?, Object?> map) {
    List<String> strings(Object? value) => [
      for (final item in value is List ? value : const [])
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
    int year(Object? value) {
      final year = value is num ? value.toInt() : 0;
      return year >= 1000 && year <= 2200 ? year : 0;
    }

    final listening = '${map['listening'] ?? ''}'.toLowerCase().replaceAll(
      RegExp('[^a-z]'),
      '',
    );
    return OnDevicePlan(
      name: '${map['name'] ?? ''}'.trim(),
      description: '${map['description'] ?? ''}'.trim(),
      genres: strings(map['genres']),
      artists: strings(map['artists']),
      keywords: strings(map['keywords']),
      fromYear: year(map['fromYear']),
      toYear: year(map['toYear']),
      listening: switch (listening) {
        'mostplayed' ||
        'favorites' ||
        'mostlistened' => ListeningPreference.mostPlayed,
        'rarelyplayed' ||
        'leastplayed' ||
        'neverplayed' => ListeningPreference.rarelyPlayed,
        _ => ListeningPreference.any,
      },
    );
  }

  final String name;
  final String description;
  final List<String> genres;
  final List<String> artists;
  final List<String> keywords;

  /// 0 means no limit.
  final int fromYear;
  final int toYear;
  final ListeningPreference listening;
}

/// Apple's on-device language model (Foundation Models).
abstract class OnDeviceModel {
  Future<OnDeviceStatus> status();

  Future<OnDevicePlan> plan({
    required String instructions,
    required String prompt,
  });

  /// Returns the chosen song numbers, in play order.
  Future<List<int>> pick({
    required String instructions,
    required String prompt,
  });
}

OnDeviceModel createOnDeviceModel() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return AppleOnDeviceModel();
  }
  return UnavailableOnDeviceModel();
}

/// Talks to `ios/Runner/OnDeviceModelPlugin.swift` over a method channel.
class AppleOnDeviceModel implements OnDeviceModel {
  AppleOnDeviceModel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('promptlist/on_device_model');

  final MethodChannel _channel;

  @override
  Future<OnDeviceStatus> status() async {
    try {
      final status = await _channel.invokeMethod<String>('status');
      return OnDeviceStatus.values.firstWhere(
        (value) => value.name == status,
        orElse: () => OnDeviceStatus.unavailable,
      );
    } on PlatformException {
      return OnDeviceStatus.unavailable;
    } on MissingPluginException {
      return OnDeviceStatus.unavailable;
    }
  }

  @override
  Future<OnDevicePlan> plan({
    required String instructions,
    required String prompt,
  }) async {
    final map = await _invoke('plan', instructions, prompt);
    return OnDevicePlan.fromMap(map);
  }

  @override
  Future<List<int>> pick({
    required String instructions,
    required String prompt,
  }) async {
    final map = await _invoke('pick', instructions, prompt);
    final numbers = map['songNumbers'];
    return [
      for (final n in numbers is List ? numbers : const [])
        if (n is num) n.toInt(),
    ];
  }

  Future<Map<Object?, Object?>> _invoke(
    String method,
    String instructions,
    String prompt,
  ) async {
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>(method, {
        'instructions': instructions,
        'prompt': prompt,
      });
      return result ?? const {};
    } on PlatformException catch (error) {
      throw GenerationException(
        'Apple Intelligence couldn’t handle that request. '
        '${error.message ?? error.code}',
      );
    }
  }
}

class UnavailableOnDeviceModel implements OnDeviceModel {
  @override
  Future<OnDeviceStatus> status() async => OnDeviceStatus.unavailable;

  @override
  Future<OnDevicePlan> plan({
    required String instructions,
    required String prompt,
  }) => throw GenerationException(OnDeviceStatus.unavailable.problem!);

  @override
  Future<List<int>> pick({
    required String instructions,
    required String prompt,
  }) => throw GenerationException(OnDeviceStatus.unavailable.problem!);
}
