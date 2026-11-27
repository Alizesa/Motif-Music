import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../../audio/audio_engine.dart';
import '../../diagnostics/diagnostic_recorder.dart';
import '../../downloads/download_controller.dart';
import '../../downloads/download_directory_store.dart';
import '../../downloads/platform_download_destination.dart';
import '../downloads/download_page.dart';
import '../../audio/mpv_audio_engine.dart';
import '../../library/application/library_controller.dart';
import '../../library/domain/local_playback_matcher.dart';
import '../../online/application/online_playback_controller.dart';
import '../../online/application/track_playback_resolver.dart';
import '../../online/domain/music_source_registry.dart';
import '../../online/lx/lx_native_worker.dart';
import '../../online/lx/lx_source_manager.dart';
import '../../online/lx/lx_source_store.dart';
import '../../online/qq/qq_music_client.dart';
import '../../online/qq/qq_track.dart' show QqTrack;
import '../../settings/file_online_playback_preferences_store.dart';
import '../../settings/online_playback_preferences.dart';
import '../../settings/online_playback_settings_controller.dart';
import '../library/library_page.dart';
import '../player/catalog_player_page.dart';
import '../player/catalog_player_widgets.dart';
import '../player/player_prototype_page.dart';
import '../search/qq_search_page.dart';
import '../settings/application_settings_page.dart';
import '../settings/diagnostics_settings_page.dart';
import '../settings/music_source_settings_page.dart';
import '../settings/playback_settings_page.dart';
import 'motif_home_tabs.dart';
import '../../online/qq/auth/qq_auth_client.dart';
import '../../online/qq/auth/qq_session_manager.dart';
import '../../online/qq/qq_account_api.dart';
import '../../online/qq/qq_home_controller.dart';
import '../../online/qq/qq_home_models.dart';
import '../account/qq_login_page.dart';
import '../account/qq_account_page.dart';
import '../account/qq_verification_page.dart';
import 'qq_track_list_page.dart';

class MotifHomePage extends StatefulWidget {
  const MotifHomePage({
    super.key,
    required this.library,
    required this.qqMusic,
    this.engineFactory,
    this.preferencesStore,
    this.thirdPartySources = const [],
    this.sessions,
    this.authClient,
    this.accountApi,
    this.saveDiagnosticReport,
  });

  final LibraryController library;
  final QqMusicClient qqMusic;
  final AudioEngine Function()? engineFactory;
  final OnlinePlaybackPreferencesStore? preferencesStore;
  final List<MusicSourceRegistration> thirdPartySources;
  final QqSessionManager? sessions;
  final QqAuthClient? authClient;
  final QqAccountApi? accountApi;
  final DiagnosticSave? saveDiagnosticReport;

  @override
  State<MotifHomePage> createState() => _MotifHomePageState();
}

class _MotifHomePageState extends State<MotifHomePage>
    with WidgetsBindingObserver {
  final _diagnostics = DiagnosticRecorder();
  late final AudioEngine _engine;
  late final MusicSourceRegistry _sources;
  late final DownloadController _downloads;
  LxSourceManager? _lxSources;
  late final OnlinePlaybackSettingsController _settings;
  late final OnlinePlaybackController _playback;
  int _selectedIndex = 0;
  String? _shownError;
  QqHomeController? _home;
  StreamSubscription<QqSessionStatus>? _sessionSubscription;
  int? _sessionEpoch;

  bool get _useSideNavigation =>
      defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engine =
        widget.engineFactory?.call() ??
        MpvAudioEngine(diagnostics: _diagnostics);
    _sources = MusicSourceRegistry(
      qq: widget.qqMusic,
      thirdPartySources: widget.thirdPartySources,
    );
    if (const LxNativeWorker().available &&
        _engine is ControlledPcmAudioEngine) {
      final manager = _lxSources = LxSourceManager(
        registry: _sources,
        publicDetail: widget.qqMusic.publicDetail,
        store: LxSourceStore(() async {
          final directory = await getApplicationSupportDirectory();
          return Directory(
            '${directory.path}${Platform.pathSeparator}lx-sources',
          );
        }),
      );
      _sources.loadManaged = manager.initialize;
      unawaited(manager.initialize());
    }
    _settings = OnlinePlaybackSettingsController(
      widget.preferencesStore ??
          FileOnlinePlaybackPreferencesStore(
            file: () async {
              final directory = await getApplicationSupportDirectory();
              return File(
                '${directory.path}${Platform.pathSeparator}online-playback.json',
              );
            },
          ),
    );
    _downloads = DownloadController(
      sources: _sources,
      destination: const PlatformDownloadDestination(),
      currentScriptOrder: () => _settings.value.downloadOrder,
      directoryStore: FileDownloadDirectoryStore(() async {
        final support = await getApplicationSupportDirectory();
        return File.fromUri(
          support.uri.resolve('download-settings/directory.json'),
        );
      }),
      diagnostics: _diagnostics,
    );
    _playback = OnlinePlaybackController(
      engine: _engine,
      settings: _settings,
      diagnostics: _diagnostics,
      resolver: TrackPlaybackResolver(
        sources: _sources,
        matchLocal: (track, quality) => widget.library.resolveLocalPlayback(
          track: track.metadata,
          onlineQuality: quality,
        ),
        prepareLocal: widget.library.preparePlaybackFile,
      ),
      confirmLocal: _confirmLocal,
    )..addListener(_showPlaybackError);
    unawaited(_settings.initialize());
    final sessions = widget.sessions;
    final api = widget.accountApi ?? widget.qqMusic.accountApi;
    if (sessions != null && api != null) {
      api.verify = (challenge) => showQqVerification(context, challenge);
      _home = QqHomeController(sessions: sessions, api: api)
        ..addListener(_homeChanged);
      _sessionEpoch = sessions.epoch;
      _sessionSubscription = sessions.changes.listen((_) {
        if (!mounted) return;
        if (_sessionEpoch != sessions.epoch) {
          _sessionEpoch = sessions.epoch;
          _playback.releaseCatalogQueue();
        }
        setState(() {});
      });
      unawaited(_home!.initialize());
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await _downloads.close();
    return AppExitResponse.exit;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _diagnostics.record(DiagnosticEvent.lifecycle, {
      DiagnosticField.state: state,
    });
    if (state == AppLifecycleState.detached) unawaited(_downloads.close());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _home?.removeListener(_homeChanged);
    _home?.dispose();
    unawaited(_sessionSubscription?.cancel() ?? Future.value());
    (widget.accountApi ?? widget.qqMusic.accountApi)?.verify = null;
    _playback.removeListener(_showPlaybackError);
    _playback.dispose();
    _downloads.dispose();
    _settings.dispose();
    _lxSources?.dispose();
    _sources.close();
    unawaited(_engine.dispose());
    _diagnostics.dispose();
    super.dispose();
  }

  void _homeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openLogin() async {
    if (widget.sessions == null || widget.authClient == null) return;
    await _push(
      QqLoginPage(sessions: widget.sessions!, client: widget.authClient!),
      showMiniPlayer: false,
    );
  }

  Future<void> _openAccount() async {
    if (widget.sessions == null || widget.authClient == null) return;
    if (widget.sessions!.account == null) {
      await _openLogin();
      return;
    }
    await _push(QqAccountPage(sessions: widget.sessions!, onLogin: _openLogin));
  }

  Future<void> _openList(QqTrackListKind kind, {QqPlaylist? playlist}) async {
    final api = widget.accountApi ?? widget.qqMusic.accountApi;
    if (api == null) return;
    if (api.sessions.account == null) {
      await _openLogin();
      return;
    }
    await _push(
      QqTrackListPage(
        title: switch (kind) {
          QqTrackListKind.daily => '每日推荐',
          QqTrackListKind.radio => '猜你喜欢',
          QqTrackListKind.redHeart => '红心歌单',
          QqTrackListKind.playlist => playlist!.title,
        },
        kind: kind,
        api: api,
        playback: _playback,
        playlist: playlist,
        onDownload: _download,
      ),
    );
  }

  Future<void> _openRedHeart() async {
    final home = _home;
    if (home == null) return;
    if (home.sessions.account == null) {
      await _openLogin();
      return;
    }
    if (home.recent.isEmpty) await home.retry('recent');
    if (!mounted) return;
    final matches = home.recent
        .where((playlist) => playlist.title.trim() == '红心歌单')
        .toList();
    QqPlaylist? playlist = matches.length == 1 ? matches.single : null;
    playlist ??= await showModalBottomSheet<QqPlaylist>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('从最近播放的歌单中选择红心歌单'),
            ),
            if (home.recent.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(home.error('recent') ?? '暂无最近播放歌单。'),
              ),
            for (final item in home.recent)
              ListTile(
                title: Text(item.title),
                onTap: () => Navigator.of(context).pop(item),
              ),
          ],
        ),
      ),
    );
    if (playlist != null && mounted) {
      await _openList(QqTrackListKind.redHeart, playlist: playlist);
    }
  }

  Future<void> _playRecommended(QqRecommendedSong song) async {
    final api = widget.accountApi ?? widget.qqMusic.accountApi;
    if (api == null) return;
    final snapshot = api.sessions.snapshot;
    try {
      final track = await api.songDetail(song);
      if (mounted && api.sessions.isCurrent(snapshot)) {
        await _playback.playQueue([track]);
      }
    } catch (error) {
      if (mounted && api.sessions.isCurrent(snapshot)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('歌曲信息获取失败，请重试。')));
      }
    }
  }

  void _showPlaybackError() {
    final error = _playback.error;
    if (error == null) {
      _shownError = null;
      return;
    }
    if (error == _shownError) return;
    _shownError = error;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _playback.error != error) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(error),
          action: SnackBarAction(
            label: '重试',
            onPressed: () => unawaited(_playback.retry()),
          ),
        ),
      );
    });
  }

  Future<void> _push(Widget page, {bool showMiniPlayer = true}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => showMiniPlayer
              ? _PlayerRouteFrame(
                  playback: _playback,
                  onOpenPlayer: _openPlayer,
                  child: page,
                )
              : page,
        ),
      );

  Future<void> _openSearch() => _push(
    QqSearchPage(
      client: widget.qqMusic,
      playback: _playback,
      onDownload: _download,
    ),
  );

  Future<void> _openDownloads() => _push(DownloadPage(controller: _downloads));

  Future<void> _download(QqTrack track) async {
    await _sources.loadManaged?.call();
    await _settings.initialize();
    if (!mounted) return;
    final started = await showTrackDownloadSheet(
      context,
      controller: _downloads,
      track: track,
      preferredSourceId: _sources.downloadDefault(
        _settings.value.preferredSourceId,
        _settings.value.fallbackOrder,
      ),
      scriptOrder: _settings.value.downloadOrder,
      quality: _settings.value.quality,
    );
    if (started && mounted) await _openDownloads();
  }

  Future<void> _openLibrary() => _push(
    LibraryPage(controller: widget.library, onPlay: _playback.playLocal),
  );

  Future<void> _openPlayer() => _push(
    CatalogPlayerPage(
      playback: _playback,
      onOpenSettings: _openSettings,
      onDownload: _download,
    ),
    showMiniPlayer: false,
  );

  Future<void> _openPlayerPrototype() {
    return _push(
      PlayerPrototypePage(
        engine: _engine,
        library: widget.library,
        onQueueWillOpen: _playback.releaseCatalogQueue,
      ),
      showMiniPlayer: false,
    );
  }

  Future<void> _openSettings() => _push(
    ApplicationSettingsPage(
      onOpenQuality: _openQualitySettings,
      onOpenSources: _openSourceSettings,
      onOpenAudioTest: _openPlayerPrototype,
      onOpenDiagnostics: _openDiagnostics,
    ),
  );

  Future<void> _openDiagnostics() => _push(
    DiagnosticsSettingsPage(
      recorder: _diagnostics,
      snapshot: _diagnosticSnapshot,
      save: widget.saveDiagnosticReport,
    ),
    showMiniPlayer: false,
  );

  Map<DiagnosticSection, DiagnosticFacts> _diagnosticSnapshot() => {
    DiagnosticSection.app: {
      DiagnosticField.lxAvailable: _lxSources != null,
      DiagnosticField.ready: _lxSources?.ready,
      DiagnosticField.sourceCount: _sources.sources.length,
      DiagnosticField.state: WidgetsBinding.instance.lifecycleState,
    },
    DiagnosticSection.playback: _playback.diagnosticSnapshot(),
    if (_engine case final MpvAudioEngine mpv)
      DiagnosticSection.player: mpv.diagnosticSnapshot(),
    DiagnosticSection.downloads: _downloads.diagnosticSnapshot(),
  };

  Future<void> _openQualitySettings() => _push(
    PlaybackSettingsPage(
      repository: widget.library.playbackQualitySettings,
      onlineSettings: _settings,
    ),
  );

  Future<void> _openSourceSettings() => _push(
    MusicSourceSettingsPage(
      sources: _sources,
      settings: _settings,
      managed: _lxSources,
    ),
  );

  Future<LocalPlaybackChoice?> _confirmLocal(
    QqTrack track,
    LocalPlaybackResolution resolution,
  ) {
    if (!mounted) return Future.value();
    return showModalBottomSheet<LocalPlaybackChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '选择播放版本',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(track.title),
                    const SizedBox(height: 8),
                    Text(
                      resolution.isTruncated
                          ? '候选较多，可到本地曲库查看全部版本。'
                          : '请确认本地歌曲版本，也可以选择在线播放。',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: resolution.candidates.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final file = resolution.candidates[index];
                    final metadata = file.metadata;
                    return ListTile(
                      key: ValueKey('local-choice-${file.id}'),
                      leading: const Icon(Icons.audio_file_outlined),
                      title: Text(file.displayTitle),
                      subtitle: Text(
                        [
                          if (metadata.artist.isNotEmpty) metadata.artist,
                          if (metadata.album.isNotEmpty) metadata.album,
                          if (metadata.bitrateKbps != null)
                            '${metadata.bitrateKbps} kbps',
                          if (metadata.sampleRateHz != null)
                            '${metadata.sampleRateHz} Hz',
                          file.location.locator,
                        ].join(' · '),
                      ),
                      onTap: () =>
                          Navigator.of(context)
                              .pop(LocalPlaybackChoice.file(file.id)),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('local-choice-online'),
                    onPressed: () =>
                        Navigator.of(context)
                            .pop(const LocalPlaybackChoice.online()),
                    child: const Text('在线播放'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      MotifHomeTab(
        onOpenSearch: _openSearch,
        controller: _home,
        onLogin: _openAccount,
        onDaily: () => _openList(QqTrackListKind.daily),
        onRadio: () => _openList(QqTrackListKind.radio),
        onRedHeart: _openRedHeart,
        onPlaylist: (playlist) =>
            _openList(QqTrackListKind.playlist, playlist: playlist),
        onSong: _playRecommended,
      ),
      MotifMyTab(
        onOpenLibrary: _openLibrary,
        onOpenPlayer: _openPlayer,
        onOpenSettings: _openSettings,
        onOpenDownloads: _openDownloads,
        sessions: widget.sessions,
        onOpenAccount: _openAccount,
      ),
    ];
    final content = Column(
      children: [
        Expanded(
          child: IndexedStack(index: _selectedIndex, children: pages),
        ),
        CatalogMiniPlayer(playback: _playback, onOpenPlayer: _openPlayer),
      ],
    );
    if (_useSideNavigation) {
      final extended = MediaQuery.sizeOf(context).width >= 880;
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              NavigationRail(
                extended: extended,
                selectedIndex: _selectedIndex,
                onDestinationSelected: (index) =>
                    setState(() => _selectedIndex = index),
                labelType: extended ? null : NavigationRailLabelType.all,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.home_outlined),
                    selectedIcon: Icon(Icons.home_rounded),
                    label: Text('首页'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.person_outline_rounded),
                    selectedIcon: Icon(Icons.person_rounded),
                    label: Text('我的'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: content),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: content,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) =>
            setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: '首页',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

class _PlayerRouteFrame extends StatelessWidget {
  const _PlayerRouteFrame({
    required this.child,
    required this.playback,
    required this.onOpenPlayer,
  });

  final Widget child;
  final OnlinePlaybackController playback;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Expanded(
          child: MediaQuery.removeViewInsets(
            context: context,
            removeBottom: true,
            child: child,
          ),
        ),
        SafeArea(
          top: false,
          child: CatalogMiniPlayer(
            playback: playback,
            onOpenPlayer: onOpenPlayer,
          ),
        ),
      ],
    ),
  );
}
