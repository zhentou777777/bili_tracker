import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'calendar_page.dart';
import 'login_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'today_page.dart';
import 'ups_page.dart';

/// 深色高密度主题，配色贴近 B 站品牌色。
class TrackerTheme {
  static const Color bg = Color(0xFF0A0D14);
  static const Color surface = Color(0xFF121722);
  static const Color surfaceAlt = Color(0xFF1A2130);
  static const Color border = Color(0xFF232B3A);
  static const Color textPrimary = Color(0xFFE6EAF2);
  static const Color textSecondary = Color(0xFF8A94A6);
  static const Color brand = Color(0xFFFB7299);
  static const Color live = Color(0xFFFF4D6D);
  static const Color accent = Color(0xFF00AEEC);

  static ThemeData build() {
    final ColorScheme scheme = const ColorScheme.dark(
      primary: brand,
      secondary: accent,
      surface: surface,
      onSurface: textPrimary,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      // Flutter 3.27 起 ThemeData.cardTheme 的类型由 CardTheme 改为 CardThemeData
      // （官方破坏性变更），此处必须用新类型，否则编译报错。
      cardTheme: const CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: brand,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: textPrimary, fontSize: 14),
        bodySmall: TextStyle(color: textSecondary, fontSize: 12),
      ),
    );
  }
}

class TrackerApp extends StatelessWidget {
  const TrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '追更台',
      debugShowCheckedModeBanner: false,
      theme: TrackerTheme.build(),
      home: const HomeShell(),
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
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (int i) => setState(() => _index = i),
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(icon: Icon(Icons.bolt), label: '今日'),
          BottomNavigationBarItem(
              icon: Icon(Icons.calendar_month), label: '日历'),
          BottomNavigationBarItem(icon: Icon(Icons.people_alt), label: 'UP 主'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: '考古'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.lock_outline,
                size: 48, color: TrackerTheme.textSecondary),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: TrackerTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: TrackerTheme.brand,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const LoginPage()),
              ),
              icon: const Icon(Icons.login),
              label: const Text('登录 B 站账号'),
            ),
          ],
        ),
      ),
    );
  }
}
