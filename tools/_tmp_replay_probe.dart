// 临时探针：实测「关注的 UP 的投稿里能不能可靠判定直播回放」。跑完即删。
// ignore_for_file: avoid_print, avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import '../lib/core/wbi.dart';

const String UA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

String cookie = '';
Map<String, dynamic> lastJson = <String, dynamic>{};

Future<Object?> getJson(String url, {String referer = 'https://www.bilibili.com/'}) async {
  final HttpClient c = HttpClient();
  String body;
  try {
    final HttpClientRequest r = await c.getUrl(Uri.parse(url));
    r.headers.set('User-Agent', UA);
    r.headers.set('Referer', referer);
    if (cookie.isNotEmpty) r.headers.set('Cookie', cookie);
    final HttpClientResponse resp = await r.close();
    body = await resp.transform(utf8.decoder).join();
  } finally {
    c.close();
  }
  try {
    return jsonDecode(body);
  } catch (_) {
    print('  (响应不是 JSON，前 60 字：' + body.substring(0, body.length > 60 ? 60 : body.length) + ')');
    return null;
  }
}

Future<Map<String, dynamic>?> navJson() async {
  final Object? d = await getJson('https://api.bilibili.com/x/web-interface/nav');
  return d is Map ? Map<String, dynamic>.from(d) : null;
}

void main() async {
  // 先拿 buvid3，否则搜索/空间接口直接回风控页
  final Object? spi = await getJson('https://api.bilibili.com/x/frontend/finger/spi');
  if (spi is Map && spi['data'] is Map) {
    final Map<String, dynamic> dd = Map<String, dynamic>.from(spi['data'] as Map);
    cookie = 'buvid3=' + (dd['b_3'] ?? '').toString() + '; buvid4=' + (dd['b_4'] ?? '').toString();
    print('已取到设备指纹 buvid3/buvid4');
  } else {
    print('拿不到设备指纹，后面可能被风控');
  }

  final WbiSigner signer = WbiSigner(WbiKeyCache(navJson));

  print('');
  print('=== [1] 空间内搜索「回放」，看一个真实 UP 的投稿字段 ===');
  const String mid = '672328094';
  final String? q = await signer.signQuery(<String, String>{
    'mid': mid,
    'pn': '1',
    'ps': '16',
    'order': 'pubdate',
    'tid': '0',
    'keyword': '',
    'platform': 'web',
    'web_location': '1550101',
  });
  if (q == null) {
    print('  WBI 签名失败');
    return;
  }
  final Object? d = await getJson(
      'https://api.bilibili.com/x/space/wbi/arc/search?' + q,
      referer: 'https://space.bilibili.com/' + mid + '/video');
  if (d is! Map) return;
  final Map<String, dynamic> m = Map<String, dynamic>.from(d);
  print('  code=' + m['code'].toString() + ' msg=' + (m['message'] ?? '').toString());
  final Object? data = m['data'];
  if (data is! Map) return;
  final Object? list = data['list'];
  final Object? vlist = (list is Map) ? list['vlist'] : null;
  if (vlist is! List || vlist.isEmpty) {
    print('  没有 vlist');
    return;
  }
  print('  单条全部字段：');
  print('    ' + (vlist.first as Map).keys.join(', '));
  print('');
  print('  逐条：tid | tname | 标题');
  for (final Object? it in vlist) {
    if (it is! Map) continue;
    final String t = (it['title'] ?? '').toString();
    print('    ' + (it['tid'] ?? '?').toString().padRight(7) +
        (it['tname'] ?? '?').toString().padRight(12) +
        (t.length > 26 ? t.substring(0, 26) : t));
  }

  print('');
  print('=== [2] 用「直播回放」关键词搜视频，看命中视频落在哪些分区 ===');
  final String? q2 = await signer.signQuery(<String, String>{
    'search_type': 'video',
    'keyword': '直播回放',
    'page': '1',
    'page_size': '20',
  });
  if (q2 == null) return;
  final Object? d2 = await getJson(
      'https://api.bilibili.com/x/web-interface/wbi/search/type?' + q2,
      referer: 'https://search.bilibili.com/');
  if (d2 is! Map) return;
  final Map<String, dynamic> m2 = Map<String, dynamic>.from(d2);
  print('  code=' + m2['code'].toString() + ' msg=' + (m2['message'] ?? '').toString());
  final Object? res = (m2['data'] is Map) ? (m2['data'] as Map)['result'] : null;
  if (res is! List || res.isEmpty) {
    print('  result 为空');
    return;
  }
  final Map<String, int> byType = <String, int>{};
  for (final Object? it in res) {
    if (it is! Map) continue;
    final String k = (it['typeid'] ?? '?').toString() + ' / ' + (it['typename'] ?? '?').toString();
    byType[k] = (byType[k] ?? 0) + 1;
  }
  print('  分区分布（共 ' + res.length.toString() + ' 条）：');
  final List<MapEntry<String, int>> es = byType.entries.toList()
    ..sort((MapEntry<String, int> a, MapEntry<String, int> b) => b.value.compareTo(a.value));
  for (final MapEntry<String, int> e in es) {
    print('    ' + e.key + '  × ' + e.value.toString());
  }
}
