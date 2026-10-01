import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../main.dart';
import '../service/auth_service.dart';
import '../ui/app.dart';

/// WebView 登录：登录成功后从 CookieManager 提取 Cookie 存入本地安全存储。
///
/// SESSDATA 是 HttpOnly，JS 读不到，必须走原生 CookieManager，
/// 这也是选用 flutter_inappwebview 而非 webview_flutter 的原因。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  InAppWebViewController? _webController;
  final CookieManager _cookieManager = CookieManager.instance();

  bool _checking = false;
  String _status = '正在打开登录页…';
  bool _done = false;

  static const String _platform = 'bilibili';
  static const String _loginUrl =
      'https://passport.bilibili.com/h5-app/passport/login';
  static const String _homeUrl = 'https://www.bilibili.com/';

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    // 重新登录前先清掉旧凭据与 WebView Cookie，避免拿到过期 SESSDATA
    await _cookieManager.deleteAllCookies();
  }

  Future<void> _tryExtract() async {
    if (_checking || _done) return;
    setState(() => _checking = true);

    try {
      final List<Cookie> cookies = await _cookieManager.getCookies(
        url: WebUri(_homeUrl),
      );
      final Map<String, String> map = <String, String>{
        for (final Cookie c in cookies) c.name: c.value ?? '',
      };

      final bool hasSession = (map['SESSDATA'] ?? '').isNotEmpty;
      final bool hasUid = (map['DedeUserID'] ?? '').isNotEmpty;

      if (!hasSession || !hasUid) {
        if (mounted) {
          setState(() {
            _checking = false;
            _status =
                hasSession ? '已登录，正在获取账号信息…' : '请在页面内完成登录（支持扫码 / 短信 / 密码）';
          });
        }
        return;
      }

      await appContext.auth.saveCookies(
        _platform,
        cookies: map,
        requiredKeys: <String>['SESSDATA', 'bili_jct', 'DedeUserID'],
        selfUidCookieKey: 'DedeUserID',
      );

      if (!mounted) return;
      setState(() {
        _done = true;
        _status = '登录成功，正在拉取关注列表…';
      });

      // 登录后立即拉一次关注，形成闭环
      appContext.auth.state.setLoggedIn(_platform, true);
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _checking = false;
          _status = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _checking = false;
          _status = '登录信息提取失败：$e';
        });
      }
    }
  }

  Future<void> _openHome() async {
    await _webController?.loadUrl(
      urlRequest: URLRequest(url: WebUri(_homeUrl)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录 B 站'),
        actions: <Widget>[
          IconButton(
            tooltip: '登录完成后点这里',
            icon: const Icon(Icons.check),
            onPressed: _tryExtract,
          ),
          IconButton(
            tooltip: '回首页确认登录态',
            icon: const Icon(Icons.home_outlined),
            onPressed: _openHome,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: TrackerTheme.surfaceAlt,
            child: Row(
              children: <Widget>[
                const Icon(Icons.shield_outlined,
                    size: 16, color: TrackerTheme.brand),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _status,
                    style: const TextStyle(
                      color: TrackerTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (_checking)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
              initialSettings: InAppWebViewSettings(
                userAgent:
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Mobile Safari/537.36',
                javaScriptEnabled: true,
                // 用移动端 UA 更容易触发手机登录页
                preferredContentMode: UserPreferredContentMode.MOBILE,
              ),
              onWebViewCreated: (InAppWebViewController c) =>
                  _webController = c,
              onLoadStart: (InAppWebViewController c, WebUri? url) {
                if (mounted) {
                  setState(() => _status = '加载中…');
                }
              },
              onLoadStop: (InAppWebViewController c, WebUri? url) async {
                // 每次加载完成都试一次，登录成功即可捕获
                await Future<void>.delayed(const Duration(milliseconds: 600));
                await _tryExtract();
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Cookie 只保存在本机 Keystore，不会上传到任何服务器',
                style: const TextStyle(
                  color: TrackerTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
