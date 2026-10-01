/// 极薄的 HTTP 抽象。
///
/// 之所以抽象出来：App 里跑 Dio，CLI 探针里跑 dart:io，两边共用同一套适配器逻辑。
library http_core;

/// 请求结果。
class HttpResp {
  const HttpResp({required this.status, required this.body, this.headers = const <String, String>{}});

  final int status;
  final String body;
  final Map<String, String> headers;

  bool get isOk => status >= 200 && status < 300;
}

/// 统一的网络出口。
abstract class HttpSender {
  Future<HttpResp> get(String url, {Map<String, String>? headers});
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
