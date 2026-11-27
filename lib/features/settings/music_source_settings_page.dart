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
import '../../settings/online_playback_preferences.dart';
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
  OnlinePlaybackPreferences? _draft;

  Future<void> _select(String primary, List<String> backups) async {
    final settings = widget.settings;
    if (_draft != null || settings.isSaving || !settings.isReady) return;
    final next = settings.value.copyWith(
      preferredSourceId: primary,
      fallbackOrder: backups,
    );
    // Reflect the drop immediately. The controller only publishes committed
    // preferences; clearing this draft also restores them if writing fails.
    setState(() => _draft = next);
    try {
      await settings.save(next);
    } finally {
      if (mounted) setState(() => _draft = null);
    }
  }

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
      if (manager.busy || !manager.ready && manager.error == null)
        const LinearProgressIndicator(),
      if (manager.sources.isNotEmpty)
        ExpansionTile(
          key: const PageStorageKey('manage-scripts'),
          tilePadding: EdgeInsets.zero,
          title: Text('管理已导入的音源（${manager.sources.length}）'),
          children: [
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
                          for (final entry
                              in source.capabilities.byPlatform.entries)
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
                              if (source.capabilities.byPlatform.containsKey(
                                    p,
                                  ) ||
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
          ],
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

  Widget _sourceList(BuildContext context) {
    final settings = widget.settings;
    final manager = widget.managed;
    final prefs = _draft ?? settings.value;
    final primary =
        prefs.fallbackOrder == null &&
            prefs.preferredSourceId != lxOrderedSourceId
        ? widget.sources.effectivePrimary(prefs.preferredSourceId)
        : prefs.selectedPrimary;
    final active = {
      for (final source in widget.sources.sources) source.id: source.name,
    };
    final names = {
      for (final source in manager?.sources ?? const <LxStoredSource>[])
        source.id: source.name,
      ...active,
    };
    // Keep checked, temporarily disabled scripts in their positions. Removed
    // scripts disappear without enrolling their replacements.
    final checked = prefs.selectedBackups
        .where((id) => id != primary && names.containsKey(id))
        .toSet()
        .toList();
    final unchecked = active.keys.where(
      (id) => id != primary && !checked.contains(id),
    );
    final canEdit =
        settings.isReady &&
        !settings.isSaving &&
        _draft == null &&
        (manager == null || (manager.ready && !manager.busy));
    Widget choice(String id, bool selected) => CheckboxListTile(
      key: ValueKey('backup-$id'),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      title: Text(names[id]!, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: active.containsKey(id) ? null : const Text('已停用，尝试时跳过'),
      value: selected,
      onChanged: !canEdit || primary == null
          ? null
          : (on) => unawaited(
              _select(
                primary,
                on == true
                    ? [...checked, id]
                    : checked.where((v) => v != id).toList(),
              ),
            ),
    );
    return ReorderableListView(
      padding: const EdgeInsets.all(20),
      buildDefaultDragHandles: false,
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (settings.isLoading) const LinearProgressIndicator(),
          if (settings.isReady) ...[
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '优先播放来源',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  key: const ValueKey('primary-source'),
                  value: primary != null && names.containsKey(primary)
                      ? primary
                      : null,
                  hint: Text(primary == null ? '选择优先来源' : '原优先来源不可用，请重选'),
                  isExpanded: true,
                  isDense: true,
                  items: [
                    if (primary != null &&
                        names.containsKey(primary) &&
                        !active.containsKey(primary))
                      DropdownMenuItem(
                        value: primary,
                        enabled: false,
                        child: Text(
                          '${names[primary]}（已停用）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    for (final e in active.entries)
                      DropdownMenuItem(
                        value: e.key,
                        child: Text(
                          e.value,
                          key: ValueKey('primary-option-${e.key}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: !canEdit
                      ? null
                      : (id) {
                          if (id != null && id != primary) {
                            unawaited(_select(id, checked));
                          }
                        },
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text('备用来源', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              checked.isEmpty && unchecked.isEmpty
                  ? '暂无其他可选音源。'
                  : '勾选后从上到下尝试，拖动手柄可调整顺序。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      onReorderItem: (from, to) {
        if (!canEdit ||
            primary == null ||
            from == to ||
            from < 0 ||
            to < 0 ||
            from >= checked.length ||
            to >= checked.length) {
          return;
        }
        final next = [...checked];
        next.insert(to, next.removeAt(from));
        unawaited(_select(primary, next));
      },
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (settings.isReady)
            for (final id in unchecked) choice(id, false),
          if (settings.isSaving) const LinearProgressIndicator(),
          if (settings.error case final error?) ...[
            Text(error),
            if (!settings.isReady)
              TextButton(
                onPressed: () => unawaited(settings.initialize()),
                child: const Text('重试'),
              ),
          ],
          if (manager != null) ..._scriptOptions(manager),
        ],
      ),
      children: [
        if (settings.isReady)
          for (final (i, id) in checked.indexed)
            Row(
              key: ValueKey('backup-row-$id'),
              children: [
                Expanded(child: choice(id, true)),
                if (checked.length > 1)
                  ReorderableDragStartListener(
                    key: ValueKey('drag-$id'),
                    index: i,
                    enabled: canEdit,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Tooltip(
                        message: '拖动排序',
                        child: SizedBox.square(
                          dimension: 48,
                          child: Icon(
                            Icons.drag_handle,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
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
            builder: (context, _) => _sourceList(context),
          ),
        ),
      ),
    ),
  );
}
