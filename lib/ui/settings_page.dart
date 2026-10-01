import 'package:flutter/material.dart';

import '../main.dart';
import '../service/bg_service.dart';
import 'app.dart';
import 'login_page.dart';

/// 设置：账号、通知、规则、后台任务、数据清理。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loggedIn = false;
  String? _selfUid;
  final TextEditingController _ruleCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ruleCtrl.text = appContext.rulesService.remoteUrl ?? '';
    _load();
  }

  @override
  void dispose() {
    _ruleCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bool ok = await appContext.auth.isLoggedIn('bilibili');
    final String? uid = await appContext.auth.selfUid('bilibili');
    if (!mounted) return;
    setState(() {
      _loggedIn = ok;
      _selfUid = uid;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rules = appContext.rulesService.current;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: <Widget>[
          _section('账号'),
          ListTile(
            dense: true,
            leading: Icon(
              _loggedIn ? Icons.check_circle : Icons.error_outline,
              color: _loggedIn ? Colors.green : TrackerTheme.live,
              size: 20,
            ),
            title: Text(_loggedIn ? 'B 站已登录' : 'B 站未登录'),
            subtitle: Text(
              _selfUid == null ? '登录后才能拉取关注列表' : 'UID $_selfUid · Cookie 仅存本机',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: TextButton(
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LoginPage()),
                );
                await _load();
              },
              child: Text(_loggedIn ? '重新登录' : '去登录'),
            ),
          ),
          if (_loggedIn)
            ListTile(
              dense: true,
              leading:
                  const Icon(Icons.logout, size: 20, color: TrackerTheme.live),
              title: const Text('退出并清除 Cookie'),
              onTap: _logout,
            ),
          _section('通知'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.notifications, size: 20),
            title: const Text('申请通知权限'),
            subtitle: const Text('Android 13+ 需要显式授权',
                style: TextStyle(fontSize: 11)),
            onTap: () async {
              final bool ok = await appContext.notify.requestPermission();
              _toast(ok ? '已授权' : '未授权，通知将不会显示');
            },
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.send, size: 20),
            title: const Text('发送一条测试通知'),
            onTap: () =>
                appContext.notify.notifySummary(upCount: 1, itemCount: 1),
          ),
          _section('抓取规则'),
          ListTile(
            dense: true,
            title: const Text('当前规则', style: TextStyle(fontSize: 13)),
            subtitle: Text(
              '版本 ${rules.version} · 来源 ${_sourceLabel(rules.source)} · ${rules.platforms.length} 个平台',
              style: const TextStyle(fontSize: 11),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _ruleCtrl,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: '远端规则 JSON 地址（留空用内置）',
                      hintStyle: TextStyle(
                          fontSize: 11, color: TrackerTheme.textSecondary),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    await appContext.rulesService.setRemoteUrl(_ruleCtrl.text);
                    final bool ok =
                        await appContext.rulesService.refreshFromRemote();
                    if (!mounted) return;
                    setState(() {});
                    _toast(ok ? '规则已更新' : '拉取失败，继续用现有规则');
                  },
                  child: const Text('保存并刷新'),
                ),
              ],
            ),
          ),
          _section('后台任务'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.schedule, size: 20),
            title: const Text('注册后台轮询'),
            subtitle: const Text(
              '开播 15 分钟 / 动态 30 分钟（受系统省电策略影响）',
              style: TextStyle(fontSize: 11),
            ),
            onTap: () async {
              await BackgroundService().register();
              _toast('已注册后台任务');
            },
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.cancel_schedule_send,
                size: 20, color: TrackerTheme.live),
            title: const Text('取消后台任务'),
            onTap: () async {
              await BackgroundService().cancelAll();
              _toast('已取消');
            },
          ),
          _section('数据'),
          ListTile(
            dense: true,
            leading: const Icon(Icons.delete_forever,
                size: 20, color: TrackerTheme.live),
            title: const Text('清除所有本地数据'),
            subtitle: const Text('动态、直播记录、订阅与 Cookie 全部删除',
                style: TextStyle(fontSize: 11)),
            onTap: _clearAll,
          ),
          _section('说明'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              '本工具使用你本人的 Cookie 直连平台接口，相当于你自己打开网页查看关注内容。'
              'Cookie 只保存在本机安全存储中，不会上传到任何服务器。\n\n'
              '使用本工具即表示你了解并自行承担违反平台服务条款的潜在风险。'
              '如遇到验证码或风控提示，请重新登录或降低抓取频率。',
              style: TextStyle(
                  fontSize: 12, color: TrackerTheme.textSecondary, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: TrackerTheme.surface,
        title: const Text('退出登录'),
        content: const Text('将清除本机保存的 Cookie，已抓取的动态会保留。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认', style: TextStyle(color: TrackerTheme.live)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await appContext.auth.clear('bilibili');
    await _load();
  }

  Future<void> _clearAll() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: TrackerTheme.surface,
        title: const Text('清除所有本地数据'),
        content: const Text('动态、直播记录、订阅列表和 Cookie 都会被删除，且无法恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                const Text('确认清除', style: TextStyle(color: TrackerTheme.live)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await appContext.db.clearAll();
    await appContext.auth.clearAll();
    if (!mounted) return;
    await _load();
    _toast('已清除');
  }

  /// 统一的提示入口。
  ///
  /// 为什么单独抽一个方法：`await` 之后再直接用 `context` 会踩
  /// use_build_context_synchronously —— 用户在等待期间切走页面时，
  /// context 已经失效，会抛 "Looking up a deactivated widget's ancestor"。
  /// 把「判断 + 使用」收进这个**没有 await**的方法里，判断与使用之间
  /// 不存在异步间隙，从结构上就不可能出错。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: TrackerTheme.brand,
          ),
        ),
      );

  static String _sourceLabel(String s) {
    switch (s) {
      case 'remote':
        return '远端';
      case 'cache':
        return '缓存';
      case 'bundled':
        return '内置';
      default:
        return '未加载';
    }
  }
}
