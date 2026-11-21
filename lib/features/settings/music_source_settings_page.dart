import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../online/domain/music_source_registry.dart';
import '../../settings/online_playback_settings_controller.dart';

class MusicSourceSettingsPage extends StatefulWidget {
  const MusicSourceSettingsPage({
    super.key,
    required this.sources,
    required this.settings,
  });

  final MusicSourceRegistry sources;
  final OnlinePlaybackSettingsController settings;

  @override
  State<MusicSourceSettingsPage> createState() =>
      _MusicSourceSettingsPageState();
}

class _MusicSourceSettingsPageState extends State<MusicSourceSettingsPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.settings.initialize());
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
            animation: widget.settings,
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
                    if (widget.sources.sources.length == 1) ...[
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
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
