import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:promptlist/app_controller.dart';
import 'package:promptlist/main.dart';
import 'package:promptlist/services/claude_client.dart';
import 'package:promptlist/services/demo_library.dart';
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
  Future<ClaudeReply> createJson({
    required String system,
    required List<Map<String, dynamic>> messages,
    required Map<String, dynamic> schema,
  }) async {
    calls++;
    return ClaudeReply(json: replies.removeAt(0), content: const []);
  }
}

void main() {
  Future<(AppController, RecordingLibrary, ScriptedModel)> pumpApp(
    WidgetTester tester, {
    String apiKey = 'sk-ant-test',
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
      settingsStore: MemorySettingsStore(Settings(apiKey: apiKey)),
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
}
