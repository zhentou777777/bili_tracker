/// 平台接口规则表：端点地址、参数、解析路径全部外置为 JSON。
///
/// 目的：B 站 / 微博的接口说变就变，改一份 JSON 就能救回来，不必发版。
/// 本文件保持纯 Dart 零依赖，CLI 探针与 App 共用同一套加载逻辑。
library rules;

import 'dart:convert';

/// 按点路径取值，支持 Map 与 List 下标混合，如 `data.list.vlist`。
Object? getByPath(Object? root, String path) {
  if (path.isEmpty) return root;
  Object? cur = root;
  for (final String part in path.split('.')) {
    if (cur is Map) {
      cur = cur[part];
    } else if (cur is List) {
      final int? idx = int.tryParse(part);
      if (idx == null || idx < 0 || idx >= cur.length) return null;
      cur = cur[idx];
    } else {
      return null;
    }
  }
  return cur;
}

/// 单个接口规则。
class EndpointRule {
  const EndpointRule({
    required this.url,
    this.method = 'GET',
    this.referer = '',
    this.requireCookie = false,
    this.requireSign = false,
    this.params = const <String, String>{},
    this.repeatParam,
    this.listPath = '',
    this.totalPath = '',
    this.nextOffsetPath = '',
    this.hasMorePath = '',
    this.parser = 'generic',
    this.itemMap = const <String, String>{},
    this.note = '',
  });

  final String url;
  final String method;
  final String referer;
  final bool requireCookie;
  final bool requireSign;
  final Map<String, String> params;

  /// 需要重复出现的同名参数（B 站的 `uids[]=1&uids[]=2`）。
  final Map<String, String>? repeatParam;

  final String listPath;
  final String totalPath;
  final String nextOffsetPath;
  final String hasMorePath;

  /// 解析策略名：generic 走 item_map，复杂结构走专用 parser。
  final String parser;
  final Map<String, String> itemMap;
  final String note;

  factory EndpointRule.fromJson(Map<String, dynamic> json) => EndpointRule(
        url: json['url']?.toString() ?? '',
        method: (json['method']?.toString() ?? 'GET').toUpperCase(),
        referer: json['referer']?.toString() ?? '',
        requireCookie: json['require_cookie'] == true,
        requireSign: json['require_sign'] == true,
        params: _stringMap(json['params']),
        repeatParam: json['repeat_param'] == null
            ? null
            : _stringMap(json['repeat_param']),
        listPath: json['list_path']?.toString() ?? '',
        totalPath: json['total_path']?.toString() ?? '',
        nextOffsetPath: json['next_offset_path']?.toString() ?? '',
        hasMorePath: json['has_more_path']?.toString() ?? '',
        parser: json['parser']?.toString() ?? 'generic',
        itemMap: _stringMap(json['item_map']),
        note: json['note']?.toString() ?? '',
      );

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    return <String, String>{
      for (final MapEntry<dynamic, dynamic> e in raw.entries)
        e.key.toString(): e.value?.toString() ?? '',
    };
  }
}

/// 平台规则。
class PlatformRule {
  const PlatformRule({
    required this.id,
    required this.name,
    required this.brandColor,
    required this.enabled,
    required this.sign,
    required this.loginUrl,
    required this.cookieDomains,
    required this.requiredCookies,
    required this.deviceCookies,
    required this.selfUidCookie,
    required this.endpoints,
  });

  final String id;
  final String name;
  final String brandColor;
  final bool enabled;
  final String sign; // wbi / none
  final String loginUrl;
  final List<String> cookieDomains;
  final List<String> requiredCookies;
  final List<String> deviceCookies;

  /// 从哪个 Cookie 字段读取当前登录用户的 UID。
  final String selfUidCookie;
  final Map<String, EndpointRule> endpoints;

  EndpointRule? endpoint(String name) => endpoints[name];

  factory PlatformRule.fromJson(Map<String, dynamic> json) => PlatformRule(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        brandColor: json['brand_color']?.toString() ?? '#888888',
        enabled: json['enabled'] == true,
        sign: json['sign']?.toString() ?? 'none',
        loginUrl: json['login_url']?.toString() ?? '',
        cookieDomains: _stringList(json['cookie_domains']),
        requiredCookies: _stringList(json['required_cookies']),
        deviceCookies: _stringList(json['device_cookies']),
        selfUidCookie: json['self_uid_cookie']?.toString() ?? '',
        endpoints: <String, EndpointRule>{
          if (json['endpoints'] is Map)
            for (final MapEntry<dynamic, dynamic> e
                in (json['endpoints'] as Map).entries)
              e.key.toString(): EndpointRule.fromJson(
                    Map<String, dynamic>.from(e.value as Map),
                  ),
        },
      );

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const <String>[];
    return <String>[for (final Object? v in raw) v?.toString() ?? ''];
  }
}

/// 完整规则集。
class RuleSet {
  const RuleSet({
    required this.version,
    required this.updatedAt,
    required this.platforms,
    this.source = 'bundled',
  });

  final int version;
  final String updatedAt;
  final List<PlatformRule> platforms;

  /// 来源标记：bundled / remote / cache，便于排查规则生效情况。
  final String source;

  PlatformRule? platform(String id) {
    for (final PlatformRule p in platforms) {
      if (p.id == id) return p;
    }
    return null;
  }

  factory RuleSet.fromJsonString(String raw, {String source = 'bundled'}) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('规则文件根节点必须是对象');
    }
    final Map<String, dynamic> json = Map<String, dynamic>.from(decoded);
    return RuleSet(
      version: json['version'] is num ? (json['version'] as num).toInt() : 0,
      updatedAt: json['updated_at']?.toString() ?? '',
      source: source,
      platforms: <PlatformRule>[
        if (json['platforms'] is List)
          for (final Object? p in json['platforms'] as List)
            if (p is Map)
              PlatformRule.fromJson(Map<String, dynamic>.from(p)),
      ],
    );
  }
}

/// 把 `{uid}` 形式的占位符替换为实际值。
String renderTemplate(String template, Map<String, String> vars) {
  String out = template;
  for (final MapEntry<String, String> v in vars.entries) {
    out = out.replaceAll('{${v.key}}', v.value);
  }
  return out;
}

/// 渲染接口参数（跳过值仍为空占位符的参数）。
Map<String, String> renderParams(
  Map<String, String> params,
  Map<String, String> vars,
) {
  final Map<String, String> out = <String, String>{};
  for (final MapEntry<String, String> e in params.entries) {
    final String value = renderTemplate(e.value, vars);
    if (value.contains('{') && value.contains('}')) continue;
    out[e.key] = value;
  }
  return out;
}
