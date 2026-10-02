import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'external_link.dart';
import 'theme.dart';

/// 直播间弹幕姬（LAPLACE Chat）。
///
/// 接入方式很简单：该服务给每个直播间提供一个**固定页面**
/// `https://chat.vrp.moe/dashboard/{房间号}`，用内嵌 WebView 打开即可。
/// （房间里的事件订阅、样式、TTS 等都由那个页面自己处理，我们不需要对接
/// 它的长连接 —— 它也没有公开 API 文档。）
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

  String get _url => 'https://chat.vrp.moe/dashboard/${widget.roomId}';

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
              });
              _controller?.reload();
            },
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
      body: _error != null
          ? _errorView()
          : InAppWebView(
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
                if (mounted) {
                  setState(() {
                    _loading = false;
                    _error = null;
                  });
                }
              },
              onReceivedError:
                  (InAppWebViewController controller, WebResourceRequest req,
                      WebResourceError err) {
                // 只在意主文档的失败；子资源（图片/接口）失败不该整页报错
                // isForMainFrame 的类型是 bool?（插件里可空），不能直接取反
                if (req.isForMainFrame != true) return;
                if (!mounted) return;
                setState(() {
                  _loading = false;
                  _error = err.description;
                });
              },
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
            Icon(Icons.cloud_off_rounded, size: 40, color: c.textSecondary),
            const SizedBox(height: 14),
            Text(
              '弹幕姬页面加载失败',
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
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                setState(() {
                  _error = null;
                  _loading = true;
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
