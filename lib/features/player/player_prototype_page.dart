import 'dart:async';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../audio/audio_engine.dart';
import '../../audio/controlled_pcm.dart';
import '../../audio/mpv_audio_engine.dart';
import '../../library/application/library_controller.dart';
import '../../online/lx/fixture/lx_fixture_runtime.dart';
import '../../online/lx/fixture/lx_fixture_transport.dart';
import '../../online/lx/fixture/lx_fixture_wave.dart';
import '../library/library_page.dart';
import '../settings/playback_settings_page.dart';

class PlayerPrototypePage extends StatefulWidget {
  const PlayerPrototypePage({
    super.key,
    this.engineFactory,
    this.engine,
    required this.library,
    this.onQueueWillOpen,
  });

  final AudioEngine Function()? engineFactory;
  final AudioEngine? engine;
  final VoidCallback? onQueueWillOpen;
  final LibraryController library;

  @override
  State<PlayerPrototypePage> createState() => _PlayerPrototypePageState();
}

class _PlayerPrototypePageState extends State<PlayerPrototypePage> {
  late final AudioEngine _engine;
  final TextEditingController _streamUrlController = TextEditingController();
  StreamSubscription<String>? _errorSubscription;
  Timer? _equalizerTimer;
  final _fixtureRuntime = const LxFixtureRuntime();
  PcmCancellation? _fixture;
  bool _fixtureStarting = false;

  List<double> _equalizerGains = List<double>.filled(10, 0);
  String? _errorMessage;
  bool _busy = false;
  double _volume = 75;
  double _preampDb = 0;

  @override
  void initState() {
    super.initState();
    _engine = widget.engine ?? widget.engineFactory?.call() ?? MpvAudioEngine();
    _errorSubscription = _engine.errors.listen((message) {
      if (!mounted) return;
      setState(() => _errorMessage = message);
    });
  }

  @override
  void dispose() {
    if (_fixture != null) {
      _fixture?.cancel();
      if (_engine case MpvAudioEngine engine) {
        unawaited(engine.closeControlledPcm().catchError((Object _) {}));
      }
    }
    _streamUrlController.dispose();
    _equalizerTimer?.cancel();
    unawaited(_errorSubscription?.cancel());
    if (widget.engine == null) unawaited(_engine.dispose());
    super.dispose();
  }

  Future<void> _openLibrary() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => LibraryPage(
          controller: widget.library,
          onPlay: (file) async {
            if (!mounted) throw StateError('播放器已关闭');
            setState(() => _errorMessage = null);
            _forgetLxFixture();
            widget.onQueueWillOpen?.call();
            await _engine.openQueue([
              AudioTrack(uri: file.location.locator, title: file.displayTitle),
            ]);
          },
        ),
      ),
    );
  }

  Future<void> _chooseAudioFiles() async {
    setState(() {
      _busy = true;
      _errorMessage = null;
    });

    try {
      final files = await FilePicker.pickFiles(
        type: FileType.audio,
        dialogTitle: '选择音频文件',
        androidOptions: const FilePickerAndroidOptions(
          safOptions: AndroidSAFOptions(
            grant: AndroidSAFGrant.lifetime,
            copyToCache: false,
          ),
        ),
      );
      if (!mounted || files.isEmpty) return;

      final tracks = files
          .map((file) => AudioTrack(uri: file.uri.toString(), title: file.name))
          .toList(growable: false);
      _forgetLxFixture();
      widget.onQueueWillOpen?.call();
      await _engine.openQueue(tracks);
    } catch (error) {
      if (mounted) setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playNetworkStream() async {
    if (_busy) return;
    final uri = Uri.tryParse(_streamUrlController.text.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() => _errorMessage = '请输入有效的 HTTP 或 HTTPS 音频直链。');
      return;
    }

    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final title = uri.pathSegments.isEmpty ? uri.host : uri.pathSegments.last;
      _forgetLxFixture();
      widget.onQueueWillOpen?.call();
      await _engine.openQueue([AudioTrack(uri: uri.toString(), title: title)]);
    } catch (error) {
      if (mounted) setState(() => _errorMessage = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playLxFixture() async {
    final engine = _engine;
    if (_fixtureStarting || engine is! MpvAudioEngine) return;
    _fixture?.cancel();
    final request = _fixture = PcmCancellation();
    setState(() {
      _fixtureStarting = true;
      _errorMessage = null;
    });
    FixtureWave? wave;
    var handedOff = false;
    try {
      final url = await _fixtureRuntime.resolve(request);
      wave = await FixtureWave.open(
        url,
        const LxFixtureHttpsTransport(),
        request,
      );
      request.check();
      if (!mounted) return;
      widget.onQueueWillOpen?.call();
      handedOff = true;
      await engine.openControlledPcm(
        wave,
        title: lxFixtureTrackTitle,
        cancellation: request,
      );
    } on PcmCancelled {
      // The page or the next playback request cancelled this operation.
    } on LxFixtureRuntimeException catch (error) {
      if (mounted && !request.cancelled) {
        final stage = error.stage == 'timeout' ? '超时检查' : '初始化或取址';
        setState(() => _errorMessage = '隔离脚本验证失败（$stage）。');
      }
    } catch (_) {
      if (mounted && !request.cancelled) {
        setState(() => _errorMessage = '测试音频暂时无法读取，请重试。');
      }
    } finally {
      if (!handedOff) wave?.close();
      if (mounted) setState(() => _fixtureStarting = false);
    }
  }

  Future<void> _cancelLxFixture() async {
    setState(_forgetLxFixture);
    if (_engine case MpvAudioEngine engine) {
      await _runEngineAction(engine.closeControlledPcm);
    }
  }

  void _forgetLxFixture() {
    _fixture?.cancel();
    _fixture = null;
  }

  Future<void> _runEngineAction(Future<void> Function() action) async {
    setState(() => _errorMessage = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _errorMessage = error.toString());
    }
  }

  void _scheduleEqualizerUpdate() {
    _equalizerTimer?.cancel();
    _equalizerTimer = Timer(const Duration(milliseconds: 120), () {
      unawaited(_runEngineAction(() => _engine.setEqualizer(_equalizerGains)));
    });
  }

  Future<void> _resetEqualizer() async {
    final flat = List<double>.filled(10, 0);
    setState(() {
      _equalizerGains = flat;
      _preampDb = 0;
    });
    _equalizerTimer?.cancel();
    await _runEngineAction(() async {
      await _engine.setEqualizer(flat);
      await _engine.setPreamp(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Motif'),
        actions: [
          IconButton(
            key: const Key('open-playback-settings'),
            tooltip: '播放设置',
            onPressed: () => unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => PlaybackSettingsPage(
                    repository: widget.library.playbackQualitySettings,
                  ),
                ),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            key: const Key('open-local-library'),
            tooltip: '本地曲库',
            onPressed: _busy ? null : () => unawaited(_openLibrary()),
            icon: const Icon(Icons.library_music_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Chip(
                avatar: const Icon(Icons.science_outlined, size: 18),
                label: const Text('测试版 · 音频原型'),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Text('播放器引擎验证', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  '验证本地格式、切歌、均衡器及系统媒体控制。当前使用 audio-only libmpv 原型。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                _PlayerCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '正在播放',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: _busy ? null : _chooseAudioFiles,
                            icon: _busy
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.library_music_outlined),
                            label: const Text('选择音频'),
                          ),
                        ],
                      ),
                      if (_fixtureRuntime.isAvailable &&
                          _engine is MpvAudioEngine)
                        Wrap(
                          spacing: 8,
                          children: [
                            FilledButton.tonal(
                              onPressed: _busy || _fixtureStarting
                                  ? null
                                  : _playLxFixture,
                              child: Text(
                                _fixtureStarting ? '正在验证…' : '播放固定样本',
                              ),
                            ),
                            TextButton(
                              onPressed: _fixture == null
                                  ? null
                                  : _cancelLxFixture,
                              child: const Text('停止样本'),
                            ),
                          ],
                        ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _streamUrlController,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        onSubmitted: (_) => unawaited(_playNetworkStream()),
                        decoration: const InputDecoration(
                          labelText: '网络音频直链',
                          hintText: 'https://example.com/track.flac',
                          prefixIcon: Icon(Icons.link_rounded),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonalIcon(
                          onPressed: _busy ? null : _playNetworkStream,
                          icon: const Icon(Icons.play_circle_outline_rounded),
                          label: const Text('播放网络直链'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      StreamBuilder<AudioQueueSnapshot>(
                        stream: _engine.queue,
                        initialData: AudioQueueSnapshot.empty,
                        builder: (context, snapshot) {
                          final queue = snapshot.data!;
                          final track = queue.currentTrack;
                          return Row(
                            children: [
                              Container(
                                width: 76,
                                height: 76,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Icon(
                                  Icons.graphic_eq_rounded,
                                  size: 36,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(width: 18),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      track?.title ?? '尚未选择歌曲',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleLarge,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      queue.tracks.isEmpty
                                          ? '选择一首或多首本地音频开始验证'
                                          : '队列 ${queue.currentIndex + 1} / ${queue.tracks.length}',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 18),
                      _PlaybackProgress(engine: _engine),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton.filledTonal(
                            tooltip: '上一首',
                            onPressed: () => unawaited(
                              _runEngineAction(() async {
                                await _engine.previous();
                              }),
                            ),
                            icon: const Icon(Icons.skip_previous_rounded),
                          ),
                          const SizedBox(width: 16),
                          StreamBuilder<bool>(
                            stream: _engine.playWhenReady,
                            initialData: false,
                            builder: (context, snapshot) {
                              final playing = snapshot.data ?? false;
                              return IconButton.filled(
                                tooltip: playing ? '暂停' : '播放',
                                iconSize: 32,
                                onPressed: () => unawaited(
                                  _runEngineAction(
                                    playing ? _engine.pause : _engine.play,
                                  ),
                                ),
                                icon: Icon(
                                  playing
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 16),
                          IconButton.filledTonal(
                            tooltip: '下一首',
                            onPressed: () => unawaited(
                              _runEngineAction(() async {
                                await _engine.next();
                              }),
                            ),
                            icon: const Icon(Icons.skip_next_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(Icons.volume_down_rounded, size: 20),
                          Expanded(
                            child: Slider(
                              min: 0,
                              max: 100,
                              divisions: 100,
                              value: _volume,
                              label: '${_volume.round()}%',
                              onChanged: (value) =>
                                  setState(() => _volume = value),
                              onChangeEnd: (value) => unawaited(
                                _runEngineAction(
                                  () => _engine.setVolume(value),
                                ),
                              ),
                            ),
                          ),
                          const Icon(Icons.volume_up_rounded, size: 20),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _PlayerCard(
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 12),
                    title: const Text('10 段均衡器'),
                    subtitle: const Text('临时测试频点；可拖动调节，松开后应用'),
                    trailing: IconButton(
                      tooltip: '恢复平直',
                      onPressed: _resetEqualizer,
                      icon: const Icon(Icons.restart_alt_rounded),
                    ),
                    children: [
                      Row(
                        children: [
                          const SizedBox(width: 82, child: Text('前级增益')),
                          Expanded(
                            child: Slider(
                              min: -12,
                              max: 12,
                              divisions: 48,
                              value: _preampDb,
                              label: '${_preampDb.toStringAsFixed(1)} dB',
                              onChanged: (value) =>
                                  setState(() => _preampDb = value),
                              onChangeEnd: (value) => unawaited(
                                _runEngineAction(
                                  () => _engine.setPreamp(value),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 62,
                            child: Text('${_preampDb.toStringAsFixed(1)} dB'),
                          ),
                        ],
                      ),
                      SizedBox(
                        height: 190,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: List.generate(10, (index) {
                              final centerHz = equalizerCentersHz[index];
                              return SizedBox(
                                width: 54,
                                child: Column(
                                  children: [
                                    Text(
                                      _formatBand(centerHz),
                                      style: theme.textTheme.labelSmall,
                                    ),
                                    Expanded(
                                      child: RotatedBox(
                                        quarterTurns: 3,
                                        child: SizedBox(
                                          width: 142,
                                          child: Slider(
                                            min: -12,
                                            max: 12,
                                            divisions: 48,
                                            value: _equalizerGains[index],
                                            onChanged: (value) {
                                              setState(() {
                                                _equalizerGains[index] = value;
                                              });
                                              _scheduleEqualizerUpdate();
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${_equalizerGains[index].toStringAsFixed(1)} dB',
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 16),
                  _PlayerCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SelectableText(
                            _errorMessage!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭',
                          onPressed: () => setState(() => _errorMessage = null),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaybackProgress extends StatefulWidget {
  const _PlaybackProgress({required this.engine});

  final AudioEngine engine;

  @override
  State<_PlaybackProgress> createState() => _PlaybackProgressState();
}

class _PlaybackProgressState extends State<_PlaybackProgress> {
  double? _dragPositionMs;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.engine.duration,
      initialData: Duration.zero,
      builder: (context, durationSnapshot) {
        final duration = durationSnapshot.data ?? Duration.zero;
        final maxMs = duration.inMilliseconds.clamp(1, 1 << 31);
        return StreamBuilder<Duration>(
          stream: widget.engine.position,
          initialData: Duration.zero,
          builder: (context, positionSnapshot) {
            final position = positionSnapshot.data ?? Duration.zero;
            final value =
                (_dragPositionMs ?? position.inMilliseconds.toDouble())
                    .clamp(0, maxMs)
                    .toDouble();
            return Column(
              children: [
                Slider(
                  min: 0,
                  max: maxMs.toDouble(),
                  value: value,
                  onChanged: duration == Duration.zero
                      ? null
                      : (milliseconds) {
                          setState(() => _dragPositionMs = milliseconds);
                        },
                  onChangeEnd: duration == Duration.zero
                      ? null
                      : (milliseconds) {
                          setState(() => _dragPositionMs = null);
                          unawaited(
                            widget.engine.seek(
                              Duration(milliseconds: milliseconds.round()),
                            ),
                          );
                        },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatDuration(position)),
                      Text(_formatDuration(duration)),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _PlayerCard extends StatelessWidget {
  const _PlayerCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

String _formatDuration(Duration value) {
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = value.inHours;
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String _formatBand(double frequency) {
  if (frequency >= 1000) {
    final khz = frequency / 1000;
    return '${khz == khz.roundToDouble() ? khz.toInt() : khz}k';
  }
  return frequency.toInt().toString();
}
