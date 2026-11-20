import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';

import 'audio/audio_engine.dart';
import 'features/player/player_prototype_page.dart';
import 'library/application/library_controller.dart';
import 'third_party_licenses.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerThirdPartyLicenses();
  MpvAudioKit.ensureInitialized();
  runApp(const MotifApp());
}

class MotifApp extends StatefulWidget {
  const MotifApp({
    super.key,
    this.engineFactory,
    this.libraryControllerFactory,
  });

  final AudioEngine Function()? engineFactory;
  final LibraryController Function()? libraryControllerFactory;

  @override
  State<MotifApp> createState() => _MotifAppState();
}

class _MotifAppState extends State<MotifApp> with WidgetsBindingObserver {
  late final LibraryController _library;

  @override
  void initState() {
    super.initState();
    _library = (widget.libraryControllerFactory ?? LibraryController.open)();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_library.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) unawaited(_library.close());
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _library.close();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_library.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF91C8B0);
    return MaterialApp(
      title: 'Motif',
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF101311),
        cardTheme: const CardThemeData(color: Color(0xFF191E1B), elevation: 0),
        useMaterial3: true,
      ),
      home: PlayerPrototypePage(
        engineFactory: widget.engineFactory,
        library: _library,
      ),
    );
  }
}
