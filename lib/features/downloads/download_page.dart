import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../downloads/download_controller.dart';
import '../../online/domain/download_source.dart';
import '../../online/domain/playback_source.dart';
import '../../online/qq/qq_track.dart';

class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key, required this.controller});
  final DownloadController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('下载管理')),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('保存目录'),
            subtitle: Text(controller.directory?.label ?? '尚未选择'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: controller.busy || controller.choosing
                ? null
                : () => unawaited(controller.chooseDirectory()),
          ),
          if (controller.error case final error?)
            Padding(padding: const EdgeInsets.all(12), child: Text(error)),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('下载时请保持应用运行。已下载的文件保存在所选目录中。'),
          ),
          if (controller.tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('从歌曲菜单选择“下载”开始')),
            ),
          for (final task in controller.tasks)
            Card(
              key: ObjectKey(task),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.track.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${task.track.artists.join('、')} · ${task.quality.label}',
                    ),
                    const SizedBox(height: 8),
                    Text(_status(task.status)),
                    if ({
                      DownloadStatus.resolving,
                      DownloadStatus.downloading,
                      DownloadStatus.saving,
                    }.contains(task.status)) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: task.total == null
                            ? null
                            : (task.received / task.total!).clamp(0.0, 1.0),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_size(task.received)}${task.total == null ? '' : ' / ${_size(task.total!)}'}',
                      ),
                    ],
                    if (task.receipt case final receipt?) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        '${task.directory.label}\n${receipt.name}',
                      ),
                    ],
                    if (task.error case final error?) Text(error),
                    if ({
                      DownloadStatus.resolving,
                      DownloadStatus.downloading,
                    }.contains(task.status))
                      TextButton(
                        onPressed: controller.cancel,
                        child: const Text('取消下载'),
                      ),
                    if (task.retryable)
                      TextButton(
                        onPressed: controller.busy || controller.choosing
                            ? null
                            : () => unawaited(controller.retry(task)),
                        child: const Text('重新下载'),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

String _status(DownloadStatus status) => switch (status) {
  DownloadStatus.resolving => '正在获取下载地址…',
  DownloadStatus.downloading => '下载中',
  DownloadStatus.saving => '正在保存文件…',
  DownloadStatus.completed => '已完成',
  DownloadStatus.cancelled => '已取消',
  DownloadStatus.failed => '下载失败',
};

String _size(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

Future<bool> showTrackDownloadSheet(
  BuildContext context, {
  required DownloadController controller,
  required QqTrack track,
  required String preferredSourceId,
  required OnlineQuality quality,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DownloadSheet(
        controller: controller,
        track: track,
        preferredSourceId: preferredSourceId,
        quality: quality,
      ),
    ) ??
    false;

class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({
    required this.controller,
    required this.track,
    required this.preferredSourceId,
    required this.quality,
  });
  final DownloadController controller;
  final QqTrack track;
  final String preferredSourceId;
  final OnlineQuality quality;
  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  String? _source;
  late OnlineQuality _quality;
  @override
  void initState() {
    super.initState();
    final sources = widget.controller.sources.downloadSources;
    _source = sources.any((source) => source.id == widget.preferredSourceId)
        ? widget.preferredSourceId
        : sources.firstOrNull?.id;
    _quality = widget.quality;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final sources = controller.sources.downloadSources;
      final source = sources.where((item) => item.id == _source).firstOrNull;
      final qualities = source == null
          ? <OnlineQuality>[]
          : OnlineQuality.values
                .where(
                  (quality) => (source.resolver as TrackDownloadSource)
                      .downloadQualities
                      .contains(quality),
                )
                .toList();
      if (!qualities.contains(_quality) && qualities.isNotEmpty) {
        _quality = qualities.first;
      }
      final busy = controller.busy || controller.choosing;
      return SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('下载歌曲', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              Text(widget.track.title),
              const SizedBox(height: 16),
              if (sources.isEmpty)
                const Text('请先在“设置 → 音源管理”导入并启用一个音源。')
              else ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: source?.id,
                  decoration: const InputDecoration(labelText: '下载音源'),
                  items: [
                    for (final item in sources)
                      DropdownMenuItem(
                        value: item.id,
                        child: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: busy
                      ? null
                      : (value) => setState(() => _source = value),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<OnlineQuality>(
                  key: ValueKey('download-quality-$_source-$_quality'),
                  initialValue: qualities.contains(_quality) ? _quality : null,
                  decoration: const InputDecoration(labelText: '音质'),
                  items: [
                    for (final value in qualities)
                      DropdownMenuItem(value: value, child: Text(value.label)),
                  ],
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value != null) setState(() => _quality = value);
                        },
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => unawaited(controller.chooseDirectory()),
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(controller.directory?.label ?? '选择保存目录'),
              ),
              if (controller.error case final error?) Text(error),
              if (controller.busy) const Text('已有一首歌曲正在下载，请完成或取消后再试。'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed:
                    busy ||
                        source == null ||
                        qualities.isEmpty ||
                        controller.directory == null
                    ? null
                    : () {
                        unawaited(
                          controller.start(widget.track, source.id, _quality),
                        );
                        Navigator.of(context).pop(true);
                      },
                icon: const Icon(Icons.download_rounded),
                label: const Text('开始下载'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
