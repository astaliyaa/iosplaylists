import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptlist/app_controller.dart';
import 'package:promptlist/main.dart';
import 'package:promptlist/services/claude_client.dart';
import 'package:promptlist/services/demo_library.dart';
import 'package:promptlist/services/on_device_model.dart';
import 'package:promptlist/services/settings_store.dart';

class MemorySettingsStore extends SettingsStore {
  MemorySettingsStore(this.settings);

  Settings settings;

  @override
  Future<Settings> load() async => settings;

  @override
  Future<void> save(Settings settings) async => this.settings = settings;
}

class RecordingLibrary extends DemoMusicLibrary {
  final saved = <(String, List<String>)>[];

  @override
  Future<void> createPlaylist({
    required String name,
    required String description,
    required List<String> songIds,
  }) async => saved.add((name, songIds));
}

class ScriptedModel implements JsonModel {
  ScriptedModel(this.replies);

  final List<Map<String, dynamic>> replies;
  int calls = 0;

  @override
  Future<ModelReply> createJson({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
  }) async {
    calls++;
    return ModelReply(json: replies.removeAt(0), content: const []);
  }
}

class FakeOnDeviceModel implements OnDeviceModel {
  FakeOnDeviceModel(this.currentStatus);

  final OnDeviceStatus currentStatus;
  final prompts = <String>[];

  @override
  Future<OnDeviceStatus> status() async => currentStatus;

  @override
  Future<OnDevicePlan> plan({
    required String instructions,
    required String prompt,
  }) async {
    prompts.add(prompt);
    return const OnDevicePlan(
      name: 'Quiet Folk',
      description: 'Soft and acoustic.',
      genres: ['Folk'],
    );
  }

  @override
  Future<List<int>> pick({
    required String instructions,
    required String prompt,
  }) async => [1];
}

void main() {
  Future<(AppController, RecordingLibrary, ScriptedModel)> pumpApp(
    WidgetTester tester, {
    Engine engine = Engine.claude,
    String apiKey = 'sk-ant-test',
    String geminiApiKey = '',
    OnDeviceModel? onDeviceModel,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final library = RecordingLibrary();
    final model = ScriptedModel([
      {
        'name': 'Night Drive',
        'description': 'Synths after dark.',
        'song_ids': [1, 2, 3],
        'note': '',
      },
      {
        'name': 'Night Drive II',
        'description': 'Even darker.',
        'song_ids': [3, 4],
        'note': 'Dropped the brighter songs.',
      },
    ]);
    final controller = AppController(
      library: library,
      settingsStore: MemorySettingsStore(
        Settings(engine: engine, apiKey: apiKey, geminiApiKey: geminiApiKey),
      ),
      onDeviceModel: onDeviceModel,
      createModel: (_) => model,
    );
    await controller.init();
    await tester.pumpWidget(PromptlistApp(controller: controller));
    await tester.pumpAndSettle();
    return (controller, library, model);
  }

  testWidgets('prompt → preview → refine → save', (tester) async {
    final (controller, library, model) = await pumpApp(tester);
    final catalog = controller.catalog(allowExplicit: true);

    expect(find.text('${demoSongs.length} sample songs'), findsOneWidget);
    final create = find.ancestor(
      of: find.text('Create playlist'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(tester.widget<FilledButton>(create).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'late night drive');
    await tester.pump();
    await tester.tap(create);
    await tester.pumpAndSettle();

    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Night Drive'), findsOneWidget);
    expect(find.text(catalog.songForId(1)!.title), findsOneWidget);

    await tester.tap(find.text('Refine'));
    await tester.pumpAndSettle();
    expect(find.text('What should change?'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'darker');
    await tester.pump();
    await tester.tap(find.text('Update playlist'));
    await tester.pumpAndSettle();

    expect(model.calls, 2);
    expect(find.text('Night Drive II'), findsOneWidget);
    expect(find.text('Dropped the brighter songs.'), findsOneWidget);

    await tester.tap(find.text('Save to Music'));
    await tester.pumpAndSettle();

    final (savedName, savedIds) = library.saved.single;
    expect(savedName, 'Night Drive II');
    expect(savedIds, [catalog.songForId(3)!.id, catalog.songForId(4)!.id]);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('asks for an API key when none is saved', (tester) async {
    await pumpApp(tester, apiKey: '');

    expect(find.text('Add your Anthropic API key'), findsOneWidget);

    await tester.tap(find.text('Add your Anthropic API key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'sk-ant-new');
    await tester.tap(find.text('Claude Sonnet 5'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Add your Anthropic API key'), findsNothing);
  });

  testWidgets('Gemini mode needs its own key, then generates', (tester) async {
    final (controller, _, model) = await pumpApp(
      tester,
      engine: Engine.gemini,
      apiKey: '',
    );

    expect(find.text('Add your Gemini API key'), findsOneWidget);
    await tester.tap(find.text('Add your Gemini API key'));
    await tester.pumpAndSettle();
    expect(find.text('Gemini 3.8 Flash'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Gemini API key'),
      'AIza-test',
    );
    await tester.ensureVisible(find.text('Gemini 3.5 Flash-Lite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemini 3.5 Flash-Lite'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(controller.settings.geminiApiKey, 'AIza-test');
    expect(controller.settings.geminiModel, 'gemini-3.5-flash-lite');
    expect(controller.settings.apiKey, isEmpty);
    expect(find.text('Add your Gemini API key'), findsNothing);

    await tester.enterText(find.byType(TextField), 'late night drive');
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Using gemini-3.5-flash-lite (free tier)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Create playlist'));
    await tester.pumpAndSettle();

    expect(model.calls, 1);
    expect(find.text('Night Drive'), findsOneWidget);
  });

  testWidgets('free mode builds playlists on the device', (tester) async {
    final onDevice = FakeOnDeviceModel(OnDeviceStatus.available);
    await pumpApp(
      tester,
      engine: Engine.onDevice,
      apiKey: '',
      onDeviceModel: onDevice,
    );

    await tester.scrollUntilVisible(
      find.text('Using Apple Intelligence on this iPhone (free)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Add your Anthropic API key'), findsNothing);

    await tester.enterText(find.byType(TextField), 'quiet folk');
    await tester.pump();
    await tester.tap(find.text('Create playlist'));
    await tester.pumpAndSettle();

    expect(onDevice.prompts.single, contains('Request: quiet folk'));
    expect(find.text('Quiet Folk'), findsOneWidget);
    // The demo library has three folk songs, fewer than the 25 asked for.
    expect(find.text('Mykonos'), findsOneWidget);
    expect(find.text('White Winter Hymnal'), findsOneWidget);
    expect(
      find.text('Only 3 songs in your library fit this request.'),
      findsOneWidget,
    );
  });

  testWidgets('explains when free mode is unavailable', (tester) async {
    await pumpApp(
      tester,
      engine: Engine.onDevice,
      apiKey: '',
      onDeviceModel: FakeOnDeviceModel(OnDeviceStatus.deviceNotEligible),
    );

    expect(find.text('Apple Intelligence isn’t available'), findsOneWidget);
    expect(find.textContaining('iPhone 15 Pro or newer'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'anything');
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Create playlist'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final create = find.ancestor(
      of: find.text('Create playlist'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    expect(tester.widget<FilledButton>(create).onPressed, isNull);
  });
}
