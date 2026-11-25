import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../online/qq/auth/qq_session_manager.dart';
import '../../online/qq/qq_home_controller.dart';
import '../../online/qq/qq_home_models.dart';
import '../player/catalog_player_widgets.dart';

class MotifHomeTab extends StatelessWidget {
  const MotifHomeTab({
    super.key,
    required this.onOpenSearch,
    this.controller,
    this.onLogin,
    this.onDaily,
    this.onRadio,
    this.onRedHeart,
    this.onPlaylist,
    this.onSong,
  });
  final VoidCallback onOpenSearch;
  final QqHomeController? controller;
  final VoidCallback? onLogin;
  final VoidCallback? onDaily;
  final VoidCallback? onRadio;
  final VoidCallback? onRedHeart;
  final void Function(QqPlaylist)? onPlaylist;
  final void Function(QqRecommendedSong)? onSong;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Motif'),
      actions: [
        IconButton(
          tooltip: '账号',
          onPressed: onLogin,
          icon: const Icon(Icons.person_outline_rounded),
        ),
        if (controller?.sessions.account != null)
          IconButton(
            tooltip: '刷新推荐',
            onPressed: () => unawaited(controller!.refresh()),
            icon: const Icon(Icons.refresh_rounded),
          ),
      ],
    ),
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                key: const Key('home-search-entry'),
                borderRadius: BorderRadius.circular(18),
                onTap: onOpenSearch,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Icon(Icons.search_rounded),
                      SizedBox(width: 12),
                      Expanded(child: Text('搜索歌曲、歌手或专辑')),
                      Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text('为你推荐', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            _FeaturedCarousel(
              controller: controller,
              onDaily: onDaily,
              onRadio: onRadio,
              onRedHeart: onRedHeart,
            ),
            const SizedBox(height: 24),
            if (controller?.sessions.account != null)
              _SongRecommendations(controller: controller!, onSong: onSong)
            else
              const _EmptyRecommendationShelf(
                title: '歌曲推荐',
                icon: Icons.music_note_rounded,
              ),
            const SizedBox(height: 24),
            if (controller?.sessions.account != null)
              _PlaylistRecommendations(
                controller: controller!,
                onPlaylist: onPlaylist,
              )
            else
              const _EmptyRecommendationShelf(
                title: '个性化歌单',
                icon: Icons.queue_music_rounded,
              ),
          ],
        ),
      ),
    ),
  );
}

class _FeaturedCarousel extends StatefulWidget {
  const _FeaturedCarousel({
    this.controller,
    this.onDaily,
    this.onRadio,
    this.onRedHeart,
  });
  final QqHomeController? controller;
  final VoidCallback? onDaily;
  final VoidCallback? onRadio;
  final VoidCallback? onRedHeart;
  @override
  State<_FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class _FeaturedCarouselState extends State<_FeaturedCarousel> {
  final _controller = PageController(viewportFraction: 0.94);
  int _page = 0;
  static const _cards = [
    ('每日推荐', '30 首', Icons.today_rounded, '每天为你精选'),
    ('猜你喜欢', '每批 20 首', Icons.auto_awesome_rounded, '让喜欢的旋律继续'),
    ('红心歌单', '50 首', Icons.favorite_rounded, '收藏此刻的心动'),
  ];
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.5);
    final loggedIn = widget.controller?.sessions.account != null;
    final actions = [widget.onDaily, widget.onRadio, widget.onRedHeart];
    return Column(
      children: [
        SizedBox(
          height: 180 * scale,
          child: PageView.builder(
            key: const Key('home-featured-carousel'),
            controller: _controller,
            onPageChanged: (index) => setState(() => _page = index),
            itemCount: _cards.length,
            itemBuilder: (context, index) {
              final (title, count, icon, subtitle) = _cards[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  key: ValueKey('home-featured-$index'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: actions[index],
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(icon, color: theme.colorScheme.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                title,
                                style: theme.textTheme.titleLarge,
                              ),
                            ),
                          ],
                        ),
                        Text(count, style: theme.textTheme.headlineSmall),
                        Text(subtitle),
                        Text(
                          loggedIn ? '查看歌曲' : '登录后查看',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var index = 0; index < _cards.length; index++)
              Semantics(
                label: '${_cards[index].$1}，第 ${index + 1} 页',
                selected: _page == index,
                button: true,
                child: InkWell(
                  onTap: () => _controller.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOut,
                  ),
                  child: SizedBox(
                    width: 40,
                    height: 32,
                    child: Center(
                      child: Container(
                        width: _page == index ? 20 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _page == index
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _SongRecommendations extends StatelessWidget {
  const _SongRecommendations({required this.controller, this.onSong});
  final QqHomeController controller;
  final void Function(QqRecommendedSong)? onSong;
  @override
  Widget build(BuildContext context) {
    final shelves = controller.feed?.shelves ?? [];
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('歌曲推荐', style: Theme.of(context).textTheme.titleLarge),
        if (controller.loading('feed')) const LinearProgressIndicator(),
        if (controller.error('feed') case final error?)
          _RetryMessage(
            message: error,
            onRetry: () => unawaited(controller.retry('feed')),
          ),
        if (shelves.isEmpty && !controller.loading('feed'))
          const Padding(padding: EdgeInsets.all(16), child: Text('暂无歌曲推荐')),
        for (final shelf in shelves) ...[
          const SizedBox(height: 12),
          if (shelf.title.isNotEmpty)
            Text(shelf.title, style: Theme.of(context).textTheme.titleMedium),
          SizedBox(
            height: 228 * scale,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: shelf.pages.length,
              itemBuilder: (context, index) => SizedBox(
                width: 340,
                child: Card(
                  child: Column(
                    children: [
                      for (final song in shelf.pages[index])
                        Expanded(
                          child: ListTile(
                            leading: song.track != null
                                ? SongArtwork(track: song.track)
                                : _Cover(uri: song.artwork, size: 44),
                            title: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              song.artists.join('、'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: onSong == null ? null : () => onSong!(song),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        if (controller.feed?.hasMore == true)
          TextButton(
            onPressed: controller.loading('feed')
                ? null
                : () => unawaited(controller.moreFeed()),
            child: const Text('更多推荐'),
          ),
      ],
    );
  }
}

class _PlaylistRecommendations extends StatelessWidget {
  const _PlaylistRecommendations({required this.controller, this.onPlaylist});
  final QqHomeController controller;
  final void Function(QqPlaylist)? onPlaylist;
  @override
  Widget build(BuildContext context) {
    final unique = <String, QqPlaylist>{};
    for (final playlist in [
      ...controller.playlists,
      ...?controller.feed?.playlists,
    ]) {
      unique.putIfAbsent(playlist.id, () => playlist);
    }
    final items = unique.values.toList();
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('个性化歌单', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (controller.loading('playlists')) const LinearProgressIndicator(),
        if (controller.error('playlists') case final error?)
          _RetryMessage(
            message: error,
            onRetry: () => unawaited(controller.retry('playlists')),
          ),
        if (items.isEmpty && !controller.loading('playlists'))
          const Padding(padding: EdgeInsets.all(16), child: Text('暂无推荐歌单')),
        if (items.isNotEmpty)
          SizedBox(
            height: 220 * scale,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final playlist = items[index];
                return SizedBox(
                  width: 176,
                  child: Card(
                    child: InkWell(
                      onTap: onPlaylist == null
                          ? null
                          : () => onPlaylist!(playlist),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Cover(uri: playlist.artwork, size: 128),
                            const SizedBox(height: 10),
                            Text(
                              playlist.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (playlist.subtitle.isNotEmpty)
                              Text(
                                playlist.subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({this.uri, required this.size});
  final Uri? uri;
  final double size;
  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Center(child: Icon(Icons.music_note_rounded)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox.square(
        dimension: size,
        child: uri == null
            ? placeholder
            : Image.network(
                uri.toString(),
                fit: BoxFit.cover,
                cacheWidth: 256,
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

class _RetryMessage extends StatelessWidget {
  const _RetryMessage({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

class _EmptyRecommendationShelf extends StatelessWidget {
  const _EmptyRecommendationShelf({required this.title, required this.icon});
  final String title;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      SizedBox(
        height: 120 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.5),
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            SizedBox(
              width: 280,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(icon, size: 30),
                      const SizedBox(width: 14),
                      const Expanded(child: Text('登录后查看为你推荐的音乐')),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class MotifMyTab extends StatelessWidget {
  const MotifMyTab({
    super.key,
    required this.onOpenLibrary,
    required this.onOpenPlayer,
    required this.onOpenSettings,
    this.onOpenDownloads,
    this.sessions,
    this.onOpenAccount,
  });
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenPlayer;
  final VoidCallback onOpenSettings;
  final VoidCallback? onOpenDownloads;
  final QqSessionManager? sessions;
  final VoidCallback? onOpenAccount;
  @override
  Widget build(BuildContext context) {
    final account = sessions?.account;
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: ListTile(
                  key: const Key('my-qq-account'),
                  onTap: onOpenAccount,
                  leading: CircleAvatar(
                    backgroundImage: account?.avatar == null
                        ? null
                        : NetworkImage(account!.avatar.toString()),
                    child: account?.avatar == null
                        ? const Icon(Icons.person_outline_rounded)
                        : null,
                  ),
                  title: Text(account?.name ?? 'QQ 音乐账号'),
                  subtitle: Text(
                    account == null ? (sessions?.error ?? '未登录') : 'QQ 音乐账号',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                ),
              ),
              const SizedBox(height: 24),
              Text('我的音乐', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      key: const Key('my-local-library'),
                      leading: const Icon(Icons.library_music_outlined),
                      title: const Text('本地曲库'),
                      subtitle: const Text('管理目录并浏览本机音乐'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: onOpenLibrary,
                    ),
                    if (onOpenDownloads != null) ...[
                      const Divider(height: 1),
                      ListTile(
                        key: const Key('my-downloads'),
                        leading: const Icon(Icons.download_outlined),
                        title: const Text('下载管理'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: onOpenDownloads,
                      ),
                    ],
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.play_circle_outline_rounded),
                      title: const Text('播放器'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: onOpenPlayer,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Card(
                child: ListTile(
                  key: const Key('my-settings'),
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('设置'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: onOpenSettings,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
