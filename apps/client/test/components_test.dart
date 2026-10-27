import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:links_toolbox/core/ui/app_theme.dart';
import 'package:links_toolbox/core/ui/lt_components.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'shared controls support $brightness, narrow layout and disabled/loading states',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(brightness),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    LTButton(label: '执行', onPressed: () => taps++),
                    const LTButton(label: '禁用'),
                    LTButton(
                      label: '加载',
                      loading: true,
                      onPressed: () => taps++,
                    ),
                    const LTTextField(label: '长文字', hint: '中文English与文件路径'),
                    const LTEmptyState(title: '暂无记录', message: '等待创建真实数据'),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('执行'));
        await tester.tap(find.text('禁用'));
        await tester.tap(find.text('加载'));
        await tester.pump();
        expect(taps, 1);
        expect(
          tester.getSize(find.widgetWithText(FilledButton, '执行')).height,
          greaterThanOrEqualTo(48),
        );
        expect(tester.takeException(), isNull);
        expect(
          Theme.of(tester.element(find.byType(Scaffold))).brightness,
          brightness,
        );
      },
    );
  }
  testWidgets('confirmation has no effect until explicit confirmation', (
    tester,
  ) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => LTButton(
              label: '打开确认',
              onPressed: () async {
                answer = await ltConfirm(
                  context,
                  title: '删除记录？',
                  message: '不会自动确认。',
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开确认'));
    await tester.pumpAndSettle();
    expect(answer, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });
}
