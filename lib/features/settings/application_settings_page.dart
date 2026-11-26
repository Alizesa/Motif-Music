import 'package:material_ui/material_ui.dart';

class ApplicationSettingsPage extends StatelessWidget {
  const ApplicationSettingsPage({
    super.key,
    required this.onOpenQuality,
    required this.onOpenSources,
    required this.onOpenAudioTest,
    required this.onOpenDiagnostics,
  });

  final VoidCallback onOpenQuality;
  final VoidCallback onOpenSources;
  final VoidCallback onOpenAudioTest;
  final VoidCallback onOpenDiagnostics;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.high_quality_outlined),
                      title: const Text('播放音质'),
                      subtitle: const Text('在线音质与本地版本选择'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: onOpenQuality,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('settings-source-management'),
                      leading: const Icon(Icons.extension_outlined),
                      title: const Text('音源管理'),
                      subtitle: const Text('优先播放来源与备用来源'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: onOpenSources,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.graphic_eq_rounded),
                      title: const Text('音频测试'),
                      subtitle: const Text('播放、均衡器与前级'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: onOpenAudioTest,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const Key('settings-diagnostics'),
                      leading: const Icon(Icons.bug_report_outlined),
                      title: const Text('调试与诊断'),
                      subtitle: const Text('记录并导出播放和下载问题'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: onOpenDiagnostics,
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
}
