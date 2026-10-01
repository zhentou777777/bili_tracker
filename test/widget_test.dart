// 冒烟测试：验证主题与未登录占位卡片能正常渲染。
//
// 说明：本文件原先是从 `flutter create` 模板带过来的计数器示例测试
// （`const MyApp()`），而本项目根本没有 MyApp 这个类，导致 `flutter test`
// 直接编译失败。此处改写为真正针对本项目的测试。
//
// 为什么不直接 pump 整个 TrackerApp：各页面的 initState 会读取 main.dart
// 里的全局变量 `appContext`（数据库 / 鉴权 / 通知），该变量只有在真机启动
// 的 main() 流程里才会被赋值，单元测试环境下访问会抛
// LateInitializationError。因此这里只测不依赖该全局状态的部件。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_tracker/ui/app.dart';

void main() {
  test('TrackerTheme 构建出深色主题且配色正确', () {
    final ThemeData theme = TrackerTheme.build();

    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, TrackerTheme.brand);
    expect(theme.scaffoldBackgroundColor, TrackerTheme.bg);
    expect(theme.cardTheme.color, TrackerTheme.surface);
  });

  testWidgets('未登录占位卡片渲染出提示文案与登录入口', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: LoginPrompt(message: '登录后查看今日更新')),
      ),
    );

    expect(find.text('登录后查看今日更新'), findsOneWidget);
    expect(find.text('登录 B 站账号'), findsOneWidget);
    expect(find.byIcon(Icons.login), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });
}
