/// 打开站外内容：**优先唤起 B 站 App**，不行再退回系统浏览器。
///
/// 为什么单独抽一个文件：三个页面（今日 / 日历 / 考古）都要「点一下直接进 App」，
/// 各写一份必然出现某一处忘了转换深链、或者失败后没有任何提示。
library external_link;

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/bilibili.dart';

/// 打开一条 B 站内容链接。
///
/// 顺序：`bilibili://` 深链 → 原始 https 链接。
/// 返回 false 表示两条路都没走通（既没装 B 站 App、也没有浏览器），
/// 此时调用方应给用户一个「链接已复制」之类的出路。
Future<bool> openBilibiliContent(String webUrl, {bool preferApp = true}) async {
  if (webUrl.isEmpty) return false;

  if (preferApp) {
    final String? deep = bilibiliDeepLink(webUrl);
    if (deep != null && await _launch(deep)) return true;
  }
  return _launch(webUrl);
}

/// 唤起一个自定义 scheme（例如 `bilibili://live/123`）。
///
/// 单独暴露出来，给「弹幕姬」这类非 B 站 App 的深链用。
Future<bool> openExternal(String url) => _launch(url);

/// 把链接复制到剪贴板（两条路都失败时的兜底）。
Future<void> copyLink(String url) => Clipboard.setData(ClipboardData(text: url));

/// 发起一次跳转。**两条分支都不做 `canLaunchUrl` 预检**（2026-10-02 优化）。
///
/// 两条理由：
///
/// 1. **性能**：预检是一次额外的「插件 ↔ 原生」IPC 往返，发生在平台线程上，
///    点击后到真正跳转之间那段卡顿，它要占掉一部分。
/// 2. **准确性**（阶段 I 踩过的坑）：Android 11+ 的包可见性限制下，没在
///    `AndroidManifest.xml` 的 `<queries>` 里声明过的 scheme，`canLaunchUrl`
///    会**误报 false** —— 于是会在明明装了 B 站 App 的情况下放弃深链、
///    退回浏览器，症状就是「点一下还是打开了网页」。
///
/// 所以一律直接尝试 `launchUrl`，用异常兜底。
Future<bool> _launch(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } on PlatformException {
    // 没有应用能处理这个 scheme（没装 B 站 App、或该机禁止唤起）
    return false;
  } catch (_) {
    return false;
  }
}
