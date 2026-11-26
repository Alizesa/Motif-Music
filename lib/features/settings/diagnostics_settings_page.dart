import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../diagnostics/diagnostic_recorder.dart';

typedef DiagnosticSave = Future<bool> Function(DiagnosticReport report);
typedef DiagnosticSnapshot = Map<DiagnosticSection, DiagnosticFacts> Function();

Future<bool> _saveReport(DiagnosticReport report) async =>
    await FilePicker.saveFile(
      fileName: report.fileName,
      bytes: report.bytes,
      mimeType: 'application/json',
      dialogTitle: '保存诊断报告',
    ) !=
    null;

class DiagnosticsSettingsPage extends StatefulWidget {
  const DiagnosticsSettingsPage({
    super.key,
    required this.recorder,
    required this.snapshot,
    this.save,
  });

  final DiagnosticRecorder recorder;
  final DiagnosticSnapshot snapshot;
  final DiagnosticSave? save;

  @override
  State<DiagnosticsSettingsPage> createState() =>
      _DiagnosticsSettingsPageState();
}

class _DiagnosticsSettingsPageState extends State<DiagnosticsSettingsPage> {
  bool _saving = false;
  String? _result;

  Future<void> _export() async {
    if (_saving || !widget.recorder.enabled) return;
    setState(() {
      _saving = true;
      _result = null;
    });
    String? result;
    try {
      final report = widget.recorder.export(widget.snapshot());
      result = await (widget.save ?? _saveReport)(report)
          ? '诊断报告已保存，可手动发送给开发者。'
          : '已取消导出，记录仍保留。';
    } catch (_) {
      result = '无法保存诊断报告，请选择可写位置后重试。';
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _result = result;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('调试与诊断')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              AnimatedBuilder(
                animation: widget.recorder,
                builder: (context, _) {
                  final enabled = widget.recorder.enabled;
                  return SwitchListTile(
                    title: const Text('记录诊断信息'),
                    subtitle: Text(enabled ? '仅记录开启后的活动' : '未记录'),
                    value: enabled,
                    onChanged: _saving
                        ? null
                        : (value) {
                            widget.recorder.setEnabled(value);
                            setState(() => _result = null);
                          },
                  );
                },
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('开启后返回播放器复现问题，再到这里导出报告。仅保留近期事件，关闭记录或退出应用即清空。'),
              ),
              const Text(
                '报告包含设备环境、取址、缓冲、解码与下载状态，不含歌曲名、链接、账号凭据、音源脚本或本地路径。不会自动上传。',
              ),
              const SizedBox(height: 16),
              AnimatedBuilder(
                animation: widget.recorder,
                builder: (context, _) {
                  final canEdit = widget.recorder.enabled && !_saving;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                        onPressed: canEdit ? _export : null,
                        icon: const Icon(Icons.save_alt),
                        label: Text(_saving ? '正在保存…' : '导出诊断报告'),
                      ),
                      TextButton(
                        onPressed: canEdit
                            ? () {
                                widget.recorder.clear();
                                setState(() => _result = '已清空本次记录。');
                              }
                            : null,
                        child: const Text('清空本次记录'),
                      ),
                    ],
                  );
                },
              ),
              if (_result case final result?)
                Semantics(liveRegion: true, child: Text(result)),
            ],
          ),
        ),
      ),
    ),
  );
}
