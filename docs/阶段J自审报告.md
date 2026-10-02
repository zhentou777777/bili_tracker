# 阶段 J 自审报告

> 审计对象：我自己这一轮（阶段 J + J6）的改动。
> 方法：逐文件复核 + **到 pub 缓存里核对插件源码**（不凭记忆、不凭推测下结论）。
> 时间 2026-10-02。
>
> **修复状态（已按范围 B 修完）**：P1-1 ✅（`IndexedStack` 常驻）、P1-2 ✅、P2-1 ✅、P2-3 ✅。
> **未修**：P2-2（抽共用函数，改动面较大）、P2-4 / P2-5 / P2-6。
> ⚠️ 本报告初稿对 P1-1 有一处**说过头**的表述，已在正文里更正并留痕（见 P1-1 第 1 条）。
>
> 改动范围：`lib/ui/today_page.dart`（弹层）、`lib/ui/danmaku_page.dart`（重定向检测 + 进入直播间按钮）、
> `lib/core/danmaku_link.dart`（新增）、`test/danmaku_link_test.dart`（新增）。

---

## 一、结论

**2 个 P1、6 个 P2，没有 P0（不崩）。**

但 P1-1 值得优先处理：它会造成**「点了没反应」** —— 这正是本项目最忌讳的一类缺陷
（阶段 I 修的那个「点通知毫无反应」就是同类）。而且它是我这次**放大**了的一个既有缺陷。

| 级别 | 数量 | 一句话 |
|---|---|---|
| **P1** | 2 | ① 错误态把 WebView 摘出组件树 → `reload()` 成死代码、新加的撤销逻辑不可达；② 弹幕姬入口变得完全不可见 |
| **P2** | 6 | 进度条可能提前消失、深链兜底逻辑重复、空房间号仍弹层、AppBar 图标可发现性、域名硬编码、测试未跑 |

---

## 二、P1

### P1-1 ★ 错误视图会把 WebView 从组件树上摘掉（✅ 已修）

**代码事实**（`lib/ui/danmaku_page.dart:152`）：

```dart
body: _error != null ? _errorView() : InAppWebView(...)
```

一旦 `_error != null`，`InAppWebView` 就**不在组件树里了**。证据链（已逐条核对插件源码）：

| 环节 | 位置 | 结论 |
|---|---|---|
| 1 | 本项目 `danmaku_page.dart:152` | 错误时 WebView 被 `_errorView()` 顶替 |
| 2 | `flutter_inappwebview-6.1.5/lib/src/in_app_webview/in_app_webview.dart:675` | `void dispose() { widget.platform.dispose(); super.dispose(); }` —— **移出树即被 dispose** |
| 3 | `flutter_inappwebview_android-1.1.3/.../in_app_webview_controller.dart:2755` | Android 端 `dispose()` → `disposeChannel(...)` + `_controllerFromPlatform = null` |
| 4 | 同上 `:1858` | `reload()` 的实现是 `await channel?.invokeMethod('reload', args)` —— `channel` 为 null 时**静默无操作** |

**两条后果：**

1. **`reload()` 那行是死代码，但按钮并不是"点了没反应"。**
   ⚠️ **本报告初稿把这条写成「重试按钮点了没反应」，说得过头了，这里更正：**
   按钮的实际流程是 `setState` 先把 `_error` 置 null → 下一帧 `build()` 因 `_error == null`
   走另一分支**重建一个全新的 `InAppWebView`** → 由 `initialUrlRequest` 重新加载。
   所以页面**确实会重新加载**，只是走的是「整只 WebView 重建」这条更重的路径（丢状态、更慢）。
   `reload()` 打在已拆掉的通道上、静默空转这一点成立，但"用户点了完全没反应"不成立。
   → 教训：**审计时把"某一行是死代码"直接当成"用户可见后果"，是推理跳步。**
2. **我这次新写的"撤销判定"逻辑永远触发不了 —— 这条完全成立。**
   我在 `_noteUrl` 里写了「站点若又跳到别处（例如登录页），就撤销之前那个『被甩到首页』的结论」，
   可 WebView 一旦不在树上，**就再也不会有任何 URL 回调** —— 那段逻辑是死的。
   写它的时候没意识到这一点，是本次审计才发现。

> 严格说，第 1 条是**既有缺陷**（原代码就是这个结构），但阶段 J 让 `_error != null` 变成了一条**常见路径**
> （用户实测到的现象就是"被甩到首页"），所以它从一个边缘情况变成了大概率会撞上的情况。第 2 条是本次引入。

**修法（已采用 ①）：**

- **① 让 WebView 始终留在组件树上**（`IndexedStack`，错误视图作为覆盖层）。
  好处：控制器不死 → 「重试」不用退化成整只重建；回调不断 → 那条撤销逻辑也能真的生效。
- ② 退一步：「重试」时重建 WebView（换 `ValueKey`），并**删掉**那段永远不会触发的撤销逻辑。

**✅ 已修（采用 ① `IndexedStack`）**：`body` 改为 `IndexedStack(index: _error != null ? 1 : 0)`，
两个 child 都包 `SizedBox.expand`（`IndexedStack` 内部是 `StackFit.loose`，不包的话 WebView 会量到 0、
`_errorView()` 这个 `Center` 也会贴左上不居中）。

---

### P1-2 弹幕姬入口变得完全不可见（✅ 已修）

改版前，卡片右上角那个图标虽然会误触，但它**至少让这个功能是可见的**。现在弹幕姬收进弹层，
卡片上没有任何视觉线索：用户既不知道有这个功能，也不知道点卡片会发生什么。

这是"修误触"的副作用 —— 误触确实没了，可发现性也一起没了。

**修法**（不改交互结构，只补线索，任选）：
- 弹层标题下加一行说明（例如「进入直播间 / 看弹幕」）；
- 或直播卡上加一个**不参与点击**的提示标签；
- 或设置页加一句说明。

**✅ 已修（两处都补了）**：
- 弹层里标题下加一行 12px 说明「进直播间，或看这个直播间的弹幕」；
- 直播卡右侧加一个**不绑 `onTap`** 的 `Icons.more_horiz`（纯装饰，随整张卡片一起响应）——
  提示"点开还有选项"，但**不制造第二个落点**（那正是这次改版要消除的东西）。

---

## 三、P2

| # | 问题 | 影响 | 修法 |
|---|---|---|---|
| P2-1 ✅ | `_noteUrl` 每次被调用都把 `_loading` 置 false。SPA 的历史变更（`onUpdateVisitedHistory`）可能**早于** `onLoadStop` 触发 | 进度条提前消失，页面其实还没出来 | 只有 `onLoadStop` 负责关进度条；历史回调只做地址判定 |
| P2-2 | `_openLiveRoom`（弹幕姬页）与 `_open`（今日页）是两份几乎相同的逻辑：深链 → 复制兜底 → toast | 以后改一处容易漏另一处 | 抽到 `external_link.dart` 成一个共用函数 |
| P2-3 ✅ | 房间号为空时**仍会弹层**，只是两个按钮禁用 + 一行提示 | 略怪，且多一步无意义交互 | `_showLiveActions` 开头短路 + toast，不弹层；弹层内的 `hasRoom` 三元与提示段一并删除 |
| P2-4 | 弹幕姬页顶部现在 3 个图标按钮；「进入直播间」只有图标、靠 tooltip（移动端要长按才出现） | 可发现性一般；小屏可能挤 | 错误态下补一个带文字的「去直播间」大按钮 |
| P2-5 | `classifyDanmakuUrl` 硬编码域名 `chat.vrp.moe` | 该站换域名 / 加 www 则判定整体失效 —— **只会退化成"照常显示页面"，不会崩** | 影响有限，把这条写进注释当作已知限制 |
| P2-6 | 新增 13 项单测**尚未跑过 `flutter test`**；`_noteUrl`、`_showLiveActions` 属 UI 层无覆盖 | 数字断言与事实可能不符 | 出包时一起跑 `CHECK.bat` 看总数是否为 56 |

---

## 四、已核对**没有问题**的项（避免只挑刺）

| 项 | 核对方式与结论 |
|---|---|
| 静态分析 | ✅ **34 个文件，error 0 / warning 0 / info 0**（`tools/analyzer_runner` 实测） |
| 弹层里的 `CrossAxisAlignment.stretch` | ✅ **安全**。这里交叉轴是**宽度**，有界；与坑清单第 22 条（ListView 里**高度**无界 + stretch）不是同一情况。已就地写明理由 |
| `nav.pop()` 后立即 `nav.push()` | ✅ 先取 `final NavigatorState nav = Navigator.of(sheet)` 再操作，不会用到已失效的 context |
| `TextButton(onPressed: nav.pop)` | ✅ `pop` 的可选参数可安全赋给 `void Function()`（analyzer 已验） |
| 判定规则的 16 条断言 | ✅ **16/16 通过**（临时脚本在纯 Dart 下真跑，跑完已删） |
| 深链逻辑 | ✅ **未改动**，阶段 I 的 18/18 实测不受影响 |
| `onUpdateVisitedHistory` 签名 | ✅ 已核对插件源码为 `(controller, WebUri?, bool?)`，不是凭记忆写的 |

---

## 五、修复执行情况（范围 B）

已修 4 条：**P1-1**（`IndexedStack` 常驻）、**P1-2**（弹层说明行 + 卡上 `more_horiz`）、
**P2-1**（进度条只由 `onLoadStop` 关）、**P2-3**（无房间号不弹层）。

自检：`dart format --output=none` 双文件语法通过；`tools/analyzer_runner`
**34 个文件，error 0 / warning 0 / info 0**。

**仍然未修**：P2-2（抽共用函数）、P2-4、P2-5、P2-6。

**下一步（我做不到，需项目持有人执行）**：
双击 `REBUILD.bat` 出包 → 真机验三条：
① 点直播卡弹层出现、选「进入直播间」真进 B 站 App；
② 选「打开弹幕姬」，若被甩到首页 `/` 应看到「弹幕姬里没有这个直播间」（此时 WebView 仍在树上下方）；
③ 弹幕姬页顶部「进入直播间」按钮可用。
