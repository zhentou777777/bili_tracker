import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'service/app_context.dart';
import 'service/bg_service.dart';
import 'ui/app.dart';
import 'ui/external_link.dart';
import 'ui/theme.dart';

/// 全局上下文，页面直接取用。
late AppContext appContext;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // 把「通知被点击后怎么打开链接」注入进去：
  // service 层不依赖 ui 层，所以只能在组装根（这里）把两边接起来。
  appContext = await AppContext.create(onOpenLink: openBilibiliContent);

  // 冷启动补偿：如果**本次启动本身就是「点了通知」触发的**，
  // 那一刻应用进程还不存在，注册的点击回调不会触发 —— 必须在这里单独查一次，
  // 否则「杀掉应用后点开播通知」会只是打开首页、不跳直播间。
  final String? launchPayload =
      await appContext.notify.pendingLaunchPayload();
  if (launchPayload != null) {
    unawaited(openBilibiliContent(launchPayload));
  }

  // 主题模式存在 prefs 里，必须在 runApp 之前读出来，
  // 否则第一帧会用默认值再跳成用户选的那套，看起来像闪一下。
  await appTheme.load(appContext.prefs);

  await BackgroundService().register();

  runApp(const TrackerApp());
}
