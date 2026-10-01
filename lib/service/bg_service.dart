/// 后台任务。
///
/// 移动端后台调度不可靠：不同厂商的省电策略会拖延甚至跳过任务。
/// 因此这里只做「尽力而为」，开播检测另有服务端兜底通道（第二阶段）。
library bg_service;

import 'package:workmanager/workmanager.dart';

import 'app_context.dart';
import 'sync_service.dart';

/// 开播轮询任务名。
const String kTaskLive = 'live_poll';

/// 动态抓取任务名。
const String kTaskSync = 'feed_sync';

/// WorkManager 的调度间隔下限是 15 分钟，写更小会被自动抬升。
const Duration kLiveInterval = Duration(minutes: 15);
const Duration kSyncInterval = Duration(minutes: 30);

/// 后台入口，必须是顶层函数。
@pragma('vm:entry-point')
void bgCallbackDispatcher() {
  Workmanager().executeTask((String task, Map<String, dynamic>? input) async {
    try {
      final AppContext ctx = await AppContext.create();
      final SyncService sync = SyncService(ctx);

      switch (task) {
        case kTaskLive:
          await sync.checkLive();
          break;
        case kTaskSync:
          await sync.syncAll(foreground: false);
          await sync.checkLive();
          break;
        default:
          break;
      }
    } catch (_) {
      // 后台任务失败不重试到死，等下一个调度周期
    }
    return true;
  });
}

class BackgroundService {
  Future<void> register() async {
    await Workmanager().initialize(
      bgCallbackDispatcher,
      isInDebugMode: false,
    );
    await Workmanager().registerPeriodicTask(
      kTaskLive,
      kTaskLive,
      frequency: kLiveInterval,
      constraints: Constraints(networkType: NetworkType.connected),
      // registerPeriodicTask 的参数类型是 ExistingPeriodicWorkPolicy（与一次性任务的
      // ExistingWorkPolicy 是两个不同枚举），作者原代码写错为后者，从未编译故未暴露
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
    await Workmanager().registerPeriodicTask(
      kTaskSync,
      kTaskSync,
      frequency: kSyncInterval,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  Future<void> cancelAll() async {
    await Workmanager().cancelAll();
  }
}
