import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../online/domain/music_source_registry.dart';
import '../../online/lx/lx_native_worker.dart';
import '../../online/lx/lx_ordered_source.dart';
import '../../online/lx/lx_music_platform.dart';
import '../../online/lx/lx_source_manager.dart';
import '../../online/lx/lx_source_store.dart';
import '../../settings/online_playback_settings_controller.dart';

class MusicSourceSettingsPage extends StatefulWidget {
  const MusicSourceSettingsPage({
    super.key,
    required this.sources,
    required this.settings,
    this.managed,
  });

  final MusicSourceRegistry sources;
  final OnlinePlaybackSettingsController settings;
  final LxSourceManager? managed;

  @override
  State<MusicSourceSettingsPage> createState() =>
      _MusicSourceSettingsPageState();
}

class _MusicSourceSettingsPageState extends State<MusicSourceSettingsPage> {
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.settings.initialize());
    final managed = widget.managed;
    if (managed != null) unawaited(managed.initialize());
  }

  Future<void> _import(LxSourceManager manager, [String? replace]) async {
    if (_picking || manager.busy) return;
    setState(() => _picking = true);
    try {
      final Uint8List? bytes;
      if (Platform.isAndroid) {
        bytes = await pickAndroidLxScript();
      } else {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: const ['js'],
        );
        if (file != null && !file.name.toLowerCase().endsWith('.js')) {
          throw const FormatException('LX extension');
        }
        bytes = file == null
            ? null
            : await readLxScript(file.readAsByteStream());
      }
      if (!mounted || bytes == null) return;
      await manager.import(bytes, replaceId: replace);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('选取失败。请选择不超过 768 KiB 的 .js 文件。')),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _remove(LxSourceManager manager, LxStoredSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除音源？'),
        content: Text('将移除「${source.name}」并停止其播放。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) await manager.remove(source.id);
  }

  List<Widget> _scriptOptions(LxSourceManager manager) {
    final canEdit = manager.ready && !manager.busy && !_picking;
    return [
      const SizedBox(height: 24),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: canEdit ? () => unawaited(_import(manager)) : null,
          icon: const Icon(Icons.file_upload_outlined),
          label: const Text('导入音源'),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '导入后自动启用。自动换源先用 QQ，再按需用歌名和歌手到脚本支持的酷我、酷狗目录匹配同曲。不会改变队列或降低所选音质。',
        ),
      ),
      if (manager.busy || !manager.ready && manager.error == null)
        const LinearProgressIndicator(),
      for (final source in manager.sources)
        Card(
          child: Column(
            children: [
              SwitchListTile(
                key: ValueKey('source-${source.id}'),
                title: Text(source.name),
                subtitle: Text(
                  [
                    if (source.info['version'] case final version?
                        when version.isNotEmpty)
                      version,
                    for (final entry in source.capabilities.byPlatform.entries)
                      '${entry.key.label}：${entry.value.map((q) => q.label).join(' / ')}',
                  ].join(' · '),
                ),
                value: source.enabled,
                onChanged: !canEdit
                    ? null
                    : (enable) => unawaited(
                        manager.configure(source.id, enable: enable),
                      ),
              ),
              if (source.capabilities.byPlatform.length > 1 ||
                  source.platform != null)
                ListTile(
                  title: const Text('取址通道'),
                  subtitle: const Text('固定后不再尝试此脚本的其他平台。更改会停止此音源的当前任务。'),
                  trailing: DropdownButton<String>(
                    key: ValueKey('platform-${source.id}'),
                    value: source.platform?.name ?? 'auto',
                    items: [
                      const DropdownMenuItem(
                        value: 'auto',
                        child: Text('自动换源'),
                      ),
                      for (final p in LxPlatform.values)
                        if (source.capabilities.byPlatform.containsKey(p) ||
                            source.platform == p)
                          DropdownMenuItem(
                            value: p.name,
                            child: Text('仅用${p.label}'),
                          ),
                    ],
                    onChanged: !canEdit
                        ? null
                        : (value) {
                            if (value == null) return;
                            unawaited(
                              manager.selectPlatform(
                                source.id,
                                value == 'auto'
                                    ? null
                                    : LxPlatform.values.byName(value),
                              ),
                            );
                          },
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  children: [
                    TextButton(
                      onPressed: canEdit
                          ? () => unawaited(_import(manager, source.id))
                          : null,
                      child: const Text('替换脚本'),
                    ),
                    TextButton(
                      onPressed: canEdit
                          ? () => unawaited(_remove(manager, source))
                          : null,
                      child: const Text('移除'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (manager.error case final error?) ...[
        Text(error),
        if (!manager.ready)
          TextButton(
            onPressed: () => unawaited(manager.initialize()),
            child: const Text('重试'),
          ),
      ],
    ];
  }

  List<Widget> _orderEditor() {
    final settings = widget.settings;
    final available = {
      for (final s in widget.sources.orderableScripts) s.id: s.name,
    };
    final saved = settings.value.scriptOrder;
    // Keep temporarily disabled installed scripts in their positions, but drop
    // removed IDs on edit so stale records never exhaust the preference limit.
    final installed =
        widget.managed?.sources.map((s) => s.id).toSet() ??
        available.keys.toSet();
    final order = saved.where(installed.contains).toList();
    final names = {
      for (final s in widget.managed?.sources ?? const <LxStoredSource>[])
        s.id: s.name,
      ...available,
    };
    void save(List<String> next) =>
        unawaited(settings.save(settings.value.copyWith(scriptOrder: next)));
    void move(int a, int b) {
      final next = [...order];
      next.insert(b, next.removeAt(a));
      save(next);
    }

    if (available.isEmpty && order.isEmpty) return [];
    return [
      const SizedBox(height: 20),
      Text('换源顺序', style: Theme.of(context).textTheme.titleLarge),
      const Text('只尝试勾选的脚本，按从上到下的顺序。音频校验通过即停止；停用的脚本会跳过。'),
      for (final (i, id) in [
        ...order,
        ...available.keys.where((id) => !order.contains(id)),
      ].indexed)
        Row(
          children: [
            Expanded(
              child: CheckboxListTile(
                key: ValueKey('order-$id'),
                title: Text(names[id] ?? '音源'),
                subtitle: !available.containsKey(id) ? const Text('已停用') : null,
                value: order.contains(id),
                onChanged: settings.isSaving
                    ? null
                    : (on) => save(
                        on == true
                            ? [...order, id]
                            : order.where((v) => v != id).toList(),
                      ),
              ),
            ),
            if (order.contains(id)) ...[
              IconButton(
                key: ValueKey('order-up-$id'),
                tooltip: '上移',
                onPressed: settings.isSaving || i == 0
                    ? null
                    : () => move(i, i - 1),
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                key: ValueKey('order-down-$id'),
                tooltip: '下移',
                onPressed: settings.isSaving || i == order.length - 1
                    ? null
                    : () => move(i, i + 1),
                icon: const Icon(Icons.arrow_downward),
              ),
            ],
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('音源管理')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: AnimatedBuilder(
            animation: Listenable.merge([widget.settings, widget.managed]),
            builder: (context, _) {
              final settings = widget.settings;
              final primary = widget.sources.effectivePrimary(
                settings.value.preferredSourceId,
              );
              final fallback = settings.value.fallbackSourceId;
              final activeFallback =
                  fallback != null &&
                      widget.sources.contains(fallback) &&
                      fallback != primary
                  ? fallback
                  : '';
              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text('优先播放来源', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Text('优先播放匹配的本地文件；在线取址时使用以下来源。'),
                  const SizedBox(height: 16),
                  if (settings.isLoading) const LinearProgressIndicator(),
                  if (settings.isReady) ...[
                    RadioGroup<String>(
                      groupValue: primary,
                      onChanged: (id) {
                        if (id != null) {
                          unawaited(
                            settings.save(
                              settings.value.copyWith(preferredSourceId: id),
                            ),
                          );
                        }
                      },
                      child: Column(
                        children: [
                          if (widget.sources.orderableScripts.isNotEmpty ||
                              primary == lxOrderedSourceId)
                            Card(
                              child: RadioListTile<String>(
                                key: const ValueKey('preferred-ordered'),
                                value: lxOrderedSourceId,
                                title: const Text('按顺序换源'),
                                subtitle: const Text('使用下方配置的脚本顺序'),
                                enabled:
                                    !settings.isSaving &&
                                    widget.sources
                                        .orderedQualities(
                                          settings.value.scriptOrder,
                                        )
                                        .isNotEmpty,
                              ),
                            ),
                          for (final source in widget.sources.sources)
                            Card(
                              child: RadioListTile<String>(
                                key: ValueKey('preferred-${source.id}'),
                                title: Text(source.name),
                                value: source.id,
                                enabled: !settings.isSaving,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (primary != lxOrderedSourceId) ...[
                      Text(
                        '备用来源',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text('优先来源无法提供歌曲或所选音质时，尝试备用来源。'),
                      const SizedBox(height: 12),
                      RadioGroup<String>(
                        groupValue: activeFallback,
                        onChanged: (id) {
                          if (id != null) {
                            unawaited(
                              settings.save(
                                settings.value.copyWith(
                                  fallbackSourceId: id.isEmpty ? null : id,
                                  clearFallback: id.isEmpty,
                                ),
                              ),
                            );
                          }
                        },
                        child: Column(
                          children: [
                            Card(
                              child: RadioListTile<String>(
                                title: const Text('不使用备用来源'),
                                value: '',
                                enabled: !settings.isSaving,
                              ),
                            ),
                            for (final source in widget.sources.sources)
                              if (source.id != primary)
                                Card(
                                  child: RadioListTile<String>(
                                    key: ValueKey('fallback-${source.id}'),
                                    title: Text(source.name),
                                    value: source.id,
                                    enabled: !settings.isSaving,
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ],
                    ..._orderEditor(),
                    if (widget.managed == null &&
                        widget.sources.sources.length == 1) ...[
                      const SizedBox(height: 20),
                      const Text('暂无其他音源。'),
                    ],
                  ],
                  if (settings.isSaving) const Text('正在保存…'),
                  if (settings.error case final error?) ...[
                    const SizedBox(height: 16),
                    Text(error),
                    if (!settings.isReady)
                      TextButton(
                        onPressed: () => unawaited(settings.initialize()),
                        child: const Text('重试'),
                      ),
                  ],
                  if (widget.managed case final manager?)
                    ..._scriptOptions(manager),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
