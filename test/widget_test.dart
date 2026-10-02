// 主题系统的冒烟测试。
//
// 说明：本文件原先是从 `flutter create` 模板带过来的计数器示例测试
// （`const MyApp()`），而本项目根本没有 MyApp 这个类，导致 `flutter test`
// 直接编译失败。此处改写为真正针对本项目的测试。
//
// 为什么不直接 pump 整个 TrackerApp：各页面的 initState 会读取 main.dart
// 里的全局变量 `appContext`（数据库 / 鉴权 / 通知），该变量只有在真机启动
// 的 main() 流程里才会被赋值，单元测试环境下访问会抛
// LateInitializationError。因此这里只测不依赖该全局状态的部件。
//
// 阶段 E 之后这里额外承担一件事：**守住浅色/深色两套配色都不退化**。
// 颜色是这次从「静态常量」搬到「主题扩展」的，一旦搬错，界面上不会崩，
// 只会「看着不对」—— 那种问题最难在事后发现，所以用测试钉住几个关键槽位。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_tracker/ui/app.dart';
import 'package:bili_tracker/ui/theme.dart';
// 共用组件在 widgets.dart 里，不在 app.dart —— 漏了这个 import 会让本文件
// 连编译都过不去，`flutter test` 报 Some tests failed（本文件 13 个用例全部不执行）。
import 'package:bili_tracker/ui/widgets.dart';

void main() {
  test('深色主题：亮度、主色、底色、卡片色都对', () {
    final ThemeData theme = buildTrackerTheme(AppColors.dark);

    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, AppColors.dark.brand);
    expect(theme.scaffoldBackgroundColor, AppColors.dark.bg);
    expect(theme.cardTheme.color, AppColors.dark.surface);
  });

  test('浅色主题：亮度、主色、底色、卡片色都对', () {
    final ThemeData theme = buildTrackerTheme(AppColors.light);

    expect(theme.brightness, Brightness.light);
    expect(theme.colorScheme.primary, AppColors.light.brand);
    expect(theme.scaffoldBackgroundColor, AppColors.light.bg);
    expect(theme.cardTheme.color, AppColors.light.surface);
  });

  test('两套配色都注册进了 ThemeData.extensions（否则 context.c 会拿不到）', () {
    expect(buildTrackerTheme(AppColors.dark).extension<AppColors>(),
        AppColors.dark);
    expect(buildTrackerTheme(AppColors.light).extension<AppColors>(),
        AppColors.light);
  });

  test('浅色不用 B 站原版粉：白底上那支对比度只有约 2.2:1，看不清', () {
    expect(AppColors.light.brand, isNot(AppColors.dark.brand));
    // 浅色主题的主色应当比深色主题更深（亮度更低）
    expect(AppColors.light.brand.computeLuminance(),
        lessThan(AppColors.dark.brand.computeLuminance()));
  });

  test('浅底色比深底色的亮度高（确认两套没有写反）', () {
    expect(AppColors.light.bg.computeLuminance(),
        greaterThan(AppColors.dark.bg.computeLuminance()));
    expect(AppColors.light.textPrimary.computeLuminance(),
        lessThan(AppColors.dark.textPrimary.computeLuminance()));
  });

  test('主题色是「可插值」的，切换时是渐变而不是硬闪', () {
    final AppColors mid = AppColors.dark.lerp(AppColors.light, 0.5);
    expect(mid.bg.computeLuminance(),
        greaterThan(AppColors.dark.bg.computeLuminance()));
    expect(mid.bg.computeLuminance(),
        lessThan(AppColors.light.bg.computeLuminance()));
    // 0.5 是边界：isDark 取后半段
    expect(mid.isDark, isFalse);
    expect(AppColors.dark.lerp(AppColors.light, 0.0).bg, AppColors.dark.bg);
    expect(AppColors.dark.lerp(AppColors.light, 1.0).bg, AppColors.light.bg);
  });

  test('copyWith 只改指定槽位', () {
    final AppColors changed = AppColors.dark.copyWith(brand: Colors.green);
    expect(changed.brand, Colors.green);
    expect(changed.bg, AppColors.dark.bg);
    expect(changed.textPrimary, AppColors.dark.textPrimary);
  });

  test('默认主题模式是「跟随系统」', () {
    expect(ThemeController().value, ThemeMode.system);
  });

  test('主题模式读写：三个值都能正确往返', () async {
    final ThemeController c = ThemeController();
    await c.setMode(ThemeMode.light);
    expect(c.value, ThemeMode.light);
    await c.setMode(ThemeMode.dark);
    expect(c.value, ThemeMode.dark);
    await c.setMode(ThemeMode.system);
    expect(c.value, ThemeMode.system);
  });

  testWidgets('未登录占位卡片在浅色与深色下都能渲染', (WidgetTester tester) async {
    for (final AppColors colors in <AppColors>[
      AppColors.light,
      AppColors.dark,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTrackerTheme(colors),
          home: const Scaffold(body: LoginPrompt(message: '登录后查看今日更新')),
        ),
      );

      expect(find.text('需要先登录 B 站'), findsOneWidget);
      expect(find.text('登录后查看今日更新'), findsOneWidget);
      expect(find.text('登录 B 站账号'), findsOneWidget);
      expect(find.byIcon(Icons.login), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    }
  });

  testWidgets('context.c 在两种主题下解析出各自的配色', (WidgetTester tester) async {
    late AppColors seen;

    Widget probe(AppColors theme) => MaterialApp(
          theme: buildTrackerTheme(theme),
          home: Builder(
            builder: (BuildContext context) {
              seen = context.c;
              return const SizedBox.shrink();
            },
          ),
        );

    await tester.pumpWidget(probe(AppColors.light));
    expect(seen.bg, AppColors.light.bg);
    expect(seen.isDark, isFalse);

    await tester.pumpWidget(probe(AppColors.dark));
    expect(seen.bg, AppColors.dark.bg);
    expect(seen.isDark, isTrue);
  });

  testWidgets('底部导航在浅色主题下也能正常渲染（M3 NavigationBar）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTrackerTheme(AppColors.light),
        // 注意两处 const 的写法：
        // - `NavigationBar` **没有** const 构造函数（Flutter SDK 里有明确说明：
        //   "This class cannot be const constructed"），所以外层不能加 const；
        // - 但 `NavigationDestination` **有**，所以 destinations 那个列表可以整体
        //   写成 const，元素随之隐式 const（否则 prefer_const_constructors 会报警）。
        home: Scaffold(
          body: const SizedBox.shrink(),
          bottomNavigationBar: NavigationBar(
            selectedIndex: 0,
            destinations: const <NavigationDestination>[
              NavigationDestination(icon: Icon(Icons.bolt), label: '今日'),
              NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('共用组件 AppCard / SectionTitle / TagChip / EmptyState 可渲染',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTrackerTheme(AppColors.light),
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const SectionTitle(title: '开播中', icon: Icons.podcasts),
              AppCard(
                onTap: () {},
                accent: AppColors.light.live,
                child: const Row(
                  children: <Widget>[
                    TagChip(label: '直播', icon: Icons.circle),
                    SizedBox(width: 8),
                    Text('标题'),
                  ],
                ),
              ),
              const EmptyState(
                icon: Icons.inbox_outlined,
                title: '还没有内容',
                description: '去「UP 主」页添加追更对象',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('开播中'), findsOneWidget);
    expect(find.text('直播'), findsOneWidget);
    expect(find.text('还没有内容'), findsOneWidget);
    expect(find.text('去「UP 主」页添加追更对象'), findsOneWidget);
  });
}
