// 动态 / 观看历史解析的单元测试。
//
// 为什么单独一个文件而不是塞进 widget_test.dart：
// 这里测的是纯数据解析（`lib/platform/bilibili.dart` 里没有任何 Flutter 依赖），
// 与被测部件渲染分开，出问题时能一眼看出是「解析错」还是「界面错」。
//
// 样本字段全部取自真实接口响应（2026-10 实测），
// 之所以要做成离线样本：真实接口需要登录态、还会随风控抖动，
// 不适合放进单元测试；离线的可以每次都跑、结果稳定。

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_tracker/platform/bilibili.dart';
import 'package:bili_tracker/platform/models.dart';

/// 构造一条最小可用的新版动态 item。
Map<String, dynamic> _item({
  required String id,
  required String type,
  String name = '碧诗',
  int mid = 2,
  int pubTs = 1783878096,
  Map<String, dynamic>? dyn,
  Map<String, dynamic>? orig,
}) =>
    <String, dynamic>{
      'id_str': id,
      'type': type,
      'modules': <String, dynamic>{
        'module_author': <String, dynamic>{
          'mid': mid,
          'name': name,
          'face': '//i2.hdslb.com/face.jpg',
          'pub_ts': pubTs,
        },
        'module_dynamic': dyn ?? <String, dynamic>{},
      },
      if (orig != null) 'orig': orig,
    };

void main() {
  group('parseDynamicItem 新版空间动态', () {
    test('投稿视频（MAJOR_TYPE_ARCHIVE）', () {
      final FeedItem? it = parseDynamicItem(_item(
        id: '1224236172397510665',
        type: 'DYNAMIC_TYPE_AV',
        dyn: <String, dynamic>{
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_ARCHIVE',
            'archive': <String, dynamic>{
              'bvid': 'BV1ujNV6qEXg',
              'title': '帮不帮？',
              'desc': '去还是不去？',
              'cover': 'http://i2.hdslb.com/bfs/archive/x.jpg',
            },
          },
        },
      ));

      expect(it, isNotNull);
      expect(it!.kind, FeedKind.video);
      expect(it.title, '帮不帮？');
      expect(it.summary, '去还是不去？');
      expect(it.url, 'https://www.bilibili.com/video/BV1ujNV6qEXg');
      // 封面统一升级成 https，便于缓存
      expect(it.cover.startsWith('https://'), isTrue);
      expect(it.itemId, '1224236172397510665');
      expect(it.upUid, '2');
      // pub_ts 是秒，必须正确换算
      expect(it.publishAt.year, 2026);
    });

    test('图文动态有配图 → image，且取第一张图做封面', () {
      final FeedItem? it = parseDynamicItem(_item(
        id: '1253052791646060563',
        type: 'DYNAMIC_TYPE_DRAW',
        dyn: <String, dynamic>{
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_OPUS',
            'opus': <String, dynamic>{
              'jump_url': '//www.bilibili.com/opus/1253052791646060563',
              'summary': <String, dynamic>{'text': '周边余量已上架'},
              'pics': <Map<String, dynamic>>[
                <String, dynamic>{'url': '//i0.hdslb.com/p1.jpg'},
                <String, dynamic>{'url': '//i0.hdslb.com/p2.jpg'},
              ],
            },
          },
        },
      ));

      expect(it!.kind, FeedKind.image);
      expect(it.summary, '周边余量已上架');
      expect(it.cover, 'https://i0.hdslb.com/p1.jpg');
      expect(it.extra?['pic_count'], 2);
      expect(it.url, 'https://www.bilibili.com/opus/1253052791646060563');
    });

    test('纯文字动态无配图 → text', () {
      final FeedItem? it = parseDynamicItem(_item(
        id: '1253728007744389129',
        type: 'DYNAMIC_TYPE_WORD',
        dyn: <String, dynamic>{
          'desc': <String, dynamic>{'text': '今天休息一天'},
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_OPUS',
            'opus': <String, dynamic>{
              'summary': <String, dynamic>{'text': '今天休息一天'},
              'pics': <Object?>[],
            },
          },
        },
      ));

      expect(it!.kind, FeedKind.text);
      expect(it.summary, '今天休息一天');
    });

    test('转发把原动态正文折进摘要，避免只剩一句「分享动态」', () {
      final FeedItem? it = parseDynamicItem(_item(
        id: '1233396749236699159',
        type: 'DYNAMIC_TYPE_FORWARD',
        dyn: <String, dynamic>{
          'desc': <String, dynamic>{'text': '翻得好！'},
        },
        orig: _item(
          id: '1233396000000000000',
          type: 'DYNAMIC_TYPE_AV',
          name: '横川是川崽耶',
          dyn: <String, dynamic>{
            'major': <String, dynamic>{
              'type': 'MAJOR_TYPE_ARCHIVE',
              'archive': <String, dynamic>{
                'bvid': 'BV19PMr6FEfw',
                'title': '请 汤 上 身',
              },
            },
          },
        ),
      ));

      expect(it!.kind, FeedKind.repost);
      expect(it.summary, contains('翻得好！'));
      expect(it.summary, contains('请 汤 上 身'));
      expect(it.summary, contains('横川是川崽耶'));
      // 自己的动态没有 url 时借原动态的链接
      expect(it.url, 'https://www.bilibili.com/video/BV19PMr6FEfw');
      expect(it.extra?['origin_kind'], FeedKind.video.name);
    });

    test('专栏（MAJOR_TYPE_ARTICLE）', () {
      final FeedItem? it = parseDynamicItem(_item(
        id: '1000000000000000005',
        type: 'DYNAMIC_TYPE_ARTICLE',
        dyn: <String, dynamic>{
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_ARTICLE',
            'article': <String, dynamic>{
              'id': 88888,
              'title': '专栏标题',
              'desc': '专栏摘要',
              'covers': <String>['//i0.hdslb.com/banner.jpg'],
            },
          },
        },
      ));

      expect(it!.kind, FeedKind.article);
      expect(it.title, '专栏标题');
      expect(it.url, 'https://www.bilibili.com/read/cv88888');
    });

    test('直播（MAJOR_TYPE_LIVE_RCMD 的 content 是转义 JSON 字符串）', () {
      final FeedItem? it = parseDynamicItem(_item(
        id: '1000000000000000006',
        type: 'DYNAMIC_TYPE_LIVE_RCMD',
        dyn: <String, dynamic>{
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_LIVE_RCMD',
            'live_rcmd': <String, dynamic>{
              'content':
                  '{"live_play_info":{"room_id":22637261,"title":"今晚八点开播",'
                      '"area_name":"虚拟主播","online":1234}}',
            },
          },
        },
      ));

      expect(it!.kind, FeedKind.live);
      expect(it.title, '今晚八点开播');
      expect(it.url, 'https://live.bilibili.com/22637261');
    });

    test('未知 major 也不崩，且正文不全空', () {
      final FeedItem? it = parseDynamicItem(_item(
        id: '9999999999999999999',
        type: 'DYNAMIC_TYPE_UNKNOWN_NEW',
        dyn: <String, dynamic>{
          'desc': <String, dynamic>{'text': '未来才有的新类型'},
          'major': <String, dynamic>{'type': 'MAJOR_TYPE_BRAND_NEW'},
        },
      ));

      expect(it, isNotNull);
      expect(it!.summary, '未来才有的新类型');
      // url 兜底成动态详情页，不会出现空链接
      expect(it.url, contains('opus/9999999999999999999'));
    });

    test('标题与摘要都为空时给可辨识占位，不留空白条目', () {
      final FeedItem? it = parseDynamicItem(_item(
        id: '1',
        type: 'DYNAMIC_TYPE_DRAW',
        dyn: <String, dynamic>{
          'major': <String, dynamic>{
            'type': 'MAJOR_TYPE_DRAW',
            'draw': <String, dynamic>{
              'items': <Map<String, dynamic>>[
                <String, dynamic>{'src': '//i0.hdslb.com/only-pic.jpg'},
              ],
            },
          },
        },
      ));

      expect(it!.kind, FeedKind.image);
      expect(it.summary.isNotEmpty, isTrue);
      expect(it.cover, 'https://i0.hdslb.com/only-pic.jpg');
    });

    test('缺 id_str 返回 null（不让脏数据进库）', () {
      expect(
        parseDynamicItem(<String, dynamic>{'type': 'DYNAMIC_TYPE_WORD'}),
        isNull,
      );
    });
  });

  group('parseLiveHistoryItem 最近观看的直播', () {
    test('完整字段', () {
      final WatchedLive? w = parseLiveHistoryItem(<String, dynamic>{
        'title': '今晚八点开播',
        'cover': '//i0.hdslb.com/live.jpg',
        'uri': 'https://live.bilibili.com/22637261',
        'history': <String, dynamic>{'oid': 22637261, 'business': 'live'},
        'author_name': '嘉然今天吃什么',
        'author_face': '//i1.hdslb.com/face.jpg',
        'author_mid': 672328094,
        'view_at': 1786000000,
      });

      expect(w, isNotNull);
      expect(w!.uid, '672328094');
      expect(w.name, '嘉然今天吃什么');
      expect(w.roomId, '22637261');
      expect(w.viewedAt?.year, 2026);
      expect(w.face, 'https://i1.hdslb.com/face.jpg');
    });

    test('history.oid 缺失时从 uri 兜底取房间号', () {
      final WatchedLive? w = parseLiveHistoryItem(<String, dynamic>{
        'title': '溜了溜了',
        'uri': 'https://live.bilibili.com/1024',
        'history': <String, dynamic>{'business': 'live'},
        'author_mid': 2,
        'author_name': '碧诗',
      });

      expect(w!.roomId, '1024');
    });

    test('缺 author_mid 返回 null（无 UID 无法与关注列表比对）', () {
      expect(
        parseLiveHistoryItem(<String, dynamic>{'title': '没有主播信息'}),
        isNull,
      );
    });
  });
}
