# 追更台 bili_tracker —— 交接文档 V3（编译打通与修 bug 记录）

> ⚠️ **本文档为历史过程记录，已被 `交接文档.md`（权威版）整合并取代。**
> 建议先读 `交接文档.md`；本文保留作为当时的排查证据（阶段 B 的详细过程，
> 含「编译是排队过关」的经典踩坑记录）。

> 本文档是 `HANDOVER_V2.md` 的续篇，记录 **2026-10-02 第二轮** 接手后做的事。
> 覆盖范围：把项目真正编译出 APK 的完整过程、途中暴露的 5 个新 bug、
> 代码告警清零、以及对 V2 两处结论的纠正。
>
> 面向读者：项目作者、后续接手的开发者，以及**不写代码的项目所有者**。
> 仓库：https://github.com/zhentou777777/bili_tracker （私有，main 分支）

---

## 〇、一页速览（TL;DR）

**最重要的一句：APK 已经真正编译出来了。**

| 项 | V2 时的状态 | 现在的状态 |
|---|---|---|
| 能编译出 APK 吗 | ⏳ 待办（从未编译过） | ✅ **已产出** `app-release.apk`（50.6 MB） |
| 代码错误 | ✅ 说全部修完 | ⚠️ 其实还有 5 处，本轮已全部修复 |
| `flutter analyze` | 49 项告警 | ✅ **0 项**（No issues found!） |
| `flutter test` | ❌ 编译失败，从没跑过 | ✅ 通过（2/2） |
| `tools/probe.dart` 算法探针 | ✅ 22/22 | ✅ 22/22（本轮复跑确认） |
| 构建日志 | 刷几百行假报错 | ✅ 干净，0 行 |

**当前唯一还没做的事**：把 APK 装到你手机上，用你自己的 B 站账号真机跑一遍。
这一步只能你本人做，原因见第七节。

---

## 一、为什么 V2 说「代码全修好了」，实际还有 5 个 bug

V2 的判断没做错，只是**当时没有条件验证**。

编译是一个「排队过关」的过程：Gradle 一层层往下走，**前面一关没过，后面的关卡根本不会被执行**。
V2 那一轮卡在 workmanager 依赖问题上（第 2.4 节），编译在 Dart 代码编译阶段就挂了，
于是排在后面的关卡——资源打包、清单合并、Kotlin 编译——**一次都没被跑到**，
藏在里面的错误自然也就没暴露。

这一轮把 workmanager 那关过了之后，后面的关卡逐个开始报错，于是揪出 5 个新 bug。
形象点说：V2 是把路上的第一块石头搬走了，我这一轮走下去，才发现后面还有 4 块。

---

## 二、本轮新发现并修复的 bug（7 个提交，按顺序）

> 全部已推送到 GitHub，每个提交只改一件事，方便你一个个回退。
> 想回退到某个提交之前的版本：`git revert <提交号>`。

### 2.1 `8183409` — 日历页写错 `const`，硬编译错误

| 项 | 内容 |
|---|---|
| 文件 | `lib/ui/calendar_page.dart`（星期行 `_weekdayRow`） |
| 现象 | `flutter analyze` 直接报 error：`Constant expressions don't support 'for' elements` |
| 原因 | 整个控件被声明成 `const`（表示「编译期就定死的常量」），但它内部用了一个 `for` 循环来生成「一二三四五六日」七个格子。Dart 规定：**常量里不允许写循环**，因为循环是运行时才算的 |
| 修法 | 只去掉最外层的 `const`，内部不依赖循环变量的部分保留 `const`。**界面表现和改之前一模一样**，纯粹是让编译器能通过 |
| 性质 | 硬编译错误，不修必然打不出包 |

### 2.2 `02d0c42` — 锁文件没跟着改，V2 的修复其实只做了一半

| 项 | 内容 |
|---|---|
| 文件 | `pubspec.lock` |
| 现象 | `pubspec.yaml` 里已经写了 `dependency_overrides`（V2 第 2.4 节的修复），但入库的 `pubspec.lock` 里锁的**还是那组编译不过的版本** |
| 原因 | `dependency_overrides` 只是「声明」，真正的版本号记在 `pubspec.lock`（锁文件）里。V2 改了声明但没重新解析，锁文件还是旧的 |
| 具体差异 | `workmanager_platform_interface` 从 `0.9.4`（坏）→ `0.9.3`（好）；`workmanager_android` 从 `0.9.3` → `0.9.2` |
| 修法 | 跑一次 `flutter pub get` 重新解析，锁文件与声明对齐 |
| 补充 | 这个不一致其实不影响编译（Gradle 会自动重解析），但留着会让下一个人困惑「到底哪个才是真的」，所以必须一起提交 |

### 2.3 `a366c35` — 测试文件的「幽灵类」

| 项 | 内容 |
|---|---|
| 文件 | `test/widget_test.dart` |
| 现象 | `flutter test` 报错：`Couldn't find constructor 'MyApp'` |
| 原因 | 这个文件是 `flutter create` 生成项目时附赠的**示例测试**（一个「点加号计数器加一」的模板），里面用的是模板自带的 `MyApp` 类。而本项目根本没有 `MyApp`，真正的入口叫 `TrackerApp` |
| 影响 | 只影响 `flutter test`，**不影响打 APK**，所以一直没被发现 |
| 修法 | 改写成两个真正测本项目的测试：① 主题配色正确；② 未登录占位卡片能正常渲染 |
| 为什么不测整个 App | 各页面启动时会去读 `main.dart` 里的全局变量 `appContext`（数据库、登录状态），这个变量只有在真机启动流程里才会被赋值，测试环境读它会直接崩。原因已写进文件头注释 |

### 2.4 `3c8d452` — 缺少「语法糖」支持，通知插件拦路

| 项 | 内容 |
|---|---|
| 文件 | `android/app/build.gradle.kts` |
| 现象 | 编译失败：`Dependency ':flutter_local_notifications' requires core library desugaring to be enabled for :app` |
| 原因 | 通知插件用到了一些**新版 Android 才有的系统功能**（比如时间处理）。为了让老手机也能用，需要开启一个叫「脱糖（desugaring）」的翻译机制，把新写法翻译成老手机能懂的写法。项目没开这个开关 |
| 修法 | 两处，缺一不可：① 打开 `isCoreLibraryDesugaringEnabled = true`；② 补上翻译工具依赖 `desugar_jdk_libs:2.1.4` |

### 2.5 `e91f5c9` — `minSdk` 被模板悄悄改小，并**纠正 V2 的一个错误结论**

| 项 | 内容 |
|---|---|
| 文件 | `android/app/build.gradle.kts` |
| 现象 | 编译失败：`uses-sdk:minSdkVersion 21 cannot be smaller than version 23 declared in library [:workmanager_android]` |
| 原因 | 原作者手写的配置里写死了 `minSdk = 23`（意思是「最低支持安卓 6.0」）。V2 为了补 Gradle 模板，改用 `flutter create` 生成的 `.kts` 版本，而模板里写的是 `minSdk = flutter.minSdkVersion`，Flutter 3.32 的默认值是 **21**。于是最低版本从 23 悄悄退回 21，**低于 workmanager 自己要求的 23**，清单合并直接失败 |
| 修法 | 改回写死 `minSdk = 23` |
| ⚠️ 重要 | V2 第 3.3 节写「已比对两套配置等价（仓库/构建目录/clean task 一致），**无设置丢失**」——**这个结论不成立**。至少 `minSdk` 一项就丢了。见第三节 |

### 2.6 `7e3f101` — 构建日志里几百行「假报错」

| 项 | 内容 |
|---|---|
| 文件 | `android/gradle.properties` |
| 现象 | 编译**能成功**，但会刷出几百行 Java 异常堆栈，看起来像失败 |
| 原因 | 你的 pub 缓存（第三方包存放处）在 **C 盘**，项目在 **D 盘**。Kotlin 的「增量编译」缓存需要把文件路径换算成相对路径，**跨盘符换算不了**（C 盘和 D 盘没有共同根目录），于是每个插件模块编译完都抛一次异常 |
| 影响 | 不致命——Kotlin 会自动退回「全量编译」，APK 照样产出。但日志噪音极大，非技术用户会误判为失败 |
| 修法 | 关掉增量编译（`kotlin.incremental=false`）。因为**本来每次都会退回全量编译**，所以关掉之后实际速度没有任何损失 |
| 实测 | 强制重编译验证：`--rerun-tasks` 跑了 18 个任务，`BUILD SUCCESSFUL`，异常行数 **0**（修复前是数百行） |

### 2.7 `4e22fb7` — 静态分析告警清零（49 → 0）

顺手把剩余告警全部处理完，其中 **3 处是真 bug**：

**（a）真 bug：在「等待」之后使用了已经作废的页面引用**

`settings_page.dart` 和 `ups_page.dart` 里有 3 处这样的写法：

```dart
await _load();                              // 等待加载完成
ScaffoldMessenger.of(context).showSnackBar(...)   // 用页面引用弹提示
```

问题在于：用户如果在 `_load()` 等待期间**切走了这个页面**，`context`（页面引用）就已经作废了，
再拿它弹提示会直接崩溃（报 `Looking up a deactivated widget's ancestor`）。
前面虽然有一句 `if (!mounted) return;`，但那是在**更早的**等待之前判断的，保护不到这里。

修法不是再补一句判断（补了 lint 仍会误报），而是把「判断 + 使用」收进一个**内部没有等待**的
`_toast(String)` 方法。判断和使用之间不存在等待，从结构上就不可能出错。5 处弹窗调用收敛为 2 个方法。

**（b）真 bug：死代码**

| 文件 | 问题 | 处理 |
|---|---|---|
| `lib/service/auth_service.dart` | `AuthState` 里的 `_storage` 字段从未被使用，还因此白建了第二个安全存储实例 | 删除字段与构造参数（该类全项目只在一处构造，改动安全） |
| `lib/service/sync_service.dart` | `import '../data/db.dart'` 没被用到（真正用到的东西来自 `platform/models.dart`） | 删除该 import |
| `lib/service/bg_service.dart` | `Workmanager().initialize` 的 `isInDebugMode` 参数在 workmanager 0.9.x 已弃用，官方标注「no effect（无任何作用）」 | 删除该参数 |

**（c）风格问题**：若干处 `const` 用法、`if` 缺花括号等，全部按官方建议修正。

`tools/probe.dart` 是命令行探针（不是打进 App 的代码），`print` 是它唯一的输出方式，
相对路径 import 是为了能脱离项目独立运行——这两类告警在该文件里**用注释豁免并写明原因**，
而不是为了消警告去改坏它。

---

## 三、对 `HANDOVER_V2.md` 的纠正

| # | V2 的说法 | 实际情况 |
|---|---|---|
| 1 | 第 3.3 节：「已比对两套配置等价，**无设置丢失**」 | ❌ 不成立。`minSdk` 从 23 退回了 21，直接导致清单合并失败（见 2.5） |
| 2 | 第 2 节标题「代码错误全部已修复（4 类，共 12 处改动）」 | ⚠️ 表述偏乐观。当时**没有条件**验证，后面还藏着 3 个硬错误（2.1 / 2.4 / 2.5）。建议改成「已修复当时可排查到的错误」 |
| 3 | 第 8 节：「唯一待办：在本机双击 BUILD_APK.bat」 | ✅ 这条是对的，但实际双击后还会连撞 3 个编译错误。现已全部修好，**再双击就能直接出包** |

V2 里其余内容（环境搭建、镜像策略、workmanager 上游缺陷分析、算法层验证结论）
经本轮复核**全部成立**，不需要改动。

---

## 四、本轮验证结果（全部实测，非推断）

| 验证项 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | ✅ `No issues found!`（exit 0），从 49 项降到 0 |
| 单元测试 | `flutter test` | ✅ `All tests passed!`（2/2） |
| 算法探针（真实网络） | `dart tools\probe.dart` | ✅ **通过 22  失败 0** |
| 正式编译 | `flutter build apk --release` | ✅ exit 0，产出 `app-release.apk` 50.6 MB |
| 构建日志干净度 | 检查 `incremental caches` / `BUILD FAILED` 行数 | ✅ 0 行 |
| APK 完整性 | 解包检查 | ✅ 484 个条目，含 `classes.dex`、`classes2.dex`、`libflutter.so`、`libapp.so` |
| APK 签名 | `apksigner verify` | ✅ v1 + v2 方案均通过 |
| APK 清单 | `aapt2 dump badging` | ✅ 包名 `com.example.bili_tracker`、应用名「追更台」、minSdk 23、targetSdk 35 |

**权限清单**（APK 实际申请的）：`INTERNET`、`ACCESS_NETWORK_STATE`、`POST_NOTIFICATIONS`、
`RECEIVE_BOOT_COMPLETED`、`WAKE_LOCK`、`FOREGROUND_SERVICE`、`VIBRATE`。
没有申请定位、通讯录、相机、存储等敏感权限。

---

## 五、APK 在哪、怎么装

**位置**：

```
D:\fan club\bili_tracker\build\app\outputs\flutter-apk\app-release.apk
```

**安装步骤**：

1. 把这个 `.apk` 文件传到手机（数据线拷贝 / 微信传给自己 / 网盘都行）
2. 在手机上点开它
3. 系统会提示「未知来源应用」——去设置里允许「安装未知应用」，然后继续
4. 安装完成，桌面会出现「追更台」

**关于这个包的三个提醒**：

- 它是 **universal 包**（一个包同时装 4 种 CPU 架构：arm64-v8a / armeabi-v7a / x86 / x86_64），
  所以有 50.6 MB。如果嫌大，可以改用 `flutter build apk --release --split-per-abi`，
  会产出 3 个分开的包，arm64 版（现在绝大多数手机）大约 20 MB 出头。
- 它用的是 **Android 调试证书**签名（原作者就是这么配的，见 `android/app/build.gradle.kts`
  的 `signingConfig = signingConfigs.getByName("debug")`）。
  **自己装着玩完全没问题**，但不能上架应用商店。要上架得另外申请正式签名证书。
- 包名还是 `com.example.bili_tracker`（`example` 是模板占位包名）。不影响使用，
  但正式发布前建议改掉（V1 交接文档第 6 节 P1 第 4 条就是这个）。

---

## 六、完整提交历史（14 个提交）

**V2 之前（7 个）**：

```
824bd93  chore: 原始交接代码快照 (v0.1.0)          ← 原始代码，一字未动
549823e  fix: 修复首次编译错误，新增一键编译脚本与说明
9bbcad8  fix: 修复构建卡点 —— Gradle 下载中断，改用国内镜像
84cf44d  fix: 扫清构建链路全部障碍（沙箱实测验证）
41212e5  fix: ndkVersion 显式指定 27.0.12077973
3cc402c  fix: workmanager 0.9.x 上游缺陷绕过 + bg_service 类型错误修复
c04441b  docs: 新增交接文档 V2
```

**本轮（7 个，全部对应第二节的某一条）**：

```
8183409  fix(calendar_page): 修复 const 常量列表内使用 for 元素导致的编译错误   → 2.1
02d0c42  fix(pubspec.lock): 锁文件同步 dependency_overrides                     → 2.2
a366c35  fix(test): 修复 widget_test 引用不存在的 MyApp                        → 2.3
3c8d452  fix(android): 启用 core library desugaring                             → 2.4
e91f5c9  fix(android): minSdk 显式写回 23                                       → 2.5
7e3f101  build(android): 关闭 Kotlin 增量编译，消除假报错                        → 2.6
4e22fb7  chore: 清理全部静态分析告警，flutter analyze 归零                      → 2.7
```

回退方法（举例：撤销 2.5 那一处）：

```bat
git revert e91f5c9
```

---

## 七、还没做的事（需要你本人，我做不了）

| # | 事项 | 为什么我做不了 |
|---|---|---|
| 1 | **真机跑通闭环**：登录 → 今日页刷新 → 日历有数据 → 收到开播通知 | 需要有你的手机 |
| 2 | **用真实 Cookie 跑一次探针**，验证「关注列表 / 动态」的真实解析 | 需要你的 B 站账号 Cookie。命令见 `HANDOVER.md` 第三节，但**请注意：Cookie 等于你的登录凭证，不要发给任何人（包括我）** |
| 3 | 替换占位图标（现在是纯色圆环） | 需要你提供图标素材 |
| 4 | 改掉 `com.example.bili_tracker` 包名 | 改包名会让已装的 App 变成另一个 App，建议在正式发布前一次性决定 |
| 5 | 部署 Cloudflare Worker（第二阶段，远程推送兜底） | 需要你的 Cloudflare 账号 |

**建议的下一步**：先装 APK，打开 App，看看：
- 能不能正常启动、不闪退
- 点「登录 B 站账号」，网页能不能打开
- 登录后能不能抓到关注列表

把结果告诉我（截图最好），我接着处理。

---

## 八、建议清理项（**我没有删任何东西**，等你确认）

以下是历史遗留的备份/缓存。**我一件都没动**，因为删文件是不可逆的。逐项说明：

| 路径 | 是什么 | 现在还需要吗 | 我的建议 |
|---|---|---|---|
| `android_backup\` | V2 首次编译前自动备份的 android 配置 | 不需要了（`.kts` 配置已稳定出包） | 可删，但**留着也不占多少空间**，想稳妥就再放一阵 |
| `android\_legacy_groovy_bak\` | 原作者手写的 Groovy 版构建配置 | **仍有用**：本轮 2.5 正是靠对比它才发现 `minSdk` 丢失 | **强烈建议保留**，它是还原作者原意的唯一依据 |
| `D:\dev\_wm010`、`_wmif010`、`_wmand092`、`_wmif093`、`_wmapple094` | V2 排障时下载的 workmanager 各版本源码 | 不需要了 | 可删 |
| `D:\dev\_dl\` | SDK 安装包，约 1.5 GB | 环境已装好，不需要了 | 可删（最省空间的一项） |
| `android\.kotlin\` | 本轮构建新产生的 Kotlin 缓存 | 不需要（已加入 `.gitignore`，不会入库） | 可删，删了下次编译会自动重建 |

**想清理的话，告诉我删哪几项，我会先报出完整路径和影响，你确认后再动手。**

---

## 九、给后续接手者的技术备注

1. **`flutter analyze` 现在是 0 告警，请保持。** 新增代码后跑一下，别让它重新涨回去。
2. **改动 `android/` 下配置后，务必真跑一次编译。** 本轮 2.4（desugaring）和 2.5（minSdk）
   两个 bug 都是「配置看着对、编译才报错」的类型，静态分析查不出来。
3. **`kotlin.incremental=false` 的取舍**：如果将来把 pub 缓存迁到 D 盘
   （设环境变量 `PUB_CACHE=D:\dev\pub-cache` 并重装依赖），
   跨盘符问题消失，可以删掉这一行恢复增量编译。
4. **workmanager 升级路径**（V2 第 7 节第 3 条仍有效）：Flutter 升到 3.38+ 后，
   移除 `pubspec.yaml` 的 `dependency_overrides`、升 `workmanager: ^0.10.0`，
   并适配 `bg_service.dart` 的 0.10 API。
5. **`gradle.properties` 的乱码是假象**：在终端里 `cat`/`type` 这个文件看到中文乱码，
   是终端代码页（GBK）的问题，文件本身是合法 UTF-8。已做字节级核对，
   `systemProp.javax.net.ssl.trustStoreType=WINDOWS-ROOT` 是独立一行且生效中。

---

*交接文档 V3 —— 2026-10-02 整理*
