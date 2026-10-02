// 扫码登录链路的单元测试。
//
// 测的都是纯逻辑，不碰网络：
//   - 规则文件里登录端点的解析（LoginRule）
//   - 扫码状态码 → 语义 的映射（外层 code 恒为 0，真实状态在 data.code）
//   - Set-Cookie 解析（重点：不能把「删除指令」当成下发）
//
// 真实接口的可用性由 `tools/probe.dart` 第 [10] 节在线验证，这里只保证
// 「拿到响应之后算得对不对」—— 这部分一旦算错，症状是
// 「扫码成功了但登录不上」，排查成本很高，所以值得单独钉住。

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_tracker/core/rules.dart';
import 'package:bili_tracker/platform/bilibili.dart';
import 'package:bili_tracker/platform/models.dart';

const LoginRule _rule = LoginRule(
  mode: 'qr_deeplink',
  qrGenerateUrl: 'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
  qrGenerateParams: <String, String>{},
  qrPollUrl: 'https://passport.bilibili.com/x/passport-login/web/qrcode/poll',
  qrPollParams: <String, String>{},
  crossDomainReferer: 'https://www.bilibili.com/',
  pollIntervalMs: 2000,
  qrTtlSeconds: 180,
  urlPath: 'data.url',
  keyPath: 'data.qrcode_key',
  statusPath: 'data.code',
  statusMap: <String, String>{
    '0': 'success',
    '86090': 'scanned',
    '86101': 'waiting',
    '86038': 'expired',
  },
  note: '',
);

void main() {
  group('扫码状态码映射', () {
    test('四个已知状态码各自映射正确', () {
      expect(BilibiliAdapter.statusFromCode(_rule, '0'), LoginQrStatus.success);
      expect(BilibiliAdapter.statusFromCode(_rule, '86101'), LoginQrStatus.waiting);
      expect(BilibiliAdapter.statusFromCode(_rule, '86090'), LoginQrStatus.scanned);
      expect(BilibiliAdapter.statusFromCode(_rule, '86038'), LoginQrStatus.expired);
    });

    test('未登记的码返回 unknown，不硬猜语义', () {
      expect(BilibiliAdapter.statusFromCode(_rule, '12345'), LoginQrStatus.unknown);
      expect(BilibiliAdapter.statusFromCode(_rule, ''), LoginQrStatus.unknown);
    });

    test('缺 status_map 时全部视为 unknown', () {
      const LoginRule emptyMap = LoginRule(
        mode: '',
        qrGenerateUrl: 'x',
        qrGenerateParams: <String, String>{},
        qrPollUrl: 'y',
        qrPollParams: <String, String>{},
        crossDomainReferer: '',
        pollIntervalMs: 2000,
        qrTtlSeconds: 180,
        urlPath: '',
        keyPath: '',
        statusPath: '',
        statusMap: <String, String>{},
        note: '',
      );
      expect(BilibiliAdapter.statusFromCode(emptyMap, '0'), LoginQrStatus.unknown);
    });
  });

  group('Set-Cookie 解析', () {
    test('多行原始值全部解析，HttpOnly 不影响取值', () {
      final Map<String, String> c = BilibiliAdapter.parseSetCookieHeaders(<String>[
        'SESSDATA=abc%2Cdef; Path=/; Domain=.bilibili.com; HttpOnly',
        'bili_jct=csrf-token; Path=/; Domain=.bilibili.com',
        'DedeUserID=123456; Path=/',
        'DedeUserID__ckMd5=ffff; Path=/',
      ]);
      expect(c.length, 4);
      expect(c['SESSDATA'], 'abc%2Cdef');
      expect(c['bili_jct'], 'csrf-token');
      expect(c['DedeUserID'], '123456');
      expect(c['DedeUserID__ckMd5'], 'ffff');
    });

    test('值里的等号不会被截断（Base64 / URL 编码常见）', () {
      final Map<String, String> c = BilibiliAdapter.parseSetCookieHeaders(<String>[
        'SESSDATA=a=b=c; Path=/',
      ]);
      expect(c['SESSDATA'], 'a=b=c');
    });

    test('Max-Age<=0 是删除指令，不能当成下发', () {
      final Map<String, String> c = BilibiliAdapter.parseSetCookieHeaders(<String>[
        'SESSDATA=x; Path=/; Max-Age=0',
        'bili_jct=y; Path=/; max-age=-1',
      ]);
      expect(c, isEmpty);
    });

    test('Expires 为 1970 是删除指令', () {
      final Map<String, String> c = BilibiliAdapter.parseSetCookieHeaders(<String>[
        'buvid3=v; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      ]);
      expect(c, isEmpty);
    });

    test('Expires 在未来则是正常下发', () {
      final Map<String, String> c = BilibiliAdapter.parseSetCookieHeaders(<String>[
        'buvid4=v; Path=/; Expires=Fri, 01 Jan 2027 00:00:00 GMT',
      ]);
      expect(c['buvid4'], 'v');
    });

    test('空值丢弃，避免用空 SESSDATA 冒充登录成功', () {
      final Map<String, String> c = BilibiliAdapter.parseSetCookieHeaders(<String>[
        'SESSDATA=; Path=/',
        'b_nut=; Path=/',
        'keepme=ok; Path=/',
      ]);
      expect(c.length, 1);
      expect(c['keepme'], 'ok');
    });

    test('畸形行不抛异常，直接跳过', () {
      final Map<String, String> c = BilibiliAdapter.parseSetCookieHeaders(<String>[
        'notacookie',
        '=novalue; Path=/',
        '',
        '  ',
        'good=1; Path=/',
      ]);
      expect(c.length, 1);
      expect(c['good'], '1');
    });

    test('空输入返回空表', () {
      expect(BilibiliAdapter.parseSetCookieHeaders(<String>[]), isEmpty);
    });

    test('同名 Cookie 以最后一行为准', () {
      final Map<String, String> c = BilibiliAdapter.parseSetCookieHeaders(<String>[
        'SESSDATA=old; Path=/',
        'SESSDATA=new; Path=/',
      ]);
      expect(c['SESSDATA'], 'new');
    });
  });

  group('登录结果对象语义', () {
    test('success 且有 Cookie 才算真正登录成功', () {
      const LoginPollResult r = LoginPollResult(
        status: LoginQrStatus.success,
        cookies: <String, String>{'SESSDATA': 'x'},
      );
      expect(r.isSuccess, isTrue);
      expect(r.isSuccessWithoutCookie, isFalse);
    });

    test('success 但 Cookie 为空必须能被识别出来', () {
      const LoginPollResult r =
          LoginPollResult(status: LoginQrStatus.success, cookies: <String, String>{});
      expect(r.isSuccess, isTrue);
      expect(r.isSuccessWithoutCookie, isTrue);
    });

    test('未扫码不是成功', () {
      const LoginPollResult r = LoginPollResult(status: LoginQrStatus.waiting);
      expect(r.isSuccess, isFalse);
      expect(r.isSuccessWithoutCookie, isFalse);
    });
  });

  group('LoginRule 解析', () {
    test('从真实规则文件结构解析出登录端点', () {
      final RuleSet rs = RuleSet.fromJsonString('''
{
  "version": 5,
  "platforms": [
    {
      "id": "bilibili",
      "login": {
        "mode": "qr_deeplink",
        "qr_generate_url": "https://passport.bilibili.com/x/passport-login/web/qrcode/generate",
        "qr_poll_url": "https://passport.bilibili.com/x/passport-login/web/qrcode/poll",
        "qr_poll_params": { "qrcode_key": "{qrcode_key}" },
        "cross_domain_referer": "https://www.bilibili.com/",
        "poll_interval_ms": 2000,
        "qr_ttl_seconds": 180,
        "status_path": "data.code",
        "status_map": { "0": "success", "86101": "waiting" }
      },
      "endpoints": {}
    }
  ]
}
''');
      final LoginRule lr = rs.platform('bilibili')!.login;
      expect(lr.isEmpty, isFalse);
      expect(lr.mode, 'qr_deeplink');
      expect(lr.qrPollParams['qrcode_key'], '{qrcode_key}');
      expect(lr.crossDomainReferer, 'https://www.bilibili.com/');
      expect(lr.pollIntervalMs, 2000);
      expect(lr.qrTtlSeconds, 180);
      expect(lr.statusPath, 'data.code');
      expect(BilibiliAdapter.statusFromCode(lr, '86101'), LoginQrStatus.waiting);
    });

    test('没有 login 段时给出空规则而不是崩溃', () {
      final RuleSet rs = RuleSet.fromJsonString(
        '{"version": 1, "platforms": [{"id": "weibo", "endpoints": {}}]}',
      );
      expect(rs.platform('weibo')!.login.isEmpty, isTrue);
    });

    test('缺省值兜底：轮询间隔与有效期', () {
      final RuleSet rs = RuleSet.fromJsonString('''
{"version": 1, "platforms": [{"id": "x", "login": {"qr_generate_url": "a", "qr_poll_url": "b"}, "endpoints": {}}]}
''');
      final LoginRule lr = rs.platform('x')!.login;
      expect(lr.isEmpty, isFalse);
      expect(lr.pollIntervalMs, 2000);
      expect(lr.qrTtlSeconds, 180);
      expect(lr.statusPath, 'data.code');
    });
  });
}
