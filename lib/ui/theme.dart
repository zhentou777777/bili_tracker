/// 主题系统：浅色 / 深色两套配色 + 运行时切换。
///
/// 为什么要重做：原来所有颜色都是 `TrackerTheme.xxx` 这种**静态常量**，
/// 全局写死 131 处 —— 结构上就不可能支持第二套配色。
/// 现在改成 `ThemeExtension`，颜色由上下文解析，切主题时整树重建、自动过渡。
///
/// 用法（页面里）：
/// ```dart
/// final AppColors c = context.c;
/// Text('标题', style: TextStyle(color: c.textPrimary));
/// ```
/// 注意：`c.xxx` 不是编译期常量，所以**不能写在 `const` 表达式里**，
/// 从 const 改过来时要顺手把 `const` 去掉。
library theme;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一套完整的语义配色。
///
/// 刻意只保留语义名（bg / surface / textPrimary…），不出现 `grey200` 这类
/// 具体色值名 —— 两套主题共用同一份语义，页面代码不需要知道自己是浅色还是深色。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.isDark,
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.brand,
    required this.live,
    required this.accent,
    required this.success,
    required this.warning,
    required this.shadow,
  });

  final bool isDark;

  /// 页面底色。
  final Color bg;

  /// 卡片 / 导航栏底色。
  final Color surface;

  /// 次级容器：内嵌信息条、选中态底、输入框底。
  final Color surfaceAlt;

  /// 分隔线 / 卡片描边。
  final Color border;

  final Color textPrimary;
  final Color textSecondary;

  /// B 站品牌粉。
  ///
  /// 浅色主题下刻意用了**更深的粉**（#E23F6E）：B 站官网那支 #FB7299 在白底上
  /// 对比度只有约 2.2:1，做正文/图标会看不清；深色底上则保留原色更亮眼。
  final Color brand;

  /// 直播中 / 危险。
  final Color live;

  /// 链接 / 信息类强调色（B 站蓝）。
  final Color accent;

  final Color success;
  final Color warning;

  /// 卡片投影。深色主题下几乎不可见（靠层级而非阴影表达），浅色下是淡淡的灰。
  final Color shadow;

  /// 在任意底色上叠一层淡色，用于标签底、选中态。
  Color tint(Color color, [double alpha = 0.12]) =>
      color.withValues(alpha: alpha);

  /// 比 surface 再抬一级的容器底色（深色下更亮、浅色下更暗一点）。
  Color get raised => isDark ? surfaceAlt : surface;

  @override
  AppColors copyWith({
    bool? isDark,
    Color? bg,
    Color? surface,
    Color? surfaceAlt,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? brand,
    Color? live,
    Color? accent,
    Color? success,
    Color? warning,
    Color? shadow,
  }) =>
      AppColors(
        isDark: isDark ?? this.isDark,
        bg: bg ?? this.bg,
        surface: surface ?? this.surface,
        surfaceAlt: surfaceAlt ?? this.surfaceAlt,
        border: border ?? this.border,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        brand: brand ?? this.brand,
        live: live ?? this.live,
        accent: accent ?? this.accent,
        success: success ?? this.success,
        warning: warning ?? this.warning,
        shadow: shadow ?? this.shadow,
      );

  /// 切换主题时做颜色插值，于是切换是「渐变」而不是硬闪。
  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      isDark: t < 0.5 ? isDark : other.isDark,
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      live: Color.lerp(live, other.live, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }

  /// 深色：冷调近黑，靠层级差而不是描边来分层。
  static const AppColors dark = AppColors(
    isDark: true,
    bg: Color(0xFF0E1015),
    surface: Color(0xFF171A21),
    surfaceAlt: Color(0xFF20242E),
    border: Color(0xFF2C323E),
    textPrimary: Color(0xFFF2F4F8),
    textSecondary: Color(0xFF98A1B2),
    brand: Color(0xFFFB7299),
    live: Color(0xFFFF5C77),
    accent: Color(0xFF22B8F0),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    shadow: Color(0x00000000),
  );

  /// 浅色：带一点点冷的米白底，避免纯白的「惨白感」。
  static const AppColors light = AppColors(
    isDark: false,
    bg: Color(0xFFF4F5F9),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEDEFF5),
    border: Color(0xFFE1E5EE),
    textPrimary: Color(0xFF14171E),
    textSecondary: Color(0xFF6A7285),
    brand: Color(0xFFE23F6E),
    live: Color(0xFFE8395A),
    accent: Color(0xFF0E9BD8),
    success: Color(0xFF12A150),
    warning: Color(0xFFC77700),
    shadow: Color(0x12101828),
  );
}

/// 从上下文取配色。页面里统一这么用，不再引用任何静态色值。
extension AppColorsContext on BuildContext {
  AppColors get c => Theme.of(this).extension<AppColors>() ?? AppColors.dark;
}

/// 由一套配色生成完整 ThemeData。
ThemeData buildTrackerTheme(AppColors c) {
  final Brightness brightness = c.isDark ? Brightness.dark : Brightness.light;

  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: c.brand,
    brightness: brightness,
  ).copyWith(
    primary: c.brand,
    onPrimary: Colors.white,
    secondary: c.accent,
    surface: c.surface,
    onSurface: c.textPrimary,
    onSurfaceVariant: c.textSecondary,
    outline: c.border,
    outlineVariant: c.border,
    error: c.live,
    shadow: c.shadow,
  );

  const RoundedRectangleBorder cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(18)),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    splashFactory: InkSparkle.splashFactory,
    extensions: <ThemeExtension<dynamic>>[c],

    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle:
          c.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      titleTextStyle: TextStyle(
        color: c.textPrimary,
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
      iconTheme: IconThemeData(color: c.textPrimary, size: 22),
    ),

    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: cardShape.copyWith(side: BorderSide(color: c.border)),
    ),

    // 底部导航用 M3 的 NavigationBar：带胶囊选中态的指示器比老式
    // BottomNavigationBar 现代得多，也不再需要自己调图标颜色。
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.tint(c.brand, 0.16),
      indicatorShape: const StadiumBorder(),
      elevation: 0,
      height: 66,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (Set<WidgetState> states) => IconThemeData(
          size: 23,
          color: states.contains(WidgetState.selected)
              ? c.brand
              : c.textSecondary,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (Set<WidgetState> states) => TextStyle(
          fontSize: 11.5,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? c.brand
              : c.textSecondary,
        ),
      ),
    ),

    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),

    textTheme: TextTheme(
      titleLarge: TextStyle(
        color: c.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
      titleMedium: TextStyle(
        color: c.textPrimary,
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: TextStyle(color: c.textPrimary, fontSize: 14.5, height: 1.35),
      bodyMedium: TextStyle(color: c.textPrimary, fontSize: 13.5, height: 1.35),
      bodySmall: TextStyle(color: c.textSecondary, fontSize: 12, height: 1.4),
      labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ).apply(bodyColor: c.textPrimary, displayColor: c.textPrimary),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.brand,
        foregroundColor: Colors.white,
        disabledBackgroundColor: c.surfaceAlt,
        disabledForegroundColor: c.textSecondary,
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.textPrimary,
        side: BorderSide(color: c.border),
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.brand,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: c.surfaceAlt,
        foregroundColor: c.textSecondary,
        selectedBackgroundColor: c.tint(c.brand, 0.16),
        selectedForegroundColor: c.brand,
        side: BorderSide(color: c.border),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (Set<WidgetState> s) => s.contains(WidgetState.selected)
            ? Colors.white
            : c.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (Set<WidgetState> s) => s.contains(WidgetState.selected)
            ? c.brand
            : c.surfaceAlt,
      ),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: c.textSecondary,
      textColor: c.textPrimary,
      subtitleTextStyle: TextStyle(color: c.textSecondary, fontSize: 12),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: c.surfaceAlt,
      side: BorderSide(color: c.border),
      labelStyle: TextStyle(color: c.textSecondary, fontSize: 12),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceAlt,
      hintStyle: TextStyle(color: c.textSecondary, fontSize: 14),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c.brand, width: 1.6),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.isDark ? c.surfaceAlt : const Color(0xFF23262F),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
      behavior: SnackBarBehavior.floating,
      elevation: 4,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(22)),
      ),
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
  );
}

/// 主题模式控制器：跟随系统 / 浅色 / 深色。
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController() : super(ThemeMode.system);

  static const String prefsKey = 'theme_mode';

  /// 编译期锁定主题：`flutter build apk --dart-define=FORCE_THEME=light`
  ///
  /// 用途：真机需要一版「纯浅色」或「纯深色」的包时，不必改代码。
  /// 留空则使用上面的三态开关。
  static const String forced = String.fromEnvironment('FORCE_THEME');

  SharedPreferences? _prefs;

  /// 被 `--dart-define` 锁定时，设置页里的开关应禁用并说明原因。
  bool get isForced => forced == 'light' || forced == 'dark';

  String get forcedLabel => forced == 'light' ? '浅色' : '深色';

  Future<void> load(SharedPreferences prefs) async {
    _prefs = prefs;
    if (isForced) {
      value = forced == 'light' ? ThemeMode.light : ThemeMode.dark;
      return;
    }
    value = _parse(prefs.getString(prefsKey));
  }

  Future<void> setMode(ThemeMode mode) async {
    if (isForced || value == mode) return;
    value = mode;
    await _prefs?.setString(prefsKey, _name(mode));
  }

  static ThemeMode _parse(String? raw) {
    if (raw == 'light') return ThemeMode.light;
    if (raw == 'dark') return ThemeMode.dark;
    return ThemeMode.system;
  }

  static String _name(ThemeMode mode) {
    if (mode == ThemeMode.light) return 'light';
    if (mode == ThemeMode.dark) return 'dark';
    return 'system';
  }
}

/// 全局唯一实例。与 `late AppContext appContext` 同一套惯例。
final ThemeController appTheme = ThemeController();
