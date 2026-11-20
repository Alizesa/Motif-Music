import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../library/application/library_controller.dart';
import '../../library/domain/library_models.dart';

/// Minimal library management using the application's shared controller/engine.
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.controller,
    required this.onPlay,
  });

  final LibraryController controller;
  final Future<void> Function(LocalAudioFile) onPlay;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    // The controller and database belong to the application, not this route.
    super.dispose();
  }

  Future<void> _play(LocalAudioFile file) async {
    final success = await widget.controller.playFile(file.id, widget.onPlay);
    if (success && mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _remove(LibraryDirectory root) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除音乐目录？'),
        content: Text('将“${root.displayName}”从曲库移除，原始音频文件会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.controller.removeDirectory(root.id);
    }
  }

  Future<void> _changePage(bool next) async {
    final success = await (next
        ? widget.controller.nextPage()
        : widget.controller.previousPage());
    if (success && mounted && _scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final library = widget.controller;
      final theme = Theme.of(context);
      return Scaffold(
        appBar: AppBar(
          title: const Text('本地曲库'),
          actions: [
            IconButton(
              tooltip: '刷新列表',
              onPressed: library.isBusy || !library.initialized
                  ? null
                  : () => unawaited(library.refresh()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.icon(
                          key: const Key('library-add-directory'),
                          onPressed: library.isBusy || !library.initialized
                              ? null
                              : () => unawaited(library.addDirectory()),
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('添加音乐目录'),
                        ),
                        Text(
                          '${library.directories.length} 个目录 · 本页 ${library.files.length} 首',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  if (library.metadataEnabled)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (library.isReadingMetadata) ...[
                            Text(
                              '解析中：已处理 ${library.metadataProgress.processed} 首，失败 ${library.metadataProgress.failed} 首',
                            ),
                            OutlinedButton(
                              key: const Key('library-cancel-metadata'),
                              onPressed: library.isMetadataCancelling
                                  ? null
                                  : library.cancelMetadata,
                              child: Text(
                                library.isMetadataCancelling
                                    ? '正在停止读取…'
                                    : '取消解析',
                              ),
                            ),
                          ] else ...[
                            OutlinedButton(
                              key: const Key('library-resume-metadata'),
                              onPressed: library.isBusy
                                  ? null
                                  : () => unawaited(library.startMetadata()),
                              child: const Text('继续解析'),
                            ),
                            OutlinedButton(
                              key: const Key('library-retry-metadata'),
                              onPressed: library.isBusy
                                  ? null
                                  : () => unawaited(
                                      library.startMetadata(retryFailed: true),
                                    ),
                              child: const Text('重试失败项'),
                            ),
                          ],
                          if (library.metadataMessage != null)
                            Text(library.metadataMessage!),
                        ],
                      ),
                    ),
                  if (library.isBusy) const LinearProgressIndicator(),
                  if (library.isScanning)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              library.isCancelling
                                  ? '正在取消，保留已登记的曲目…'
                                  : '正在扫描，已登记 ${library.indexedFiles} 个文件',
                            ),
                          ),
                          TextButton(
                            onPressed: library.isCancelling
                                ? null
                                : library.cancelScan,
                            child: const Text('取消扫描'),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: CustomScrollView(
                      controller: _scroll,
                      slivers: [
                        if (library.errorMessage != null)
                          SliverToBoxAdapter(
                            child: _Message(
                              message: library.errorMessage!,
                              error: true,
                            ),
                          ),
                        if (library.notice != null)
                          SliverToBoxAdapter(
                            child: _Message(message: library.notice!),
                          ),
                        if (!library.initialized && !library.isInitializing)
                          SliverToBoxAdapter(
                            child: Center(
                              child: TextButton.icon(
                                onPressed: library.isBusy
                                    ? null
                                    : () => unawaited(library.initialize()),
                                icon: const Icon(Icons.refresh),
                                label: const Text('重试打开曲库'),
                              ),
                            ),
                          ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                            child: Text(
                              '音乐目录',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                        ),
                        SliverList.builder(
                          itemCount: library.directories.length,
                          itemBuilder: (context, index) {
                            final root = library.directories[index];
                            final scanning = library.activeRootId == root.id;
                            return ListTile(
                              key: ValueKey('library-root-${root.id}'),
                              leading: Icon(
                                root.isAccessible
                                    ? Icons.folder_outlined
                                    : Icons.folder_off_outlined,
                              ),
                              title: Text(
                                root.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                scanning ? '正在扫描…' : _rootState(root),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '重新扫描 ${root.displayName}',
                                    onPressed: library.isBusy
                                        ? null
                                        : () => unawaited(
                                            library.scanDirectory(root.id),
                                          ),
                                    icon: const Icon(Icons.sync_rounded),
                                  ),
                                  IconButton(
                                    tooltip: '移除 ${root.displayName}',
                                    onPressed: library.isBusy
                                        ? null
                                        : () => unawaited(_remove(root)),
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '本地音频',
                                  style: theme.textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '每页最多 100 首 · 标签和时长将在后续解析',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (library.initialized && library.files.isEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                library.directories.isEmpty
                                    ? '添加音乐目录后，即可扫描并播放本地音频。'
                                    : '暂无可访问的音频。请重新扫描目录，或再次添加原目录恢复授权。',
                              ),
                            ),
                          ),
                        SliverList.builder(
                          itemCount: library.files.length,
                          itemBuilder: (context, index) {
                            final file = library.files[index];
                            return ListTile(
                              key: ValueKey('library-file-${file.id}'),
                              leading: const Icon(Icons.audio_file_outlined),
                              title: Text(
                                file.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                _metadataSubtitle(file),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.play_arrow_rounded),
                              enabled: !library.isBusy,
                              onTap: library.isBusy
                                  ? null
                                  : () => unawaited(_play(file)),
                            );
                          },
                        ),
                        const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        OutlinedButton(
                          key: const Key('library-previous-page'),
                          onPressed: library.isBusy || !library.hasPreviousPage
                              ? null
                              : () => unawaited(_changePage(false)),
                          child: const Text('上一页'),
                        ),
                        Expanded(
                          child: Text(
                            '第 ${library.pageNumber} 页',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        OutlinedButton(
                          key: const Key('library-next-page'),
                          onPressed: library.isBusy || !library.hasNextPage
                              ? null
                              : () => unawaited(_changePage(true)),
                          child: const Text('下一页'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  static String _rootState(LibraryDirectory root) {
    if (!root.isAccessible) return '访问已失效，请再次添加同一目录恢复授权';
    return switch (root.lastScanState) {
      'complete' => '扫描完成',
      'interrupted' => '扫描已中断，可重新扫描',
      'failed' => '扫描失败，可重试；原有记录保留',
      'running' => '扫描进行中',
      _ => '尚未扫描',
    };
  }

  static String _metadataSubtitle(LocalAudioFile file) {
    final metadata = file.metadata;
    if (metadata.state == MetadataState.pending) return '标签与时长待解析';
    if (metadata.state == MetadataState.failed) return '标签解析失败，仍可尝试播放';
    final duration = metadata.durationMs;
    final seconds = duration == null ? null : duration ~/ 1000;
    final time = seconds == null
        ? '时长未知'
        : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    return [
      metadata.artist.trim().isEmpty ? '未知歌手' : metadata.artist,
      metadata.album.trim().isEmpty ? '未知专辑' : metadata.album,
      time,
      if (file.displayTitle != file.fileName) file.fileName,
    ].join(' · ');
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.message, this.error = false});
  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: error
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      message,
      style: TextStyle(
        color: error ? Theme.of(context).colorScheme.onErrorContainer : null,
      ),
    ),
  );
}
