import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../online/application/online_playback_controller.dart';
import '../../online/domain/online_error.dart';
import '../../online/qq/auth/qq_session_manager.dart';
import '../../online/qq/qq_account_api.dart';
import '../../online/qq/qq_home_models.dart';
import '../../online/qq/qq_track.dart';
import '../player/catalog_player_widgets.dart';

enum QqTrackListKind { daily, radio, playlist, redHeart }

class QqTrackListPage extends StatefulWidget {
  const QqTrackListPage({
    super.key,
    required this.title,
    required this.kind,
    required this.api,
    required this.playback,
    this.playlist,
  });
  final String title;
  final QqTrackListKind kind;
  final QqAccountApi api;
  final OnlinePlaybackController playback;
  final QqPlaylist? playlist;
  @override
  State<QqTrackListPage> createState() => _QqTrackListPageState();
}

class _QqTrackListPageState extends State<QqTrackListPage> {
  late final QqSessionSnapshot _session;
  late final StreamSubscription<QqSessionStatus> _subscription;
  List<QqTrack> _tracks = const [];
  bool _loading = true;
  bool _hasMore = false;
  int _offset = 0;
  int _generation = 0;
  String? _error;
  @override
  void initState() {
    super.initState();
    _session = widget.api.sessions.snapshot;
    _subscription = widget.api.sessions.changes.listen((_) {
      if (!widget.api.sessions.isCurrent(_session) && mounted) {
        _generation++;
        setState(() {
          _tracks = const [];
          _loading = false;
          _hasMore = false;
          _error = '账号已变化，请返回首页。';
        });
      }
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_subscription.cancel());
    super.dispose();
  }

  Future<void> _load({int? requestedOffset}) async {
    if (!widget.api.sessions.isCurrent(_session)) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<QqTrack> tracks;
      var hasMore = false;
      final offset = requestedOffset ?? _offset;
      switch (widget.kind) {
        case QqTrackListKind.daily:
          tracks = await widget.api.daily();
        case QqTrackListKind.radio:
          tracks = await widget.api.radio(session: _session);
        case QqTrackListKind.playlist:
        case QqTrackListKind.redHeart:
          final page = await widget.api.playlistPage(
            widget.playlist!,
            offset: offset,
          );
          tracks = page.tracks;
          hasMore = widget.kind == QqTrackListKind.playlist && page.hasMore;
      }
      if (!mounted ||
          generation != _generation ||
          !widget.api.sessions.isCurrent(_session)) {
        return;
      }
      setState(() {
        _tracks = tracks;
        _hasMore = hasMore;
        _offset = offset;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = error is OnlineException
              ? error.toString()
              : '曲目获取失败，请重试。',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _play(int index) {
    if (!widget.api.sessions.isCurrent(_session) || _tracks.isEmpty) return;
    unawaited(
      widget.playback.playQueue(
        _tracks,
        startIndex: index,
        nextRecommendationBatch: widget.kind == QqTrackListKind.radio
            ? () => widget.api.radio(session: _session)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: SafeArea(
      child: Column(
        children: [
          if (_loading) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: _loading || _tracks.isEmpty
                      ? null
                      : () => _play(0),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    widget.kind == QqTrackListKind.playlist ? '播放本页' : '播放全部',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _loading || _tracks.isEmpty
                      ? null
                      : () {
                          final count = widget.playback.append(_tracks);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已加入 $count 首')),
                          );
                        },
                  icon: const Icon(Icons.queue_music_rounded),
                  label: const Text('加入队列'),
                ),
              ],
            ),
          ),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(error),
                  TextButton(
                    onPressed: _loading ? null : () => unawaited(_load()),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _tracks.isEmpty
                ? Center(child: Text(_loading ? '正在获取曲目…' : '暂无曲目'))
                : ListView.separated(
                    itemCount: _tracks.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final track = _tracks[index];
                      return ListTile(
                        leading: SongArtwork(track: track),
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
                        onTap: () => _play(index),
                      );
                    },
                  ),
          ),
          if (widget.kind == QqTrackListKind.playlist)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                children: [
                  Text('第 ${_offset ~/ 50 + 1} 页 · ${_tracks.length} 首'),
                  if (_offset > 0)
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () {
                              unawaited(_load(requestedOffset: _offset - 50));
                            },
                      child: const Text('上一页'),
                    ),
                  if (_hasMore)
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () =>
                                unawaited(_load(requestedOffset: _offset + 50)),
                      child: const Text('下一页'),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
