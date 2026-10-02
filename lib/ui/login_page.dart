import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/http.dart';
import '../core/rules.dart';
import '../main.dart';
import '../platform/bilibili.dart';
import '../platform/models.dart';
import '../service/auth_service.dart';
import 'theme.dart';

/// 登录 B 站。
///
/// 主路径是**扫码登录 + 同设备一键跳转**（登录入口只有两个纯 JSON 接口）：
///
/// 1. 申请二维码 → 拿到 `qrcode_key` 和一条 `account.bilibili.com/.../scan-web` 链接；
/// 2. 那条链接不只是给二维码用的 —— 在本机用系统打开它，装了 B 站 App 的
///    手机就会被 App Links 接走、唤起 B 站 App 内的授权确认页，
///    用户点一下「确认」即可，**不需要第二台设备来扫码**；
/// 3. 后台每 2 秒轮询一次状态，确认后从 `Set-Cookie` 里取回 SESSDATA 等凭据。
///
/// 另一台设备扫码、以及「网页登录」都作为备用路径保留（见 [WebLoginPage]）。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// 界面阶段。与 [LoginQrStatus] 分开：多了「正在申请」「保存中」「出错」这些
/// 只有界面才关心的中间态。
enum _Phase { generating, waiting, scanned, expired, error, success }

class _LoginPageState extends State<LoginPage> {
  static const String _platform = 'bilibili';

  BilibiliAdapter? _adapter;
  LoginRule _loginRule = const LoginRule.empty();

  Timer? _timer;
  _Phase _phase = _Phase.generating;
  String _status = '正在生成二维码…';
  String _detail = '';
  LoginQrSession? _session;

  /// 防止「成功回调」与手动刷新同时跑，把 Cookie 存两遍。
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    // 放到首帧之后再启动：_bootstrap 会走到 setState，而在 initState 里
    // 同步 setState 只是「碰巧不报错」（靠 Element 初始就是 dirty），
    // 不该依赖这种巧合。首帧显示的初始态本来就是「正在生成二维码…」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_bootstrap());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final PlatformRule? rule = appContext.rulesService.current.platform(_platform);
    final BilibiliAdapter? adapter = appContext.bilibiliAdapter();

    if (rule == null || adapter == null || rule.login.isEmpty) {
      _fail(
        '规则文件里没有扫码登录配置',
        '请更新平台规则文件，或改用下方的「网页登录」。',
      );
      return;
    }
    _loginRule = rule.login;
    _adapter = adapter;
    await _generate();
  }

  Future<void> _generate() async {
    _timer?.cancel();
    setState(() {
      _phase = _Phase.generating;
      _status = '正在生成二维码…';
      _detail = '';
      _session = null;
    });

    try {
      final LoginQrSession session = await _adapter!.createLoginQr();
      if (!mounted) return;
      setState(() {
        _session = session;
        _phase = _Phase.waiting;
        _status = '等待扫码';
      });
      _startPolling(session.qrcodeKey);
    } on ApiException catch (e) {
      _fail('获取二维码失败', e.message);
    } catch (e) {
      _fail('获取二维码失败', '$e');
    }
  }

  /// 开始轮询。间隔与有效期都取自规则文件，不写死。
  void _startPolling(String qrcodeKey) {
    _timer?.cancel();
    final Duration interval = Duration(milliseconds: _loginRule.pollIntervalMs);
    final DateTime deadline =
        DateTime.now().add(Duration(seconds: _loginRule.qrTtlSeconds));

    _timer = Timer.periodic(interval, (Timer t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      // 本地也判一次超时：万一轮询请求持续失败，不至于永远转下去
      if (DateTime.now().isAfter(deadline)) {
        t.cancel();
        return;
      }
      if (_phase == _Phase.success || _phase == _Phase.expired) {
        t.cancel();
        return;
      }

      try {
        final LoginPollResult r = await _adapter!.pollLoginQr(qrcodeKey);
        if (!mounted) return;

        // 这里刻意用 if/else 而不是 switch：这几个分支都要执行语句后继续，
        // switch 里少写 break 容易被下一个人读错。
        if (r.status == LoginQrStatus.success) {
          t.cancel();
          await _finish(r);
        } else if (r.status == LoginQrStatus.expired) {
          t.cancel();
          _expire();
        } else if (r.status == LoginQrStatus.scanned) {
          setState(() {
            _phase = _Phase.scanned;
            _status = '已扫码，请在 B 站 App 上点「确认」';
          });
        } else if (r.status == LoginQrStatus.waiting) {
          setState(() {
            _phase = _Phase.waiting;
            _status = '等待扫码';
          });
        } else if (r.message.isNotEmpty) {
          // 规则表里没登记的码：不猜语义，只把原文案显示出来
          setState(() => _status = r.message);
        }
      } catch (_) {
        // 单次轮询失败不打断整个流程：网络抖一下不该让用户重新扫码
      }
    });
  }

  Future<void> _finish(LoginPollResult r) async {
    if (_finishing) return;
    _finishing = true;
    try {
      if (r.isSuccessWithoutCookie) {
        // 最容易骗过人的一种失败：接口说成功，但 Cookie 是空的
        _fail(
          'B 站已确认，但没有下发登录凭据',
          '请重新生成二维码再试一次。若反复出现，可能是接口已变动（见规则文件的 login 段）。',
        );
        return;
      }

      final PlatformRule? rule =
          appContext.rulesService.current.platform(_platform);
      if (rule == null) {
        _fail('保存登录信息失败', '规则文件里找不到该平台');
        return;
      }

      await appContext.auth.saveCookies(
        _platform,
        cookies: r.cookies,
        requiredKeys: rule.requiredCookies,
        selfUidCookieKey: rule.selfUidCookie,
      );

      if (!mounted) return;
      setState(() {
        _phase = _Phase.success;
        _status = '登录成功';
        _detail = '';
      });
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) Navigator.of(context).pop(true);
    } on AuthException catch (e) {
      _fail('登录信息不完整', e.message);
    } catch (e) {
      _fail('保存登录信息失败', '$e');
    } finally {
      _finishing = false;
    }
  }

  void _expire() {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.expired;
      _status = '二维码已过期';
      _detail = '二维码有效期 ${_loginRule.qrTtlSeconds} 秒，请重新生成。';
    });
  }

  void _fail(String status, String detail) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _status = status;
      _detail = detail;
    });
  }

  /// 同设备跳转：把二维码链接交给系统打开。
  ///
  /// 这是整套方案里最像「跳转 App 授权登录」的一步 —— 链接是 B 站自己的
  /// `account-h5/auth/scan-web` 授权页，手机上装了 B 站 App 后会被 App Links
  /// 接管，直接进 App 的确认页。失败（没装 App / 没注册 App Links）时
  /// 退回复制链接，用户仍可粘贴到别处打开。
  Future<void> _openInBiliApp() async {
    final LoginQrSession? session = _session;
    if (session == null || session.url.isEmpty) return;

    try {
      final bool launched = await launchUrl(
        Uri.parse(session.url),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) throw StateError('系统未接管该链接');
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: session.url));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没能唤起 B 站 App，链接已复制到剪贴板；\n可在 B 站 App 或浏览器里打开它完成确认。'),
        ),
      );
    }
  }

  Color get _dotColor {
    final AppColors c = context.c;
    switch (_phase) {
      case _Phase.generating:
        return c.accent;
      case _Phase.waiting:
        return c.warning;
      case _Phase.scanned:
      case _Phase.success:
        return c.success;
      case _Phase.expired:
      case _Phase.error:
        return c.live;
    }
  }

  bool get _canOpenApp =>
      _phase == _Phase.waiting || _phase == _Phase.scanned;

  bool get _showOverlay => _phase == _Phase.expired || _phase == _Phase.error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录 B 站'),
        actions: <Widget>[
          IconButton(
            tooltip: '使用网页登录',
            icon: const Icon(Icons.language_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<bool>(
                builder: (_) => const WebLoginPage(),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _hero(),
              const SizedBox(height: 20),
              _statusRow(),
              const SizedBox(height: 14),
              _qrCard(),
              const SizedBox(height: 20),
              _actions(),
              const SizedBox(height: 18),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hero() {
    return Column(
      children: <Widget>[
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: context.c.surfaceAlt,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: context.c.border),
          ),
          child: Icon(Icons.qr_code_2_rounded,
              size: 30, color: context.c.brand),
        ),
        const SizedBox(height: 12),
        Text(
          '连接 Bilibili',
          style: TextStyle(
            color: context.c.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '登录后才能读取关注列表、动态与观看记录。\nCookie 只保存在本机 Keystore，不会离开这台设备。',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: context.c.textSecondary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _statusRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: _dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            _status,
            style: TextStyle(
              color: context.c.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _qrCard() {
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Container(
            width: 220,
            height: 220,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              // 二维码必须是浅底深码：库的前景色固定纯黑，这里给白底
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: context.c.border),
            ),
            child: _qrContent(),
          ),
          if (_showOverlay) _overlay(),
        ],
      ),
    );
  }

  Widget _qrContent() {
    final LoginQrSession? session = _session;
    if (session == null) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    return PrettyQrView.data(
      data: session.url,
      // 纠错等级提到 M：屏幕反光、贴膜、截图压缩都还在可扫范围内
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
  }

  Widget _overlay() {
    return Positioned.fill(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              _phase == _Phase.expired
                  ? Icons.timer_off_outlined
                  : Icons.error_outline_rounded,
              color: Colors.white,
              size: 34,
            ),
            const SizedBox(height: 10),
            Text(
              _phase == _Phase.expired ? '二维码已失效' : '出错了',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _generate,
              child: const Text('重新生成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FilledButton.icon(
          onPressed: _canOpenApp ? _openInBiliApp : null,
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text('在 B 站 App 中确认'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _phase == _Phase.generating ? null : _generate,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('换一个二维码'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(44),
            foregroundColor: context.c.textPrimary,
            side: BorderSide(color: context.c.border),
          ),
        ),
        if (_detail.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Text(
            _detail,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.c.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }

  Widget _footer() {
    return Column(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.c.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.c.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.phone_iphone_rounded,
                  size: 16, color: context.c.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '就在这台手机上：点上面的按钮，会直接跳到 B 站 App 的授权页，'
                  '在 App 里点「确认」即可，不用找第二台设备扫码。',
                  style: TextStyle(
                    color: context.c.textSecondary,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Cookie 只保存在本机 Keystore，不会上传到任何服务器',
          style: TextStyle(color: context.c.textSecondary, fontSize: 11),
        ),
      ],
    );
  }
}

/// 网页登录（备用路径）。
///
/// 保留原因：规则文件里没配扫码端点、或某些账号只能在网页端完成验证时，
/// 仍有一条路能走。登录成功后从 CookieManager 提取 Cookie 存入本地安全存储。
///
/// SESSDATA 是 HttpOnly，JS 读不到，必须走原生 CookieManager，
/// 这也是选用 flutter_inappwebview 而非 webview_flutter 的原因。
class WebLoginPage extends StatefulWidget {
  const WebLoginPage({super.key});

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
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
    // 重新登录前先清掉旧的 WebView Cookie，避免拿到过期 SESSDATA
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
            _status = hasSession
                ? '已登录，正在获取账号信息…'
                : '请在页面内完成登录（支持扫码 / 短信 / 密码）';
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
        _status = '登录成功';
      });

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
        title: const Text('网页登录'),
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
            color: context.c.surfaceAlt,
            child: Row(
              children: <Widget>[
                Icon(Icons.shield_outlined,
                    size: 16, color: context.c.brand),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _status,
                    style: TextStyle(
                      color: context.c.textSecondary,
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
                '网页登录是备用方案，可能因页面白屏而失败；\n正常情况请用扫码登录。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.c.textSecondary,
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
