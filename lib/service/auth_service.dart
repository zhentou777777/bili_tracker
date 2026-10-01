/// 账号授权与 Cookie 管理。
///
/// 红线：Cookie 只写本地 Keystore / Keychain，永不出现在任何上行请求里。
/// 服务端拿到的只有「某位 UP 主更新了」这种摘要，不含 Cookie、不含完整内容。
library auth_service;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 除必需字段外还要一并保存的设备指纹类 Cookie。
///
/// 只带 SESSDATA 而不带 buvid3/b_nut 等，B 站会按机器行为判定并回 -352。
const List<String> kExtendedCookieWhitelist = <String>[
  'buvid3',
  'buvid4',
  'buvid_fp',
  'b_nut',
  'b_lsid',
  '_uuid',
  'fingerprint',
  'rpdid',
  'CURRENT_FNVAL',
  'CURRENT_QUALITY',
  'bili_ticket',
  'bili_ticket_expires',
  'sid',
  'bmg_af_switch',
  'PVID',
];

/// 登录态变化通知。
///
/// 只保存内存里的「是否已登录」标记，不碰存储：
/// 真正的 Cookie 读写全部由下面的 AuthService 负责。
class AuthState extends ChangeNotifier {
  final Map<String, bool> _loggedIn = <String, bool>{};

  bool isLoggedIn(String platform) => _loggedIn[platform] ?? false;

  void setLoggedIn(String platform, bool value) {
    if (_loggedIn[platform] == value) return;
    _loggedIn[platform] = value;
    notifyListeners();
  }
}

class AuthService {
  AuthService({
    FlutterSecureStorage? storage,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        state = AuthState();

  static const String _keyPrefix = 'cookie_';
  static const String _keySelfUid = 'self_uid_';
  static const String _keyInvalid = 'invalid_';

  final FlutterSecureStorage _storage;
  final AuthState state;

  String _cookieKey(String platform) => '$_keyPrefix$platform';

  /// 保存从 WebView CookieManager 提取到的 Cookie。
  Future<void> saveCookies(
    String platform, {
    required Map<String, String> cookies,
    required List<String> requiredKeys,
    required String selfUidCookieKey,
  }) async {
    final Map<String, String> filtered = <String, String>{};
    for (final MapEntry<String, String> e in cookies.entries) {
      final bool keep = requiredKeys.contains(e.key) ||
          kExtendedCookieWhitelist.contains(e.key);
      if (keep && e.value.isNotEmpty) filtered[e.key] = e.value;
    }

    final List<String> missing = <String>[
      for (final String k in requiredKeys)
        if ((filtered[k] ?? '').isEmpty) k,
    ];
    if (missing.isNotEmpty) {
      throw AuthException('登录信息不完整，缺少：${missing.join('、')}');
    }

    await _storage.write(
      key: _cookieKey(platform),
      value: jsonEncode(filtered),
    );
    if (selfUidCookieKey.isNotEmpty) {
      final String? uid = cookies[selfUidCookieKey];
      if (uid != null && uid.isNotEmpty) {
        await _storage.write(key: '$_keySelfUid$platform', value: uid);
      }
    }
    await _storage.delete(key: '$_keyInvalid$platform');
    state.setLoggedIn(platform, true);
  }

  Future<Map<String, String>> loadCookies(String platform) async {
    final String? raw = await _storage.read(key: _cookieKey(platform));
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return <String, String>{
        for (final MapEntry<dynamic, dynamic> e in decoded.entries)
          e.key.toString(): e.value.toString(),
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  /// 组装成请求头用的 Cookie 串。
  Future<String> cookieHeader(String platform) async {
    final Map<String, String> cookies = await loadCookies(platform);
    if (cookies.isEmpty) return '';
    return <String>[
      for (final MapEntry<String, String> e in cookies.entries)
        '${e.key}=${e.value}',
    ].join('; ');
  }

  Future<String?> selfUid(String platform) async =>
      _storage.read(key: '$_keySelfUid$platform');

  Future<bool> isLoggedIn(String platform) async {
    final Map<String, String> cookies = await loadCookies(platform);
    return cookies.isNotEmpty;
  }

  /// 标记 Cookie 失效（接口返回 -101 时调用）。
  Future<void> markInvalid(String platform) async {
    await _storage.write(key: '$_keyInvalid$platform', value: '1');
    state.setLoggedIn(platform, false);
  }

  Future<bool> isMarkedInvalid(String platform) async {
    final String? v = await _storage.read(key: '$_keyInvalid$platform');
    return v == '1';
  }

  /// 退出登录：抹掉该平台全部凭据。
  Future<void> clear(String platform) async {
    await _storage.delete(key: _cookieKey(platform));
    await _storage.delete(key: '$_keySelfUid$platform');
    await _storage.delete(key: '$_keyInvalid$platform');
    state.setLoggedIn(platform, false);
  }

  /// 清空所有平台凭据（设置页「清除所有本地数据」）。
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
