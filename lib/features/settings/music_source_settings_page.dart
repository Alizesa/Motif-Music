import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../online/domain/music_source_registry.dart';
import '../../online/lx/lx_native_worker.dart';
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

  Future<void> _configure(
    LxSourceManager manager,
    LxStoredSource source, {
    required bool enable,
  }) async {
    final grant = await showDialog<LxSourceGrant>(
      context: context,
      builder: (_) => _GrantDialog(source: source, enable: enable),
    );
    if (!mounted || grant == null) return;
    await manager.configure(
      source.id,
      grant: grant,
      enable: enable || source.enabled,
    );
  }

  Future<void> _remove(LxSourceManager manager, LxStoredSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除音源？'),
        content: Text('将移除「${source.name}」及其域名授权。'),
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
                    if (source.qualities.isNotEmpty)
                      source.qualities
                          .map((quality) => quality.label)
                          .join(' / '),
                  ].join(' · '),
                ),
                value: source.enabled,
                onChanged: !canEdit
                    ? null
                    : (enable) {
                        if (enable) {
                          unawaited(_configure(manager, source, enable: true));
                        } else {
                          unawaited(
                            manager.configure(
                              source.id,
                              grant: source.grant,
                              enable: false,
                            ),
                          );
                        }
                      },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  children: [
                    TextButton(
                      onPressed: canEdit
                          ? () => unawaited(
                              _configure(manager, source, enable: false),
                            )
                          : null,
                      child: const Text('域名授权'),
                    ),
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
                    Text('备用来源', style: Theme.of(context).textTheme.titleLarge),
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

class _GrantDialog extends StatefulWidget {
  const _GrantDialog({required this.source, required this.enable});
  final LxStoredSource source;
  final bool enable;

  @override
  State<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends State<_GrantDialog> {
  late final _api = TextEditingController(
    text: widget.source.grant.api.join('\n'),
  );
  late final _media = TextEditingController(
    text: widget.source.grant.media.join('\n'),
  );
  String? _error;

  @override
  void dispose() {
    _api.dispose();
    _media.dispose();
    super.dispose();
  }

  void _save() {
    Iterable<String> split(String text) =>
        text.split(RegExp(r'[\s,，]+')).where((part) => part.isNotEmpty);
    try {
      final grant = LxSourceGrant(
        api: split(_api.text),
        media: split(_media.text),
      );
      Navigator.pop(context, grant);
    } on FormatException {
      setState(() => _error = '请输入完整域名，每类最多 8 个。');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.enable ? '启用${widget.source.name}' : '域名授权'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('填写允许此音源访问的域名，每行一个。留空表示不授权。'),
            const SizedBox(height: 12),
            TextField(
              controller: _api,
              decoration: const InputDecoration(labelText: '取址 API 域名'),
              minLines: 1,
              maxLines: 3,
              maxLength: 2048,
              autocorrect: false,
            ),
            TextField(
              controller: _media,
              decoration: const InputDecoration(labelText: '媒体域名'),
              minLines: 1,
              maxLines: 3,
              maxLength: 2048,
              autocorrect: false,
            ),
            if (_error case final error?) Text(error),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(onPressed: _save, child: Text(widget.enable ? '授权并启用' : '保存')),
    ],
  );
}
