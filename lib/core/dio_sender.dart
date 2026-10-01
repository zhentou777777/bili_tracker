/// App 侧的 HTTP 实现：Dio + 持久化 Cookie Jar。
///
/// Cookie Jar 的作用不是存登录态（登录态在 Keystore 里），
/// 而是自动维护 buvid3 / b_nut 这类设备指纹 —— 缺了它们，接口会回 -352 风控。
library dio_sender;

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

  /// 首次访问时向 B 站首页要一次设备指纹。
  ///
  /// 用户 Cookie 里通常已带 buvid3，这里只是兜底。
  Future<void> ensureDeviceCookies({String url = 'https://www.bilibili.com/'}) async {
    try {
      final List<Cookie> existing =
          await _jar.loadForRequest(Uri.parse('https://www.bilibili.com/'));
      final bool hasBuvid =
          existing.any((Cookie c) => c.name.toLowerCase() == 'buvid3');
      if (hasBuvid) return;

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
    } catch (_) {
      // 指纹拿不到不阻断主流程，只是风控概率上升
    }
  }

  @override
  Future<HttpResp> get(String url, {Map<String, String>? headers}) async {
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
      options: Options(responseType: ResponseType.plain, headers: h),
    );

    return HttpResp(
      status: resp.statusCode ?? 0,
      body: resp.data?.toString() ?? '',
    );
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
