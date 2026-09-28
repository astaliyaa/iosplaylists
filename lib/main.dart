import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'services/music_library.dart';
import 'services/settings_store.dart';
import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController(
    library: createMusicLibrary(),
    settingsStore: SettingsStore(),
  )..init();
  runApp(PromptlistApp(controller: controller));
}

class PromptlistApp extends StatelessWidget {
  const PromptlistApp({super.key, required this.controller});

  final AppController controller;

  static const _seed = Color(0xFFFA2D48);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Promptlist',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: _seed),
      darkTheme: ThemeData(colorSchemeSeed: _seed, brightness: Brightness.dark),
      home: HomePage(controller: controller),
    );
  }
}
