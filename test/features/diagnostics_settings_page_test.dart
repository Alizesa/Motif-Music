import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/diagnostics/diagnostic_recorder.dart';
import 'package:motif/features/settings/diagnostics_settings_page.dart';

void main() {
  testWidgets('records only after switch-on and requires a user export', (
    tester,
  ) async {
    final recorder = DiagnosticRecorder();
    addTearDown(recorder.dispose);
    final outputs = <DiagnosticReport>[];
    final save = Completer<bool>();
    await tester.pumpWidget(
      MaterialApp(
        home: DiagnosticsSettingsPage(
          recorder: recorder,
          snapshot: () => {
            DiagnosticSection.playback: {DiagnosticField.hasMedia: true},
          },
          save: (report) {
            outputs.add(report);
            return save.future;
          },
        ),
      ),
    );
    final exportButton = find.widgetWithText(FilledButton, '导出诊断报告');
    final toggle = find.byType(SwitchListTile);
    expect(tester.widget<FilledButton>(exportButton).onPressed, isNull);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(recorder.enabled, isTrue);
    recorder.record(DiagnosticEvent.nativeBuffering, {
      DiagnosticField.buffering: true,
    });
    expect(outputs, isEmpty);
    await tester.tap(exportButton);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
    expect(outputs, hasLength(1));
    final report = jsonDecode(utf8.decode(outputs.single.bytes)) as Map;
    expect(report['retainedEvents'], 1);
    expect(report['snapshot']['playback']['hasMedia'], isTrue);
    save.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('诊断报告已保存，可手动发送给开发者。'), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(exportButton).onPressed, isNull);
    expect(recorder.enabled, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a cancelled save keeps recording, an error is safe and clearing leaves capture on',
    (tester) async {
      final recorder = DiagnosticRecorder()..setEnabled(true);
      addTearDown(recorder.dispose);
      recorder.record(DiagnosticEvent.nativeEnd);
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DiagnosticsSettingsPage(
            recorder: recorder,
            snapshot: () => {},
            save: (_) async {
              if (++calls == 1) return false;
              throw StateError('sensitive-path');
            },
          ),
        ),
      );
      final exportButton = find.widgetWithText(FilledButton, '导出诊断报告');
      await tester.tap(exportButton);
      await tester.pumpAndSettle();
      expect(find.textContaining('诊断报告已保存'), findsNothing);
      expect(find.text('已取消导出，记录仍保留。'), findsOneWidget);
      await tester.tap(exportButton);
      await tester.pumpAndSettle();
      expect(find.text('无法保存诊断报告，请选择可写位置后重试。'), findsOneWidget);
      expect(find.textContaining('sensitive-path'), findsNothing);
      await tester.tap(find.text('清空本次记录'));
      await tester.pumpAndSettle();
      expect(
        (jsonDecode(utf8.decode(recorder.export({}).bytes)) as Map)['events'],
        isEmpty,
      );
      expect(recorder.enabled, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
