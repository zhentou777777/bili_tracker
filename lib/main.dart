import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'service/app_context.dart';
import 'service/bg_service.dart';
import 'ui/app.dart';
import 'ui/theme.dart';

/// 全局上下文，页面直接取用。
late AppContext appContext;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  appContext = await AppContext.create();

  // 主题模式存在 prefs 里，必须在 runApp 之前读出来，
  // 否则第一帧会用默认值再跳成用户选的那套，看起来像闪一下。
  await appTheme.load(appContext.prefs);

  await BackgroundService().register();

  runApp(const TrackerApp());
}
