/// 极薄的 HTTP 抽象。
///
/// 之所以抽象出来：App 里跑 Dio，CLI 探针里跑 dart:io，两边共用同一套适配器逻辑。
library http_core;

/// 模拟浏览器的 User-Agent。
///
/// 定义在 `core` 而不是 `platform`：`DioHttpSender`（core 层）也要用，
/// 而 core 不应该反向依赖 platform。原先这段字符串在
/// `platform/bilibili.dart` 与 `core/dio_sender.dart` 里各写了一份，
/// 改一处漏一处的风险很实在 —— 少了它会被 B 站直接判成爬虫。
const String kBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 请求结果。
class HttpResp {
  const HttpResp({
    required this.status,
    required this.body,
    this.headers = const <String, String>{},
    this.setCookies = const <String>[],
  });

  final int status;
  final String body;
  final Map<String, String> headers;

  /// 原始 `Set-Cookie` 头，**每一行是独立的**。
  ///
  /// 不能合并成一个字符串：浏览器/HTTP 库普遍不允许把多个 Set-Cookie 拼起来，
  /// 一旦拼接，后面每个 Cookie 的属性（Path/Domain/HttpOnly）都会被归到第一个
  /// Cookie 名下，解析必然出错。
  ///
  /// 登录链路依赖它：扫码成功后 SESSDATA / bili_jct / DedeUserID 就是从这里下发的，
  /// 而 SESSDATA 是 HttpOnly，JS 与 WebView 的 `document.cookie` 都读不到。
  final List<String> setCookies;

  bool get isOk => status >= 200 && status < 300;
}

/// 统一的网络出口。
abstract class HttpSender {
  /// [followRedirects] 默认 true。
  ///
  /// 登录回调（crossDomain）必须传 false：SESSDATA 挂在**第一跳 302** 的
  /// Set-Cookie 上，自动跟随重定向会让这一跳的响应头被静默丢弃，
  /// 表现为「扫码成功但 Cookie 为空」。
  Future<HttpResp> get(
    String url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  });
}

/// 平台接口返回的业务错误 / 风控。
///
/// code 语义（B 站）：
/// -101 未登录（Cookie 失效，需重新登录）
/// -352 风控校验失败（降频 + 补设备指纹）
/// -403 签名错误（WBI 链路出错）
/// -412 HTTP 层风控（通常缺 buvid3）
class ApiException implements Exception {
  const ApiException(this.code, this.message, {this.statusCode});

  final int code;
  final String message;
  final int? statusCode;

  bool get isNotLogin => code == -101;
  bool get isRiskControl => code == -352 || code == -412 || statusCode == 412;
  bool get isBadSign => code == -403;

  @override
  String toString() => 'ApiException($code): $message';
}
