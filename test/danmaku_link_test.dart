// 弹幕姬地址规则的单元测试。
//
// 为什么单独一个文件：这里测的是纯逻辑（`lib/core/danmaku_link.dart` 没有任何
// Flutter 依赖），与被测页面分开，出问题时能一眼看出是「判定错」还是「界面错」。
//
// 样本来自实测现象：**未登记的房间会被对端甩回站点首页**，于是用户在 App 内
// 看到的是 `chat.vrp.moe` 的首页而不是自己直播间的弹幕机 —— 这正是要判出来的
// 那一种，也是做这套判定的唯一理由。

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_tracker/core/danmaku_link.dart';

void main() {
  group('classifyDanmakuUrl —— 对上 / 对不上 / 不判死', () {
    test('对上：直播间页面', () {
      expect(classifyDanmakuUrl('https://chat.vrp.moe/dashboard/22637261'),
          DanmakuUrlKind.room);
    });

    test('对上：带尾斜杠也算对上了', () {
      expect(classifyDanmakuUrl('https://chat.vrp.moe/dashboard/22637261/'),
          DanmakuUrlKind.room);
    });

    test('对不上：被甩到站点首页（带斜杠）', () {
      expect(classifyDanmakuUrl('https://chat.vrp.moe/'), DanmakuUrlKind.home);
    });

    test('对不上：被甩到站点首页（不带斜杠）', () {
      expect(classifyDanmakuUrl('https://chat.vrp.moe'), DanmakuUrlKind.home);
    });

    test('对不上：只有前缀、没有房间号的空壳页', () {
      expect(classifyDanmakuUrl('https://chat.vrp.moe/dashboard/'),
          DanmakuUrlKind.other);
    });

    test('不判死：站内其它路径（例如登录页）', () {
      // 判定过宽会把正常登录流程挡在外面，所以除首页外一律按正常页面显示
      expect(classifyDanmakuUrl('https://chat.vrp.moe/login'),
          DanmakuUrlKind.other);
    });

    test('不判死：外链一律当正常页面', () {
      expect(classifyDanmakuUrl('https://passport.bilibili.com/login'),
          DanmakuUrlKind.other);
    });

    test('不判死：别的域名即便路径长得像也不算对上', () {
      expect(classifyDanmakuUrl('https://example.com/dashboard/1'),
          DanmakuUrlKind.other);
    });

    test('不判死：空值 / 中间态 / 非地址', () {
      expect(classifyDanmakuUrl(null), DanmakuUrlKind.other);
      expect(classifyDanmakuUrl(''), DanmakuUrlKind.other);
      expect(classifyDanmakuUrl('about:blank'), DanmakuUrlKind.other);
      expect(classifyDanmakuUrl('这不是一个地址'), DanmakuUrlKind.other);
    });

    test('域名大小写不敏感', () {
      expect(classifyDanmakuUrl('https://CHAT.VRP.MOE/dashboard/1'),
          DanmakuUrlKind.room);
    });
  });

  group('danmakuUrlDisplay —— 把「跳到了哪里」说清楚', () {
    test('首页只显示域名', () {
      expect(danmakuUrlDisplay('https://chat.vrp.moe/'), 'chat.vrp.moe');
    });

    test('其余显示域名 + 路径（丢掉查询串）', () {
      expect(danmakuUrlDisplay('https://chat.vrp.moe/login?x=1'),
          'chat.vrp.moe/login');
    });

    test('解析不出来时原样返回', () {
      expect(danmakuUrlDisplay('这不是一个地址'), '这不是一个地址');
    });
  });
}
