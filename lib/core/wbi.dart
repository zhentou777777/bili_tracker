/// B 站 WBI 签名（2023 年后的强制要求）。
///
/// 不做这个签名，`x/space/arc/search` 一类接口会直接被拒。
/// 流程：nav 取 img_key/sub_key → 生成 mixin_key → 参数加 wts 后 md5(query + mixin_key)。
///
/// 依赖注入 [_navFetcher]，使该模块在 CLI 探针中可脱离 App 独立验证。
library wbi;

import 'dart:convert';

import 'md5.dart';

/// 官方 mixin key 重排表（64 项，取前 32 位）。
const List<int> kWbiMixinTable = <int>[
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
  27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
  37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
  22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

/// 参与签名前必须剔除的字符，B 站服务端会先做这一步再校验。
const String kWbiStripChars = "!'()*";

/// 严格对齐 Python `urllib.parse.quote_plus` 的表单编码。
///
/// 大小写敏感：服务端用大写十六进制拼串后再算 md5，写成小写会直接校验失败。
String formEncode(String input) {
  final StringBuffer sb = StringBuffer();
  for (final int byte in utf8.encode(input)) {
    final bool isUnreserved =
        (byte >= 0x30 && byte <= 0x39) || // 0-9
        (byte >= 0x41 && byte <= 0x5A) || // A-Z
        (byte >= 0x61 && byte <= 0x7A) || // a-z
        byte == 0x5F || // _
        byte == 0x2E || // .
        byte == 0x2D || // -
        byte == 0x7E; // ~
    if (isUnreserved) {
      sb.writeCharCode(byte);
    } else if (byte == 0x20) {
      sb.write('+');
    } else {
      sb.write('%');
      sb.write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
  }
  return sb.toString();
}

/// mixin_key 的本地缓存，避免每次请求都打 nav 接口。
class WbiKeyCache {
  WbiKeyCache(this._navFetcher, {Duration ttl = const Duration(hours: 6)})
      : _ttl = ttl;

  final Future<Map<String, dynamic>?> Function() _navFetcher;
  final Duration _ttl;

  String? _mixinKey;
  DateTime? _fetchedAt;

  bool get isValid =>
      _mixinKey != null &&
      _fetchedAt != null &&
      DateTime.now().difference(_fetchedAt!) < _ttl;

  String? get current => _mixinKey;

  /// 手动写入（探针或服务端下发时使用）。
  void seed(String mixinKey) {
    _mixinKey = mixinKey;
    _fetchedAt = DateTime.now();
  }

  void clear() {
    _mixinKey = null;
    _fetchedAt = null;
  }

  /// 从 nav 响应中提取 wbi_img 并派生 mixin_key。
  /// nav 未登录也能返回密钥，因此这一步不依赖 Cookie。
  Future<String?> refresh() async {
    final Map<String, dynamic>? nav = await _navFetcher();
    final String? key = deriveMixinKey(nav);
    if (key != null) {
      seed(key);
    }
    return key;
  }

  Future<String?> get({bool force = false}) async {
    if (!force && isValid) return _mixinKey;
    return refresh();
  }

  /// 从 nav 的 `data.wbi_img` 派生 mixin_key。
  static String? deriveMixinKey(Map<String, dynamic>? nav) {
    if (nav == null) return null;
    final Object? data = nav['data'];
    if (data is! Map) return null;
    final Object? wbi = data['wbi_img'];
    if (wbi is! Map) return null;

    final String? imgUrl = wbi['img_url']?.toString();
    final String? subUrl = wbi['sub_url']?.toString();
    if (imgUrl == null || subUrl == null) return null;

    final String? imgKey = _keyFromUrl(imgUrl);
    final String? subKey = _keyFromUrl(subUrl);
    if (imgKey == null || subKey == null) return null;

    final String raw = imgKey + subKey;
    final StringBuffer sb = StringBuffer();
    for (final int idx in kWbiMixinTable) {
      if (idx < raw.length) sb.write(raw[idx]);
    }
    final String key = sb.toString();
    return key.length >= 32 ? key.substring(0, 32) : null;
  }

  static String? _keyFromUrl(String url) {
    final int slash = url.lastIndexOf('/');
    if (slash < 0) return null;
    String name = url.substring(slash + 1);
    final int dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name.isEmpty ? null : name;
  }
}

/// WBI 签名器。
class WbiSigner {
  WbiSigner(this._cache);

  final WbiKeyCache _cache;

  /// 给 [params] 加上 `wts` 与 `w_rid`，返回可直接拼接的 query 串（已排序）。
  ///
  /// [params] 中已有的 `w_rid` 会被忽略，避免二次签名时把旧值算进去。
  Future<String?> signQuery(
    Map<String, Object> params, {
    DateTime? now,
  }) async {
    final String? mixinKey = await _cache.get();
    if (mixinKey == null) return null;

    final int wts = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final Map<String, String> merged = <String, String>{
      for (final MapEntry<String, Object> e in params.entries)
        if (e.key.toLowerCase() != 'w_rid') e.key: e.value.toString(),
      'wts': wts.toString(),
    };

    // 过滤 !'()* 后按 key 字典序排序
    final List<String> keys = merged.keys.toList()..sort();
    final List<String> parts = <String>[];
    for (final String k in keys) {
      String v = merged[k]!;
      for (final int code in kWbiStripChars.codeUnits) {
        v = v.replaceAll(String.fromCharCode(code), '');
      }
      parts.add('${formEncode(k)}=${formEncode(v)}');
    }

    final String query = parts.join('&');
    final String wRid = md5String(query + mixinKey);
    return '$query&w_rid=$wRid';
  }

  /// 返回可直接塞进 Dio `queryParameters` 之外追加的 Map。
  Future<Map<String, String>?> signParams(
    Map<String, Object> params, {
    DateTime? now,
  }) async {
    final String? q = await signQuery(params, now: now);
    if (q == null) return null;
    final Map<String, String> out = <String, String>{};
    for (final String seg in q.split('&')) {
      final int eq = seg.indexOf('=');
      if (eq <= 0) continue;
      out[seg.substring(0, eq)] = Uri.decodeQueryComponent(seg.substring(eq + 1));
    }
    out.remove('w_rid');
    return out;
  }
}
