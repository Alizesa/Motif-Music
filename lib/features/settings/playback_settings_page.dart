import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../settings/playback_quality_repository.dart';
import '../../settings/playback_quality_settings.dart';

class PlaybackSettingsPage extends StatefulWidget {
  const PlaybackSettingsPage({super.key, required this.repository});

  final PlaybackQualitySettingsRepository repository;

  @override
  State<PlaybackSettingsPage> createState() => _PlaybackSettingsPageState();
}

class _PlaybackSettingsPageState extends State<PlaybackSettingsPage> {
  PlaybackQualityMode? _mode;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final mode = await widget.repository.loadMode();
      if (mounted) setState(() => _mode = mode);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取播放设置，请重试。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(PlaybackQualityMode? mode) async {
    if (mode == null || _saving || _loading || mode == _mode) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repository.saveMode(mode);
      if (mounted) setState(() => _mode = mode);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重新选择。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('播放设置')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('本地播放音质', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text('同一首歌曲有多个本地版本时，按以下偏好选择。歌曲信息和时长仍需匹配。'),
              const SizedBox(height: 20),
              if (_loading) const Center(child: CircularProgressIndicator()),
              if (!_loading && _mode != null)
                RadioGroup<PlaybackQualityMode>(
                  groupValue: _mode,
                  onChanged: (mode) => unawaited(_save(mode)),
                  child: Column(
                    children: [
                      _option(
                        PlaybackQualityMode.followOnline,
                        '跟随在线播放音质',
                        '优先选择与当前在线播放音质相符的本地版本。',
                      ),
                      const SizedBox(height: 12),
                      _option(
                        PlaybackQualityMode.highestLocal,
                        '本地最高音质',
                        '优先选择能够确认音质最高的本地版本。',
                      ),
                    ],
                  ),
                ),
              if (_saving)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text('正在保存…', semanticsLabel: '正在保存播放设置'),
                ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                if (_mode == null)
                  TextButton(
                    onPressed: () => unawaited(_load()),
                    child: const Text('重试'),
                  ),
              ],
              const SizedBox(height: 24),
              const Text('音质信息不足、版本冲突或存在多个同等版本时，会请你确认。'),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _option(PlaybackQualityMode mode, String title, String subtitle) =>
      Card(
        margin: EdgeInsets.zero,
        child: RadioListTile<PlaybackQualityMode>(
          key: ValueKey('quality-${mode.name}'),
          value: mode,
          enabled: !_saving,
          selected: _mode == mode,
          contentPadding: const EdgeInsets.all(16),
          title: Text(title),
          subtitle: Text(subtitle),
        ),
      );
}
