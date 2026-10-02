/// App 侧的 HTTP 实现：Dio + 持久化 Cookie Jar。
///
/// Cookie Jar 的作用不是存登录态（登录态在 Keystore 里），
/// 而是自动维护 buvid3 / b_nut 这类设备指纹 —— 缺了它们，接口会回 -352 风控。
library dio_sender;

import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

import 'http.dart';

/// 用户 Cookie 注入源（来自安全存储）。
typedef UserCookieSource = Future<String> Function();

class DioHttpSender implements HttpSender {
  DioHttpSender({
    required Dio dio,
    required PersistCookieJar jar,
    required UserCookieSource userCookies,
  })  : _dio = dio,
        _jar = jar,
        _userCookies = userCookies;

  final Dio _dio;
  final PersistCookieJar _jar;
  final UserCookieSource _userCookies;

  /// 确保 jar 里有设备指纹 buvid3。
  ///
  /// 这不是「优化」而是硬依赖：新版空间动态接口
  /// （`x/polymer/web-dynamic/v1/feed/space`）实测在缺 buvid3 时直接回
  /// HTTP 412（风控页，响应体是 HTML 而不是 JSON）。
  ///
  /// 两条路：① 请求首页拿 Set-Cookie；② 拿不到就退回
  /// `/x/frontend/finger/spi` 把 b_3/b_4 手动写进 jar。
  Future<void> ensureDeviceCookies({String url = 'https://www.bilibili.com/'}) async {
    try {
      if (await _hasBuvid3()) return;

      await _dio.get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, String>{
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          },
        ),
      );
      // Set-Cookie 已由 dio_cookie_manager 写入 jar
      if (await _hasBuvid3()) return;
    } catch (_) {
      // 首页失败不阻断，继续走 spi 兜底
    }

    try {
      if (await _hasBuvid3()) return;
      final Response<dynamic> resp = await _dio.get<dynamic>(
        'https://api.bilibili.com/x/frontend/finger/spi',
        options: Options(
          responseType: ResponseType.plain,
          headers: <String, String>{
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Referer': 'https://www.bilibili.com/',
          },
        ),
      );
      final Object? decoded = jsonDecode(resp.data?.toString() ?? '');
      if (decoded is Map && decoded['data'] is Map) {
        final Map<String, dynamic> d =
            Map<String, dynamic>.from(decoded['data'] as Map);
        final List<Cookie> cookies = <Cookie>[
          if ((d['b_3'] ?? '').toString().isNotEmpty)
            Cookie('buvid3', d['b_3'].toString())..domain = '.bilibili.com',
          if ((d['b_4'] ?? '').toString().isNotEmpty)
            Cookie('buvid4', d['b_4'].toString())..domain = '.bilibili.com',
        ];
        if (cookies.isNotEmpty) {
          await _jar.saveFromResponse(
            Uri.parse('https://www.bilibili.com/'),
            cookies,
          );
        }
      }
    } catch (_) {
      // 指纹拿不到不阻断主流程，只是风控概率上升
    }
  }

  Future<bool> _hasBuvid3() async {
    final List<Cookie> existing =
        await _jar.loadForRequest(Uri.parse('https://www.bilibili.com/'));
    return existing.any(
      (Cookie c) => c.name.toLowerCase() == 'buvid3' && c.value.isNotEmpty,
    );
  }

  @override
  Future<HttpResp> get(
    String url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) async {
    final Uri uri = Uri.parse(url);

    // jar 指纹 + 用户 Cookie，用户字段优先
    final Map<String, String> merged = <String, String>{
      for (final Cookie c in await _jar.loadForRequest(uri)) c.name: c.value,
      ..._parseCookieHeader(await _userCookies()),
    };

    final Map<String, String> h = <String, String>{
      if (headers != null) ...headers,
      if (merged.isNotEmpty)
        'Cookie': <String>[
          for (final MapEntry<String, String> e in merged.entries) '${e.key}=${e.value}',
        ].join('; '),
    };

    final Response<dynamic> resp = await _dio.get<dynamic>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: h,
        followRedirects: followRedirects,
        // 不跟随重定向时，302 本身不是错误，必须放行，否则拿不到那一跳的响应头。
        //
        // 顺带修正一处历史不一致：Dio 默认对非 2xx 抛 DioException，于是 412
        // 风控会以 DioException 抛出，`BilibiliAdapter._request` 里那句
        // `if (!resp.isOk) throw ApiException(-412)` 永远走不到，
        // ApiException.isRiskControl 也就失效了。这里统一放行，
        // 由调用方按 status 判断，语义回到设计时的样子。
        validateStatus: (_) => true,
      ),
    );

    return HttpResp(
      status: resp.statusCode ?? 0,
      body: resp.data?.toString() ?? '',
      setCookies: _setCookiesOf(resp),
    );
  }

  /// 取出响应里的 `Set-Cookie` 多行原始值。
  ///
  /// Dio 把响应头归一到 `Map<String, List<String>>`，`set-cookie` 天然是多值，
  /// 这里直接把整个 List 原样带出去，不做任何拼接。
  static List<String> _setCookiesOf(Response<dynamic> resp) {
    final List<String>? raw = resp.headers.map['set-cookie'];
    if (raw == null || raw.isEmpty) return const <String>[];
    return <String>[
      for (final String v in raw)
        if (v.trim().isNotEmpty) v.trim(),
    ];
  }

  static Map<String, String> _parseCookieHeader(String header) {
    final Map<String, String> out = <String, String>{};
    for (final String seg in header.split(';')) {
      final int eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final String k = seg.substring(0, eq).trim();
      if (k.isEmpty) continue;
      out[k] = seg.substring(eq + 1).trim();
    }
    return out;
  }
}
