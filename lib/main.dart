import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';

import 'audio/audio_engine.dart';
import 'features/home/motif_home_page.dart';
import 'online/qq/qq_music_client.dart';
import 'settings/online_playback_preferences.dart';
import 'library/application/library_controller.dart';
import 'third_party_licenses.dart';
import 'online/qq/auth/qq_auth_client.dart';
import 'online/qq/auth/qq_session_manager.dart';
import 'online/qq/auth/secure_qq_credential_vault.dart';
import 'online/qq/qq_account_api.dart';

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
    this.qqMusicClientFactory,
    this.onlinePreferencesStore,
    this.qqSessionFactory,
    this.qqAuthClientFactory,
    this.qqAccountApiFactory,
  });

  final AudioEngine Function()? engineFactory;
  final LibraryController Function()? libraryControllerFactory;
  final QqMusicClient Function()? qqMusicClientFactory;
  final OnlinePlaybackPreferencesStore? onlinePreferencesStore;
  final QqSessionManager Function()? qqSessionFactory;
  final QqAuthClient Function()? qqAuthClientFactory;
  final QqAccountApi Function(QqSessionManager, QqAuthClient)?
  qqAccountApiFactory;

  @override
  State<MotifApp> createState() => _MotifAppState();
}

class _MotifAppState extends State<MotifApp> with WidgetsBindingObserver {
  late final LibraryController _library;
  late final QqMusicClient _qqMusic;
  late final QqSessionManager _sessions;
  late final QqAuthClient _auth;
  late final QqAccountApi _accountApi;

  @override
  void initState() {
    super.initState();
    _library = (widget.libraryControllerFactory ?? LibraryController.open)();
    _sessions =
        widget.qqSessionFactory?.call() ??
        QqSessionManager(vault: const SecureQqCredentialVault());
    _auth = widget.qqAuthClientFactory?.call() ?? QqAuthClient();
    _accountApi =
        widget.qqAccountApiFactory?.call(_sessions, _auth) ??
        QqAccountApi(sessions: _sessions, renewClient: _auth);
    _qqMusic =
        widget.qqMusicClientFactory?.call() ??
        QqMusicClient(accountApi: _accountApi);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_library.initialize());
    unawaited(_sessions.initialize());
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
    _qqMusic.close();
    _accountApi.close();
    _auth.close();
    unawaited(_sessions.close());
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
      home: MotifHomePage(
        library: _library,
        qqMusic: _qqMusic,
        engineFactory: widget.engineFactory,
        preferencesStore: widget.onlinePreferencesStore,
        sessions: _sessions,
        authClient: _auth,
        accountApi: _accountApi,
      ),
    );
  }
}
