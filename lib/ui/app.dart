import 'package:flutter/material.dart';

import 'calendar_page.dart';
import 'login_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'today_page.dart';
import 'ups_page.dart';
import 'widgets.dart';

class TrackerApp extends StatelessWidget {
  const TrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 监听主题模式：切换时 MaterialApp 重建，两套配色之间做颜色插值
    // （见 AppColors.lerp），所以切换是渐变而不是硬闪一下。
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appTheme,
      builder: (BuildContext context, ThemeMode mode, _) {
        return MaterialApp(
          title: '追更台',
          debugShowCheckedModeBanner: false,
          theme: buildTrackerTheme(AppColors.light),
          darkTheme: buildTrackerTheme(AppColors.dark),
          themeMode: mode,
          home: const HomeShell(),
        );
      },
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => HomeShellState();
}

class HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const List<Widget> _pages = <Widget>[
    TodayPage(),
    CalendarPage(),
    UpsPage(),
    SearchPage(),
    SettingsPage(),
  ];

  void goTo(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      // M3 NavigationBar：选中项带胶囊指示器，比 BottomNavigationBar 现代
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int i) => setState(() => _index = i),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.bolt_outlined),
            selectedIcon: Icon(Icons.bolt),
            label: '今日',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '日历',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_alt_outlined),
            selectedIcon: Icon(Icons.people_alt),
            label: 'UP 主',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: '考古',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

/// 未登录时的占位卡片，各页共用。
class LoginPrompt extends StatelessWidget {
  const LoginPrompt({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.lock_outline,
      title: '需要先登录 B 站',
      description: message,
      action: FilledButton.icon(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const LoginPage()),
        ),
        icon: const Icon(Icons.login, size: 18),
        label: const Text('登录 B 站账号'),
      ),
    );
  }
}
