import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'service/app_context.dart';
import 'service/bg_service.dart';
import 'ui/app.dart';

/// 全局上下文，页面直接取用。
late AppContext appContext;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  appContext = await AppContext.create();
  await BackgroundService().register();

  runApp(const TrackerApp());
}
