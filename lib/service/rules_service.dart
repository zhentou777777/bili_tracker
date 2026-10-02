/// 规则加载：本地内置兜底 + 远端覆盖。
///
/// 接口被改时，改一份 JSON 就能恢复，不必发版重审。
library rules_service;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/rules.dart';

class RulesService {
  RulesService({required Dio dio, required SharedPreferences prefs})
      : _dio = dio,
        _prefs = prefs;

  static const String _bundledPath = 'assets/rules/platforms.json';
  static const String _prefRemoteUrl = 'rules_remote_url';
  static const String _prefCached = 'rules_cached_json';
  static const String _prefCachedAt = 'rules_cached_at';

  final Dio _dio;
  final SharedPreferences _prefs;

  RuleSet? _current;

  RuleSet get current => _current ??= const RuleSet(
        version: 0,
        updatedAt: '',
        platforms: <PlatformRule>[],
        source: 'empty',
      );

  String? get remoteUrl => _prefs.getString(_prefRemoteUrl);

  Future<void> setRemoteUrl(String url) async {
    await _prefs.setString(_prefRemoteUrl, url.trim());
  }

  /// 启动加载：先读缓存与内置，取**版本更高**的那个，再尝试远端更新。
  ///
  /// 为什么不是「有缓存就直接用缓存」：那份缓存是用户在某个旧版本上留下的。
  /// 一旦接口下线（例如动态接口从 `dynamic_svr/space_history` 换成
  /// `polymer/web-dynamic/v1/feed/space`），旧缓存里的死端点会一直被沿用，
  /// 内置的新规则永远生效不了 —— 表现就是「升级了 App 还是抓不到动态」。
  Future<RuleSet> load() async {
    // 1. 远端缓存
    RuleSet? cachedSet;
    final String? cached = _prefs.getString(_prefCached);
    if (cached != null && cached.isNotEmpty) {
      try {
        cachedSet = RuleSet.fromJsonString(cached, source: 'cache');
      } catch (_) {
        cachedSet = null;
      }
    }

    // 2. 本地内置
    RuleSet? bundledSet;
    try {
      final String bundled = await rootBundle.loadString(_bundledPath);
      bundledSet = RuleSet.fromJsonString(bundled, source: 'bundled');
    } catch (_) {
      bundledSet = null;
    }

    // 3. 版本更高的胜出（内置更新时必须压过旧缓存）
    if (bundledSet != null &&
        (cachedSet == null || bundledSet.version > cachedSet.version)) {
      _current = bundledSet;
    } else {
      _current = cachedSet ?? bundledSet;
    }

    // 4. 后台尝试远端更新（失败静默，不影响启动）
    await refreshFromRemote();
    return current;
  }

  /// 拉取远端规则；未配置地址或失败则保持现有规则。
  Future<bool> refreshFromRemote() async {
    final String? url = remoteUrl;
    if (url == null || url.isEmpty) return false;
    try {
      final Response<dynamic> resp = await _dio.get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          // 规则是公开静态资源，不需要任何身份信息
          headers: <String, String>{'Cache-Control': 'no-cache'},
        ),
      );
      final String body = resp.data?.toString() ?? '';
      if (body.isEmpty) return false;

      final RuleSet remote = RuleSet.fromJsonString(body, source: 'remote');
      final bool newer = remote.version >= current.version;
      if (newer) {
        _current = remote;
        await _prefs.setString(_prefCached, body);
        await _prefs.setString(
          _prefCachedAt,
          DateTime.now().toIso8601String(),
        );
      }
      return newer;
    } catch (_) {
      return false;
    }
  }

  /// 导出当前规则，便于排查问题。
  String exportJson() => jsonEncode(<String, Object?>{
        'version': current.version,
        'updated_at': current.updatedAt,
        'source': current.source,
        'platforms': <Object?>[
          for (final PlatformRule p in current.platforms)
            <String, Object?>{
              'id': p.id,
              'name': p.name,
              'enabled': p.enabled,
              'endpoints': p.endpoints.keys.toList(),
            },
        ],
      });
}
