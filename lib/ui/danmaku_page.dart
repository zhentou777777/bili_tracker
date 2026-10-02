import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/danmaku_link.dart';
import 'external_link.dart';
import 'theme.dart';

/// 直播间弹幕姬（LAPLACE Chat）。
///
/// 接入方式很简单：该服务给每个直播间提供一个**固定页面**
/// `https://chat.vrp.moe/dashboard/{房间号}`，用内嵌 WebView 打开即可。
/// （房间里的事件订阅、样式、TTS 等都由那个页面自己处理，我们不需要对接
/// 它的长连接 —— 它也没有公开 API 文档。）
///
/// 已知问题：**未登记的房间会被对端甩回站点首页 `/`**，表现是「打开了却对不上
/// 直播间」。所以这里会在加载完成后核对 URL（规则见 `core/danmaku_link.dart`），
/// 命中「被甩到首页」就按「这个直播间没有页面」处理，并给出「用浏览器打开」的
/// 出路 —— 既不假装正常，也不擅自把这个入口删掉。
///
/// 为什么用内嵌而不是跳浏览器：用户是在「看谁在播」的场景里顺手开弹幕，
/// 跳出去再回来会丢掉上下文。
class DanmakuPage extends StatefulWidget {
  const DanmakuPage({
    super.key,
    required this.roomId,
    this.upName = '',
  });

  /// 直播间号（长号短号都可以，B 站两边都能解析）。
  final String roomId;

  /// 仅用于标题显示。
  final String upName;

  @override
  State<DanmakuPage> createState() => _DanmakuPageState();
}

class _DanmakuPageState extends State<DanmakuPage> {
  InAppWebViewController? _controller;
  bool _loading = true;
  String? _error;

  /// 是否被对端甩到了站点首页。
  ///
  /// 与 `_error`（真的加载失败）区分开：一个是「这里没有这个房间」，
  /// 一个是「页面打不开」，给的提示和出路不一样。
  bool _redirected = false;

  String get _url => 'https://chat.vrp.moe/dashboard/${widget.roomId}';

  /// 统一的地址判定入口：加载完成（`onLoadStop`）与历史变更
  /// （`onUpdateVisitedHistory`）都走这里。
  ///
  /// 只挂 `onLoadStop` 是不够的 —— SPA 在前端做的 `replaceState` 跳转
  /// 不会再触发一次加载完成，那种跳转只有历史回调抓得到。
  void _noteUrl(String? raw) {
    if (!mounted) return;
    // 空值与 `about:blank` 这类中间态不参与判断：它们会被判成 other，
    // 从而把刚做出的「被甩到首页」结论误撤销掉。
    if (raw == null || raw.isEmpty || raw.startsWith('about:')) return;

    final DanmakuUrlKind kind = classifyDanmakuUrl(raw);
    final bool onHome = kind == DanmakuUrlKind.home;
    final String homeDetail =
        onHome ? '页面被跳转到了 ${danmakuUrlDisplay(raw)}。' : '';

    // 这里刻意**不碰 `_loading`**：进度条只由 `onLoadStop` 负责关闭。
    // 历史回调（onUpdateVisitedHistory）可能早于加载完成触发，
    // 让它去关进度条会出现「页面还没出来、进度条先没了」。
    setState(() {
      if (onHome) {
        _redirected = true;
        _error = homeDetail;
      } else if (_redirected) {
        // 之前那个「被甩到首页」的结论已经不成立（站点又跳到了别处，
        // 例如去了登录页），必须撤销 —— 否则会拿一个过期的判断把页面挡住。
        _redirected = false;
        _error = null;
      }
    });
  }

  /// 跳到 B 站直播间：优先唤起 App，不行走浏览器，都没有就把链接复制出来。
  ///
  /// 与今日页的 `_open` 是同一条策略（见 `external_link.dart`），
  /// **不要另写一套 `launchUrl`** —— 否则又会退回到「点一下只开浏览器」。
  /// 外部跳转进行中的锁（与今日页 `_open` 同一套做法）：
  /// `startActivity` 有空档期，防用户连点导致连发多次跳转。
  bool _opening = false;

  Future<void> _openLiveRoom() async {
    if (widget.roomId.isEmpty || _opening) return;

    _opening = true;
    try {
      final String url = 'https://live.bilibili.com/${widget.roomId}';
      if (await openBilibiliContent(url)) return;

      await copyLink(url);
      _toast('没能打开：链接已复制到剪贴板');
    } finally {
      _opening = false;
    }
  }

  /// 统一提示入口（判断与使用之间不放 await，避免 context 失效）。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.upName.isEmpty ? '弹幕姬' : '弹幕姬 · ${widget.upName}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              setState(() {
                _error = null;
                _loading = true;
                _redirected = false;
              });
              _controller?.reload();
            },
          ),
          // 进入直播间：看弹幕的人下一步多半就是「进直播间」，退出去再点卡片
          // 太绕。走的是和今日页同一个深链逻辑（优先唤起 B 站 App）。
          //
          // 放在 AppBar 而不是页面里：它**在错误态也可见** —— 恰恰是
          // 「这个直播间在弹幕姬里没有页面」的时候，用户最需要这个出口。
          if (widget.roomId.isNotEmpty)
            IconButton(
              tooltip: '进入直播间',
              icon: const Icon(Icons.live_tv_rounded),
              onPressed: _openLiveRoom,
            ),
          IconButton(
            tooltip: '用浏览器打开',
            icon: const Icon(Icons.open_in_new_rounded),
            // 兜底出口：万一 WebView 里兼容性有问题（该站的更新日志提到
            // 对内嵌浏览器内核版本有要求），用户还能用系统浏览器打开。
            onPressed: () => openExternal(_url),
          ),
        ],
        bottom: _loading && _error == null
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : null,
      ),
      // WebView **始终留在组件树上**，错误视图只是叠在它上面的覆盖层。
      //
      // 以前写成 `body: _error != null ? _errorView() : InAppWebView(...)`：
      // 出错时 InAppWebView 会被移出组件树并随即 dispose（已核对插件源码：
      // `in_app_webview.dart` 的 dispose → platform.dispose → 拆掉消息通道）。
      // 后果有两条：① `reload()` 打在已拆掉的通道上、静默空转，「重试」
      // 只能退化成"整只 WebView 重建"（丢状态、更慢）；② 更关键的是
      // **URL 回调全部断掉**，于是「站点又跳到别处就撤销判定」那段逻辑
      // 永远触发不了 —— WebView 常驻之后它才真的有意义。
      //
      // 两个 child 都必须包 `SizedBox.expand`：IndexedStack 内部是
      // Stack(fit: StackFit.loose)，子组件拿到的是**松约束** —— 不包的话
      // WebView 可能量到 0 尺寸而不可见，而 `_errorView()`（是个 Center）
      // 会缩到内容大小并贴到左上，不再居中。
      body: IndexedStack(
        index: _error != null ? 1 : 0,
        children: <Widget>[
          SizedBox.expand(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(_url)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                // 这个页面是个 SPA，靠 localStorage 存配置；
                // 关掉 DOM storage 会导致它每次打开都像「新用户」。
                domStorageEnabled: true,
                databaseEnabled: true,
                // 默认是 true（要求用户手势才播放媒体）。弹幕机里的
                // TTS 语音需要自动播放，所以放开。
                mediaPlaybackRequiresUserGesture: false,
                supportZoom: true,
                // 它自带移动端竖屏布局，用移动端 UA 才能拿到那一套。
                userAgent:
                    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
              ),
              onWebViewCreated: (InAppWebViewController controller) =>
                  _controller = controller,
              onLoadStart: (InAppWebViewController controller, WebUri? url) {
                if (mounted) setState(() => _loading = true);
              },
              onLoadStop: (InAppWebViewController controller, WebUri? url) {
                // 只有真正加载完成才收进度条（见 _noteUrl 里的说明）。
                if (mounted) setState(() => _loading = false);
                _noteUrl(url?.toString());
              },
              onUpdateVisitedHistory: (InAppWebViewController controller,
                      WebUri? url, bool? isReload) =>
                  _noteUrl(url?.toString()),
              onReceivedError:
                  (InAppWebViewController controller, WebResourceRequest req,
                      WebResourceError err) {
                // 只在意主文档的失败；子资源（图片/接口）失败不该整页报错
                // isForMainFrame 的类型是 bool?（插件里可空），不能直接取反
                if (req.isForMainFrame != true) return;
                if (!mounted) return;
                setState(() {
                  _loading = false;
                  _redirected = false;
                  _error = err.description;
                });
              },
            ),
          ),
          SizedBox.expand(child: _errorView()),
        ],
      ),
    );
  }

  Widget _errorView() {
    final AppColors c = context.c;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              _redirected ? Icons.help_outline_rounded : Icons.cloud_off_rounded,
              size: 40,
              color: c.textSecondary,
            ),
            const SizedBox(height: 14),
            Text(
              _redirected ? '弹幕姬里没有这个直播间' : '弹幕姬页面加载失败',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
            if (_redirected) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '该站每个直播间都有固定页面，被跳回首页通常说明这个房间没有登记。'
                '可以点下面「用浏览器打开」再试一次。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                setState(() {
                  _error = null;
                  _loading = true;
                  _redirected = false;
                });
                _controller?.reload();
              },
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => openExternal(_url),
              child: const Text('用浏览器打开'),
            ),
          ],
        ),
      ),
    );
  }
}
