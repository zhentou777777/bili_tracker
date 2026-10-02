# 追更台 · 多 UP 主综合追更工具

Flutter 实现，**客户端 Cookie 直连**架构：所有平台请求都在 App 内发起，服务端只下发规则 JSON 和转发推送，不接触 Cookie、不代理平台接口。

第一阶段 MVP 已跑通 B 站闭环：**登录 → 自动追更（最近观看直播 ∩ 已关注）→ 动态日历 → 本地通知**。

---

## 1. 环境要求

| 项目 | 版本 | 说明 |
|---|---|---|
| Flutter | **≥ 3.32**（本项目实测用 3.32.8） | 必须。`workmanager ^0.9.0` 强制要求 3.32，**低于此版本 `pub get` 会直接失败**（原文档写的「≥ 3.10」经实测不成立） |
| Dart | ≥ 3.5（随 Flutter 3.32 带来 3.8.1） | 随 Flutter 一起 |
| Android SDK | compileSdk 35 / minSdk **23** | minSdk 23 是 Keystore 强安全存储与 workmanager 的下限 |
| JDK | 17 | Gradle 要求（JDK 25 不可用） |
| NDK | **27.0.12077973** | 8 个插件的共同要求（见 `android/app/build.gradle.kts`） |

> 接手后的实际状态：项目**已在本机编译出可安装的 APK**，`flutter analyze` **0 问题**（已用
> `tools/analyzer_runner` 复核：30 个文件、error/warning/info 全 0）。
> **单元测试**共 43 个用例；最近一次自检（15:58）有 2 个失败，**已修复但尚未复跑确认**
> （详见 `审计报告.md` 与 `交接文档.md` 阶段 H）。
> 排障全过程、提交的逐项说明、坑清单与回退方法，见 **`交接文档.md`（权威版）**。

## 2. 快速开始

```bash
cd bili_tracker
flutter pub get
flutter run                       # 连真机或模拟器
```

构建安装包（**推荐直接双击 `REBUILD.bat`**，它会先清缓存再编译）：

```bash
flutter build apk --release       # Android
flutter build ipa                 # iOS（需先配好证书）
```

> ⚠️ 注意：Flutter 的增量编译**可能漏判 Dart 源码变更**，出现「只编译几秒就显示 Built …apk」的
> 假成功（包里还是旧代码）。判断是否真的出新包：**看 APK 文件的修改时间**。

首次运行请先登录 B 站账号：**扫码登录 + 一键跳转 B 站 App 确认**（推荐），
或用登录页右上角的「网页登录」备用入口。登录后回「今日」页点右上角刷新。

> 登录链路说明：申请二维码 → 每 2 秒轮询状态 → 确认后取 Cookie。
> 二维码链接本身就是 B 站的授权页（`account.bilibili.com/h5/account-h5/auth/scan-web`），
> 手机上装了 B 站 App 时用系统打开它会被 App Links 接管、**直接进 App 的确认页**，
> 所以同一台设备也能完成登录，不必找第二台手机来扫。
> 详见 `登录方式改造说明.md`。

**首次构建前注意**：

```bash
flutter create --platforms=android .   # 生成 android/local.properties 等缺失的模板文件
```

`android/` 目录已手写好 `build.gradle`、`AndroidManifest.xml`、`MainActivity.kt`、`styles.xml` 和一套占位图标（粉色圆环，建议替换）。`flutter create` 会补上 `local.properties`（含 `flutter.sdk` 路径），这一步不能跳。

> ⚠️ **本项目已补过模板，请不要再跑 `flutter create`**：它会额外生成一套 Kotlin DSL（`.kts`）配置，
> 与手写 Groovy 配置冲突，并且会把 `minSdk` 从 23 悄悄退回 21（导致清单合并失败）。
> 相关现场已整理到 `android/_legacy_groovy_bak/`（保留，未删除），细节见 `交接文档.md` 第三节 A5/B5。

## 3. 目录结构

```
lib/
├── core/
│   ├── md5.dart         纯 Dart MD5（WBI 签名依赖，零依赖以便探针验证）
│   ├── wbi.dart         B 站 WBI 签名 + mixin_key 缓存
│   ├── rules.dart       规则表解析（端点/参数/解析路径/登录规则全外置）
│   ├── http.dart        HTTP 抽象 + ApiException（风控码识别）
│   │                    含 setCookies 多行原始值与 followRedirects 开关（登录回调需要）
│   └── dio_sender.dart  Dio 实现 + Cookie Jar 自动维护设备指纹
├── platform/
│   ├── models.dart      跨平台领域模型（含 WatchedLive、登录相关模型）
│   └── bilibili.dart    B 站适配器（关注/动态/投稿/直播/用户信息/观看历史/扫码登录）
├── data/db.dart         SQLite 数据层（手写 SQL，无代码生成）
├── service/
│   ├── auth_service.dart   Cookie 安全存储（Keystore/Keychain）与失效检测
│   ├── sync_service.dart   抓取调度：频率策略、抖动、风控退避、通知分级、自动追更
│   ├── notify_service.dart 本地通知（开播/动态/汇总三档）
│   ├── bg_service.dart     WorkManager 后台任务
│   ├── rules_service.dart  规则加载（缓存与内置取版本更高者）+ 远端覆盖
│   └── app_context.dart    依赖装配
└── ui/                  界面（浅色/深色双主题）
    ├── theme.dart        配色（AppColors 主题扩展）+ ThemeData + 主题模式控制器
    ├── widgets.dart      共用组件（AppCard/SectionTitle/TagChip/InfoBar/EmptyState/AvatarBubble）
    └── login_page.dart   扫码登录 + 同设备跳转 B 站 App 确认
                          （内含 WebLoginPage：原 WebView 登录，保留为备用路径）

assets/rules/platforms.json   平台接口规则表（含 login 段）
tools/probe.dart              CLI 探针（真实接口验证，40 项）
tools/analyzer_runner/        独立小包：绕开沙箱限制跑静态分析（用法见第 5 节）
test/widget_test.dart         主题与共用组件测试（13 项）
test/dynamic_parser_test.dart 动态/观看历史解析单元测试（离线样本，12 项）
test/login_parser_test.dart   扫码登录状态码映射 + Set-Cookie 解析（离线样本，18 项）
server/worker.js              Cloudflare Worker 推送中继（第二阶段）
docs/archive/                 已归档的历史文档（仅作过程证据，见其 README.md）
```

**根目录的文档**：`交接文档.md`（权威版，先读这个）、各阶段说明
（`动态修复与自动追更策略说明.md` / `登录方式改造说明.md` / `界面改版说明.md`）、
`审计报告.md`、`编译说明.txt`（面向非技术用户）。

## 4. 与需求文档的重要差异

这几点是实测后必须调整的，不是我自作主张：

**① WBI 签名是硬性要求，原文档没提。** 2023 年后 B 站主流接口强制 `w_rid` + `wts` 签名（Mixin Key 算法）。不实现它，`x/space/arc/search` 一类接口直接拿不到数据。已在 `lib/core/wbi.dart` 实现，密钥从 `nav` 接口获取并缓存 6 小时。

**② 直播状态接口是公开的，不需要 Cookie。** 实测 `get_status_info_by_uids` 无 Cookie 直接返回 `code:0`。这意味着开播检测最稳的一环完全不依赖登录态，后台轮询甚至服务端兜底都能用。

**③ 只带 SESSDATA 不够，会被判 -352 风控。** 必须连 `buvid3`/`b_nut` 等设备指纹一起带。登录时会一并保存（`auth_service.dart` 的 `kExtendedCookieWhitelist`），另外 `DioHttpSender.ensureDeviceCookies()` 会先向首页要一次、拿不到再走 `/x/frontend/finger/spi` 兜底。

**④ 空间动态接口已换地址，旧地址整条下线。** 旧 `api.vc.bilibili.com/dynamic_svr/.../space_history` 实测返回 **HTTP 404**（HTML 错误页），参数怎么调都没用；现用 `api.bilibili.com/x/polymer/web-dynamic/v1/feed/space`，数据结构完全不同（`modules.module_author` / `major.type` / 顶层 `orig`），因此解析器是重写的。该接口**必须有 buvid3**，否则回 HTTP 412。

**⑤ 「最近观看的直播」不能用关注列表代替。** 关注列表接口拿不到「看过谁」的信号。正确来源是观看历史 `x/web-interface/history/cursor?type=live`（需登录），每条的 `author_mid` 就是主播 UID —— 这是「自动追更最近观看直播的已关注主播」的数据源。

**⑥ 登录不用 WebView，改用「扫码 + 同设备跳转」。** 内嵌 WebView 加载 B 站登录页容易白屏、控件点不动。
改用两个纯 JSON 接口（`qrcode/generate` + `qrcode/poll`）走扫码链路；而二维码链接本身就是 B 站的授权页，
手机用系统打开它会被 App Links 接走、**直接进 B 站 App 的确认页**，所以同一台设备也能完成登录。
注意 `/qrcode/poll` 有**两层 `code`**：外层恒为 0，真实扫码状态在 `data.code`（86101/86090/86038/0），
只看外层会在第一次轮询就误判成功。B 站**官方**的跳转 App 授权 OAuth 不可用（需企业资质，且换不到 SESSDATA）。
详见 `登录方式改造说明.md`。

**⑦ 颜色一律走主题扩展，不写静态色值。** 界面支持**浅色 / 深色 / 跟随系统**三态（设置 → 外观）。
取色统一用 `context.c.xxx`，绝不能再用 `static const Color` —— 静态常量编译期定死，运行时换不了主题。
两个坑要知道：① 主题色不是常量，所以**不能写在 `const` 表达式里**；
② `context` 是 `State` 的实例属性，**`static` 方法里拿不到**（辅助方法别加 `static`）。
浅色主题的主色刻意不用官网那支 `#FB7299`（白底对比度仅约 2.2:1），改用更深的 `#E23F6E`。
详见 `界面改版说明.md`。

## 5. 核心逻辑验证结果

`tools/probe.dart` 不依赖 Flutter，直接打真实接口：

```bash
dart tools/probe.dart
# 带 Cookie 可验证完整闭环：
BILI_COOKIE='SESSDATA=xxx; bili_jct=xxx; DedeUserID=xxx' dart tools/probe.dart
```

当前实测输出（40 项全通过）：

```
[1] MD5 实现自检                 5/5 通过（RFC 1321 向量 + 中文）
[2] 表单编码对齐 Python quote_plus  4/4 通过
[3] 规则文件加载                 version=5，7 个端点 + 登录端点与状态码映射断言
[4] WBI 密钥获取                 mixin_key=ea1db124af3c7062474693fa704f4ff8
[5] WBI 签名串                   ✅ 跨语言一致性：Dart 与 Python 算出同一个 w_rid
[6] 直播状态接口（公开）          解析出 2 条，uid=672328094 嘉然今天吃什么 room=22637261
[7] Cookie 失效检测              正确识别 -101 未登录；动态端点存活探测（404 直接判失败）
[8] 新版动态解析（离线样本）      9 项：视频/图文/纯文字/转发/专栏/直播/通用卡片 + 转发折入原动态 + 缺 id 防脏数据
[9] 最近观看直播解析（离线样本）  3 项：完整字段 / uri 兜底取房间号 / 缺 author_mid 丢弃
[10] 扫码登录链路（真实网络）     申请二维码 + 授权页地址 + fresh key 轮询必须回「未扫码」
[11] Set-Cookie 解析（离线样本）  多行不拼接；Max-Age=0 / Expires 1970 / 空值 一律视为删除指令
```

第 5 项是关键：探针会调 Python 独立实现一遍签名再比对 `w_rid`，确认不是自说自话、也不会因为 URL 编码大小写差异踩坑。

第 8、9、11 项的样本字段全部取自真实接口响应（2026-10 实测），做成离线样本是为了不依赖登录态、不受风控抖动影响，可以每次都跑。

第 10 项虽然打真实网络，但**不产生任何副作用**（不登录、不写数据），所以可以随时跑；它盯住两件事：
授权页地址没被 B 站改掉（改了「同设备跳转 App」就会失效）、以及**未扫码时绝不能误判成登录成功**。

### 静态分析自检（analyze 归零）

本项目要求 `flutter analyze` 保持 **0 个问题**（含 info）。但 `CHECK.bat` 要双击、还要等编译，
迭代时太慢；而某些受限环境里 `dart analyze` 会因为要建命名管道而直接失败
（`CreateFile failed 231`）。因此仓库内附带一个独立的小工具：

```bash
cd tools/analyzer_runner
dart pub get
dart run bin/analyze.dart "D:/fan club/bili_tracker"
# 已分析 29 个文件
# error 0  warning 0  info 0  →  合计 0
```

退出码：0 = 干净，1 = 有问题，可直接串进脚本。

它直接调用 analyzer 库（版本锁定 7.3.0，与当前 Flutter SDK 内置的一致，保证结果和
`flutter analyze` 对齐），并读取项目自己的 `analysis_options.yaml`，所以 lint 规则完全相同。

> ⚠️ `tools/analyzer_runner` 是**独立小包**，不在 App 的依赖图里；根
> `analysis_options.yaml` 里已用 `analyzer.exclude` 排除它。
> **不要把这个 exclude 删掉** —— 全新 clone 上那个目录还没有 `.dart_tool`，
> 分析器会用根包的 `package_config` 去解析它，`package:analyzer/...` 全部找不到，
> 反而让 `flutter analyze` 从 0 变成一堆错误。

### 出包后怎么确认「包里真的是新代码」

只看 APK 的修改时间不够（本项目遇到过增量编译漏判源码变更、只花 2.9 秒重打包的假成功；
反过来时间新也只证明文件被写过）。可靠做法是拆包搜字符串：

```python
import zipfile
data = zipfile.ZipFile('build/app/outputs/flutter-apk/app-release.apk') \
    .read('lib/arm64-v8a/libapp.so')
# 本项目 AOT 里的中文是 UTF-16LE
assert '在 B 站 App 中确认'.encode('utf-16-le') in data
```

同时要搜一个**新旧版本都有**的对照串（例如「今日速览」）来确认编码没找错，
并搜一个**只在旧版存在**的文案来确认它已消失。

## 6. 规则文件

`assets/rules/platforms.json` 定义了所有端点地址、参数模板、解析路径。B 站改接口时改这个文件即可，**不用发版**：

- App 启动时先读缓存、再读内置，**两者取版本号更高的那个**（否则旧缓存会一直压住内置新规则，
  接口修好了也生效不了）→ 后台再拉远端
- 在「设置 → 抓取规则」填入远端 JSON 地址（GitHub Raw / R2 / 对象存储都行）后自动生效
- `{uid}` `{page}` `{offset}` `{self_uid}` 是占位符，运行时替换

## 7. 服务端（第二阶段）

当前 App 完全不依赖服务端。要启用远程推送：

```bash
cd server
npm i -g wrangler
wrangler kv:namespace create RULES_KV     # 依次建三个 KV，填进 wrangler.toml
wrangler secret put FCM_SERVICE_ACCOUNT   # Firebase service account JSON
wrangler secret put FCM_PROJECT_ID
wrangler secret put APNS_AUTH_KEY         # APNs .p8 内容
wrangler secret put PUSH_SECRET
wrangler deploy
```

Worker 提供三个能力：`GET /rules` 下发规则、`POST /push` 转发 FCM/APNs、`scheduled` 每 10 分钟轮询公开直播接口做开播兜底。

**推送中继只转发摘要**（UP 主名、内容类型、时间、平台），字段白名单过滤，不落库、不记内容日志。开播兜底只碰公开接口，不需要也不接触任何 Cookie。

## 8. 已知限制

- **后台轮询不可靠**：Android 各厂商省电策略会拖延甚至跳过 WorkManager 任务。真要保开播提醒，得上服务端的公开接口兜底（Worker 已写好）。
- **风控概率**：数据中心 IP 或高频请求会触发 -352 / HTTP 412。已做抖动间隔与自动降速，但遇到验证码只能重新登录。
- **iOS 未实测**：代码按双端写，但第一阶段只在 Android 上规划验证。iOS 通知需要付费开发者账号。
- **安装包未签名**：没有签名密钥和 iOS 证书，需你本地构建。
- **自动追更依赖登录态与观看历史**：观看历史接口必须登录；接口被限流或 Cookie 失效时，
  该轮自动追更只跳过、不影响正常抓取（详情见 `动态修复与自动追更策略说明.md`）。
- **平台接口会整条下线**：本次已遇到一次（动态接口 404）。规则文件外置就是为了少发版，
  但**改完必须把 `version` 加 1**，否则旧缓存会压住新规则、修复静默失效。
- **「同设备跳转 B 站 App」依赖两件外部条件**：手机上装了 B 站 App，且 B 站没改掉授权页地址。
  前者缺失时登录页会自动降级为「复制链接到剪贴板」；后者已被探针第 [10] 项盯住（地址一变就报警）。
  真机是否真的被 App Links 接管**尚未验证**，需要你在装了 B 站 App 的手机上试一次。
- **扫码确认后的 Cookie 获取有两条路**（轮询响应自身 / 跨域回调补齐），跨域回调**必须带 Referer
  且禁止自动跟随 302**，否则会拿到空 Cookie 而请求看起来完全正常。两条路都已在代码里实现。
- **登录链路没有端到端自动化测试**：真实扫码必须由人完成。已自动化的是
  「申请二维码 → 状态码判定 → Set-Cookie 解析」这三段（探针 + 单元测试）。

## 9. 免责声明

本工具使用用户本人的 Cookie 访问平台接口，等同于自己打开网页查看关注内容。Cookie 仅存于本机 Keystore / Keychain，不上传任何服务器。使用即表示了解并自行承担违反平台服务条款的潜在风险。遇到验证码或风控提示，请重新登录或降低抓取频率。
