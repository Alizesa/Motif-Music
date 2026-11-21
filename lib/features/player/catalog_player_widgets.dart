import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../online/application/online_playback_controller.dart';
import '../../online/qq/qq_track.dart';

class SongArtwork extends StatelessWidget {
  const SongArtwork({super.key, this.track, this.size = 48});
  final QqTrack? track;
  final double size;

  @override
  Widget build(BuildContext context) {
    final mid = track?.albumMid;
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(child: Icon(Icons.music_note_rounded, size: size * 0.45)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size > 80 ? 24 : 10),
      child: SizedBox.square(
        dimension: size,
        child: mid == null
            ? placeholder
            : Image.network(
                'https://y.gtimg.cn/music/photo_new/T002R300x300M000$mid.jpg',
                fit: BoxFit.cover,
                cacheWidth: (size * 2).round().clamp(48, 600),
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

class CatalogMiniPlayer extends StatelessWidget {
  const CatalogMiniPlayer({
    super.key,
    required this.playback,
    required this.onOpenPlayer,
  });

  final OnlinePlaybackController playback;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback,
    builder: (context, _) {
      if (!playback.hasMedia) return const SizedBox.shrink();
      final duration = playback.duration.inMilliseconds;
      final progress = duration > 0
          ? (playback.position.inMilliseconds / duration).clamp(0.0, 1.0)
          : 0.0;
      return Material(
        key: const Key('catalog-mini-player'),
        color: Theme.of(context).colorScheme.surfaceContainer,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: progress, minHeight: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  InkWell(
                    onTap: onOpenPlayer,
                    child: SongArtwork(track: playback.currentTrack, size: 44),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: InkWell(
                      key: const Key('mini-open-player'),
                      onTap: onOpenPlayer,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              playback.currentTitle ?? '播放队列',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (playback.currentArtist.isNotEmpty)
                              Text(
                                playback.currentArtist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (playback.isLoading)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      key: const Key('mini-toggle-play'),
                      tooltip: playback.isPlaying ? '暂停' : '播放',
                      onPressed: () => unawaited(playback.togglePlay()),
                      icon: Icon(
                        playback.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                  IconButton(
                    tooltip: '播放队列',
                    onPressed: () =>
                        unawaited(showCatalogQueue(context, playback)),
                    icon: const Icon(Icons.queue_music_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

Future<void> showCatalogQueue(
  BuildContext context,
  OnlinePlaybackController playback,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: AnimatedBuilder(
        animation: playback,
        builder: (context, _) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '播放队列 · ${playback.queue.tracks.length}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭队列',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (playback.continuation.isLoading)
              const LinearProgressIndicator(),
            if (playback.continuation.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    const Expanded(child: Text('推荐加载失败，可重试。')),
                    TextButton(
                      onPressed: () =>
                          unawaited(playback.continuation.check(retry: true)),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: playback.queue.tracks.isEmpty
                  ? Center(child: Text(playback.currentTitle ?? '队列为空'))
                  : ListView.builder(
                      itemCount: playback.queue.tracks.length,
                      itemBuilder: (context, index) {
                        final track = playback.queue.tracks[index];
                        final selected =
                            track.identity == playback.currentTrack?.identity;
                        return ListTile(
                          key: ValueKey('queue-${track.identity}'),
                          selected: selected,
                          leading: selected
                              ? const Icon(Icons.graphic_eq_rounded)
                              : Text('${index + 1}'),
                          title: Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            track.artists.join('、'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: playback.isLoading
                              ? null
                              : () => unawaited(playback.select(index)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  ),
);

String formatPlaybackTime(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 8640000);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
