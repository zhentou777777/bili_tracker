/// 依赖装配中心。
///
/// 所有平台请求都在这里组装出「带用户 Cookie 的直连客户端」，
/// 全应用不存在任何把 Cookie 发往自有服务端的路径。
library app_context;

import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/dio_sender.dart';
import '../core/rules.dart';
import '../core/wbi.dart';
import '../data/db.dart';
import '../platform/bilibili.dart';
import 'auth_service.dart';
import 'notify_service.dart';
import 'rules_service.dart';

class AppContext {
  AppContext._({
    required this.dio,
    required this.cookieJar,
    required this.prefs,
    required this.rulesService,
    required this.auth,
    required this.db,
    required this.notify,
  });

  final Dio dio;
  final PersistCookieJar cookieJar;
  final SharedPreferences prefs;
  final RulesService rulesService;
  final AuthService auth;
  final AppDatabase db;
  final NotifyService notify;

  /// 按当前规则现造适配器：规则一更新立即生效，不用改代码。
  BilibiliAdapter? bilibiliAdapter() {
    final PlatformRule? rule = rulesService.current.platform('bilibili');
    if (rule == null) return null;

    final DioHttpSender sender = DioHttpSender(
      dio: dio,
      jar: cookieJar,
      userCookies: () => auth.cookieHeader('bilibili'),
    );

    final WbiKeyCache cache = WbiKeyCache(() => _fetchNav(sender, rule));

    return BilibiliAdapter(
      rule: rule,
      sender: sender,
      cookies: () => auth.cookieHeader('bilibili'),
      signer: WbiSigner(cache),
    );
  }

  /// 取 nav（含 wbi 密钥）。未登录也能拿到密钥，因此不强制要求 Cookie。
  static Future<Map<String, dynamic>?> _fetchNav(
    DioHttpSender sender,
    PlatformRule rule,
  ) async {
    final EndpointRule? ep = rule.endpoint('nav');
    if (ep == null) return null;
    try {
      final dynamic resp = await sender.get(
        ep.url,
        headers: <String, String>{
          'User-Agent': kBilibiliUserAgent,
          'Referer': ep.referer,
        },
      );
      final Object? decoded = jsonDecode(resp.body as String);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // nav 失败只影响需要签名的接口，不阻断整体
    }
    return null;
  }

  static Future<AppContext> create() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Dio dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        followRedirects: true,
      ),
    );

    final String docDir = (await getApplicationDocumentsDirectory()).path;
    final PersistCookieJar cookieJar = PersistCookieJar(
      storage: FileStorage(p.join(docDir, 'cookies')),
    );

    final RulesService rulesService = RulesService(dio: dio, prefs: prefs);
    await rulesService.load();

    final AuthService auth = AuthService();
    for (final PlatformRule rule in rulesService.current.platforms) {
      auth.state.setLoggedIn(rule.id, await auth.isLoggedIn(rule.id));
    }

    final AppContext ctx = AppContext._(
      dio: dio,
      cookieJar: cookieJar,
      prefs: prefs,
      rulesService: rulesService,
      auth: auth,
      db: AppDatabase.instance,
      notify: NotifyService(FlutterLocalNotificationsPlugin()),
    );

    await ctx.notify.init();

    // 设备指纹兜底：缺 buvid3 时 -352 风控概率显著上升
    await DioHttpSender(
      dio: dio,
      jar: cookieJar,
      userCookies: () async => '',
    ).ensureDeviceCookies();

    return ctx;
  }
}
