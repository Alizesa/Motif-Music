import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../online/application/online_playback_controller.dart';
import '../../online/domain/online_error.dart';
import '../../online/qq/qq_music_client.dart';
import '../../online/qq/qq_track.dart' show QqTrack;
import '../player/catalog_player_widgets.dart';

class QqSearchPage extends StatefulWidget {
  const QqSearchPage({super.key, required this.client, required this.playback});

  final QqMusicClient client;
  final OnlinePlaybackController playback;

  @override
  State<QqSearchPage> createState() => _QqSearchPageState();
}

class _QqSearchPageState extends State<QqSearchPage> {
  final _query = TextEditingController();
  List<QqTrack> _tracks = const [];
  String? _activeQuery;
  String? _error;
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  int _generation = 0;

  @override
  void dispose() {
    _generation++;
    _query.dispose();
    super.dispose();
  }

  Future<void> _search({bool nextPage = false, bool retry = false}) async {
    final query = nextPage || retry ? _activeQuery : _query.text.trim();
    if (query == null ||
        query.isEmpty ||
        (nextPage && (_loading || !_hasMore)) ||
        (!nextPage && _loading && query == _activeQuery)) {
      return;
    }
    final page = nextPage ? _page + 1 : 1;
    final generation = nextPage ? _generation : ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!nextPage) {
        _tracks = const [];
        _page = 0;
        _hasMore = false;
        _activeQuery = query;
      }
    });
    try {
      final result = await widget.client.search(query, page: page);
      if (!mounted || generation != _generation) return;
      setState(() {
        _tracks = nextPage
            ? _appendUnique(_tracks, result.tracks)
            : result.tracks;
        _page = result.page;
        _hasMore = result.hasMore && result.page < 100;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = error is OnlineException
            ? error.toString()
            : '搜索失败，请检查关键词后重试。';
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  List<QqTrack> _appendUnique(List<QqTrack> current, List<QqTrack> incoming) {
    final ids = current.map((track) => track.identity).toSet();
    return List.unmodifiable([
      ...current,
      for (final track in incoming)
        if (ids.add(track.identity)) track,
    ]);
  }

  void _addToQueue(QqTrack track) {
    final added = widget.playback.append([track]);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(added == 0 ? '歌曲已在队列中' : '已加入队列')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('搜索')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: TextField(
                  key: const Key('qq-search-input'),
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => unawaited(_search()),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: '搜索歌曲、歌手或专辑',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: IconButton(
                      key: const Key('qq-search-submit'),
                      tooltip: '搜索',
                      onPressed: _loading && _query.text.trim() == _activeQuery
                          ? null
                          : () => unawaited(_search()),
                      icon: const Icon(Icons.arrow_forward_rounded),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_error case final error?)
                MaterialBanner(
                  content: Text(error),
                  leading: const Icon(Icons.error_outline_rounded),
                  actions: [
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () => unawaited(
                              _search(
                                nextPage: _page > 0 && _hasMore,
                                retry: true,
                              ),
                            ),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              Expanded(
                child: _tracks.isEmpty
                    ? _emptyState(context)
                    : AnimatedBuilder(
                        animation: widget.playback,
                        builder: (context, _) => ListView.separated(
                          key: const Key('qq-search-results'),
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 20),
                          itemCount: _tracks.length + (_hasMore ? 1 : 0),
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            if (index == _tracks.length) {
                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: OutlinedButton.icon(
                                  key: const Key('qq-search-next-page'),
                                  onPressed: _loading
                                      ? null
                                      : () =>
                                            unawaited(_search(nextPage: true)),
                                  icon: const Icon(Icons.expand_more_rounded),
                                  label: const Text('加载更多'),
                                ),
                              );
                            }
                            final track = _tracks[index];
                            return ListTile(
                              key: Key('qq-track-${track.mid}'),
                              selected:
                                  widget.playback.currentTrack?.identity ==
                                  track.identity,
                              leading: SongArtwork(track: track),
                              title: Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                [
                                  if (track.artists.isNotEmpty)
                                    track.artists.join('、'),
                                  if (track.album.isNotEmpty) track.album,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (track.durationMs != null)
                                    Text(
                                      formatPlaybackTime(
                                        Duration(
                                          milliseconds: track.durationMs!,
                                        ),
                                      ),
                                    ),
                                  PopupMenuButton<String>(
                                    tooltip: '歌曲操作',
                                    onSelected: (action) {
                                      if (action == 'queue') {
                                        _addToQueue(track);
                                      } else {
                                        unawaited(
                                          widget.playback.playQueue([track]),
                                        );
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'play',
                                        child: Text('播放'),
                                      ),
                                      PopupMenuItem(
                                        value: 'queue',
                                        child: Text('加入队列'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () =>
                                  unawaited(widget.playback.playQueue([track])),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _emptyState(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final hasSearched = _activeQuery != null;
    final failed = _error != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              failed
                  ? Icons.cloud_off_rounded
                  : hasSearched
                  ? Icons.search_off_rounded
                  : Icons.music_note_rounded,
              size: 44,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              failed
                  ? '暂时无法完成搜索'
                  : hasSearched
                  ? '没有找到相关歌曲'
                  : '搜索喜欢的音乐',
            ),
            const SizedBox(height: 6),
            Text(
              failed
                  ? '请稍后重试。'
                  : hasSearched
                  ? '试试更换关键词。'
                  : '输入歌名、歌手或专辑。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
