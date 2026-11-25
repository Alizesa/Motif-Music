import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../online/application/online_playback_controller.dart';
import '../../online/qq/qq_track.dart';
import 'catalog_player_widgets.dart';

class CatalogPlayerPage extends StatelessWidget {
  const CatalogPlayerPage({
    super.key,
    required this.playback,
    required this.onOpenSettings,
    this.onDownload,
  });

  final OnlinePlaybackController playback;
  final VoidCallback onOpenSettings;
  final void Function(QqTrack)? onDownload;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('正在播放'),
      actions: [
        if (onDownload != null)
          AnimatedBuilder(
            animation: playback,
            builder: (context, _) => IconButton(
              tooltip: '下载',
              onPressed: playback.currentTrack == null
                  ? null
                  : () => onDownload!(playback.currentTrack!),
              icon: const Icon(Icons.download_outlined),
            ),
          ),
        IconButton(
          tooltip: '设置',
          onPressed: onOpenSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    body: SafeArea(
      child: AnimatedBuilder(
        animation: playback,
        builder: (context, _) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Center(
                  child: SongArtwork(
                    track: playback.currentTrack,
                    size: (MediaQuery.sizeOf(context).width - 96).clamp(
                      160,
                      300,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  playback.currentTitle ?? '选择一首喜欢的歌曲',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                if (playback.currentArtist.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(playback.currentArtist, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 24),
                Slider(
                  key: const Key('catalog-seek'),
                  value: playback.position.inMilliseconds
                      .clamp(
                        0,
                        playback.duration.inMilliseconds.clamp(1, 8640000000),
                      )
                      .toDouble(),
                  max: playback.duration.inMilliseconds
                      .clamp(1, 8640000000)
                      .toDouble(),
                  onChanged:
                      playback.duration > Duration.zero && !playback.isLoading
                      ? (value) => unawaited(
                          playback.seek(Duration(milliseconds: value.round())),
                        )
                      : null,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(formatPlaybackTime(playback.position)),
                    Text(formatPlaybackTime(playback.duration)),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: '上一首',
                      onPressed: !playback.isLoading && playback.canPrevious
                          ? () => unawaited(playback.previous())
                          : null,
                      iconSize: 36,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    const SizedBox(width: 16),
                    if (playback.isLoading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: SizedBox.square(
                          dimension: 32,
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else
                      IconButton.filled(
                        key: const Key('catalog-toggle-play'),
                        tooltip: playback.isPlaying ? '暂停' : '播放',
                        iconSize: 42,
                        onPressed: playback.hasMedia
                            ? () => unawaited(playback.togglePlay())
                            : null,
                        icon: Icon(
                          playback.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                      ),
                    const SizedBox(width: 16),
                    IconButton(
                      tooltip: '下一首',
                      onPressed: !playback.isLoading && playback.canNext
                          ? () => unawaited(playback.next())
                          : null,
                      iconSize: 36,
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: () =>
                      unawaited(showCatalogQueue(context, playback)),
                  icon: const Icon(Icons.queue_music_rounded),
                  label: const Text('播放队列'),
                ),
                if (playback.error case final error?) ...[
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(error),
                          TextButton(
                            onPressed: playback.isLoading
                                ? null
                                : () => unawaited(playback.retry()),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
