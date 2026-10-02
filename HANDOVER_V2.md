# 追更台 bili_tracker —— 交接文档 V2（修复与排障全记录）

> ⚠️ **本文档为历史过程记录，已被 `交接文档.md`（权威版）整合并取代。**
> 建议先读 `交接文档.md`；本文保留作为当时的排查证据（阶段 A 的详细过程）。
> 第 3.3 节「两套配置等价、无设置丢失」的结论**已被推翻**（实际丢了 `minSdk`），详见 `交接文档.md` 第三节 B5。

> 本文档是 `HANDOVER.md` 的修订与扩展版，由接手方于 **2026-10-02** 整理。
> 覆盖范围：原始交接包（v0.1.0 zip）接手后的全部代码修复、环境搭建、
> 构建排障过程、实测验证结果，以及尚未完成的收尾事项。
>
> 面向读者：项目作者、后续接手的开发者。
> 仓库：https://github.com/zhentou777777/bili_tracker （私有）

---

## 〇、一页速览（TL;DR）

| 项 | 状态 |
|---|---|
| 源码备份 | ✅ GitHub 私有仓库，6 个提交，原始快照完整保留（`824bd93`） |
| 核心算法验证 | ✅ `tools/probe.dart` 22 项全部通过（真实网络，含 B 站在线接口） |
| 编译环境 | ✅ Flutter 3.32.8 + Android SDK + JDK 17 + NDK 26/27 全部就位（`D:\dev\`） |
| 已知代码错误 | ✅ 全部修复（4 类，共 12 处改动，见第二节） |
| 已知环境/配置障碍 | ✅ 全部扫清（6 项，见第三节） |
| 最终 APK 编译 | ⏳ **待在本机普通窗口双击 `BUILD_APK.bat` 完成** |
| 原交接文档错误 | ⚠️ 2 处已纠正（见第二节开头与第七节） |

**当前唯一未完成的事**：在本机跑通最后一次编译，产出 APK。

---

## 一、环境搭建记录（全部装在 `D:\dev\`，未污染系统）

| 组件 | 版本 | 位置 | 说明 |
|---|---|---|---|
| JDK | 17.0.20 (Corretto) | `C:\Program Files\Amazon Corretto\jdk17.0.20_10` | 本机已有。**JDK 25 不可用**（AGP 8.x/Gradle 8.12 不支持） |
| Flutter SDK | **3.32.8**（Dart 3.8.1） | `D:\dev\sdk\flutter` | 版本选择依据见第二节开头 |
| Android SDK | cmdline-tools 12.0 | `D:\dev\android-sdk` | platform-tools、android-34/35、build-tools 34/35 |
| Android NDK | 26.3.11579264 + **27.0.12077973** | `D:\dev\android-sdk\ndk\` | 27 为 8 个插件共同要求（见 3.5 节） |
| Gradle | 8.12（wrapper 自动管理） | `~/.gradle` 缓存 | 已改腾讯云镜像下载（见 3.2 节） |
| GitHub CLI | 2.102.0 | `D:\dev\gh\bin\gh.exe` | 已登录账号 `zhentou777777` |

**镜像策略（重要，国内网络实测）**：

| 资源 | 可用源 | 实测速度 |
|---|---|---|
| Flutter SDK 下载 | 腾讯云 `mirrors.cloud.tencent.com/flutter` | 1.6~11 MB/s（googleapis 仅 0.2 MB/s） |
| pub 包源 | **官方 `pub.dev`** | 正常（注意：`pub.flutter-io.cn` 会证书失败，见 3.6 节） |
| Gradle 发行版 | 腾讯云 `mirrors.cloud.tencent.com/gradle` | 6.8 MB/s（官方 0.95 MB/s） |
| Maven 依赖 | 阿里云 `maven.aliyun.com` 前置，官方源兜底 | — |

---

## 二、代码错误清单（全部已修复，共 4 类）

> 原始代码快照在 git 提交 `824bd93`，所有修复可 `git diff 824bd93` 逐行核对。

### ⚠️ 先纠正原交接文档（HANDOVER.md / README.md）的 2 处错误

1. **「Flutter ≥ 3.10」不成立**。`workmanager: ^0.9.0` 强制要求 **Flutter ≥ 3.32 / Dart ≥ 3.5**，
   按 3.10 装环境 `pub get` 直接失败。本项目锁定 **3.32.8**（满足依赖的最低稳定版，改动最小）。
2. **「flutter create 会保留手写 android 配置」不成立**。实测 `flutter create` 会生成
   新的 `.kts` 系列配置与手写 `.gradle` 并存，且 Gradle 实际优先执行 Groovy 版，
   导致构建失败（详见 3.3 节）。`BUILD_APK.bat` 已内置备份/还原逻辑处理。

### 2.1 必然编译错误：`CardTheme` 类型（提交 `549823e`）

| 文件 | 问题 | 修复 |
|---|---|---|
| `lib/ui/app.dart`（原 47 行附近） | `cardTheme: const CardTheme(...)`。`ThemeData.cardTheme` 自 Flutter 3.27 起类型改为 `CardThemeData`，**硬编译错误**。原注释「旧名仍可用且兼容 3.10+」是错的 | 改为 `CardThemeData` |

### 2.2 弃用 API：`withOpacity` ×7（提交 `549823e`）

`Color.withOpacity` 自 Flutter 3.27 弃用，4 个文件共 7 处 → `withValues(alpha: x)`（完全等价）：

- `lib/ui/calendar_page.dart` ×2
- `lib/ui/search_page.dart` ×2
- `lib/ui/today_page.dart` ×1
- `lib/ui/ups_page.dart` ×2

### 2.3 枚举类型用错：`bg_service.dart` ×2（提交 `3cc402c`）

| 位置 | 问题 | 修复 |
|---|---|---|
| `lib/service/bg_service.dart` 两处 `registerPeriodicTask` | `existingWorkPolicy:` 参数类型是 **`ExistingPeriodicWorkPolicy`**（周期任务专用枚举），原代码写成 `ExistingWorkPolicy`（一次性任务枚举）。两个枚举名字相近但是不同类型，**编译失败** | 改为 `ExistingPeriodicWorkPolicy.keep` |

### 2.4 上游依赖缺陷：workmanager 0.9.x 默认组合编译不过（提交 `3cc402c`）

这是最深的一个坑，**逐版本下载源码比对后实锤**：

```
因果链：
workmanager-0.9.2 声明依赖 platform_interface ^0.9.3
  → pub 解析器取最高版 0.9.4
  → interface 0.9.4 给 registerOneOffTask/registerPeriodicTask 新增了
    foregroundServiceConfig 命名参数
  → 但 workmanager_apple-0.9.4 的覆写没有同步该参数
  → Dart 覆写签名校验失败，kernel_snapshot 编译必挂
  → 即：workmanager 0.9.2 的默认依赖组合本身就是编译不过的（上游打包缺陷）
```

**修复**（`pubspec.yaml` 新增 `dependency_overrides`，钉回自洽组合）：

```yaml
dependency_overrides:
  workmanager_platform_interface: 0.9.3   # 无 foregroundServiceConfig，与 apple 覆写逐签名核对一致
  workmanager_android: 0.9.2              # 其约束 ^0.9.3 与上者兼容
```

**为什么不升 workmanager 0.10.x**：0.10.10 要求 **Flutter ≥ 3.38**，本项目锁定 3.32.8。
若未来升级 Flutter 到 3.38+，可移除上述 overrides 并将 `bg_service.dart` 适配 0.10 API
（`executeTask`/`registerPeriodicTask` 主签名在 0.10 中未变，改动量小）。

### 2.5 排查过、确认没问题的项

`MaterialStateProperty`、`ColorScheme` 旧字段（`background`/`surfaceVariant`）、
`textScaleFactor`、`WillPopScope`、`dialogTheme`/`tabBarTheme` —— 均未踩坑。

---

## 三、构建环境障碍清单（全部已扫清，按发生顺序）

### 3.1 缺 gradle wrapper（原始包缺陷）
`android/` 下没有 `gradlew.bat` / `gradle-wrapper.jar` / `gradle-wrapper.properties`。
**首次运行 `BUILD_APK.bat` 时已由 `flutter create --platforms=android .` 补齐**，模板文件现已入库。

### 3.2 Gradle 发行版下载中断（用户实跑第 1 次卡点）
- 现象：`~/.gradle/wrapper/dists/gradle-8.12-all/*.part` 残留，构建长时间无响应
- 根因：官方源 `services.gradle.org` 仅 0.95 MB/s，200MB 下载中途断开
- 修复：`gradle-wrapper.properties` 改腾讯云镜像（6.8 MB/s，快 7 倍），并用 `-bin` 包（体积减半）

### 3.3 Groovy 与 Kotlin DSL 双配置冲突（用户实跑第 2 次卡点）
- 现象：`Project ':app' could not be found in project ':flutter_inappwebview_android'`
- 根因：补模板后 `.kts` 与手写 `.gradle` 并存，**Gradle 实际执行 Groovy 版**；
  而手写 `settings.gradle` 缺 `include(":app")`（作者未编译过，配置本身不完整）
- 修复：3 份 Groovy 旧配置移入 `android/_legacy_groovy_bak/`（**内容完整保留，未删除**），
  仅让 `.kts` 生效。已比对两套配置等价，无设置丢失。

### 3.4 NDK 残缺（`[CXX1101] NDK ... did not have a source.properties file`）
AGP 自动下载 NDK 中途失败只留空目录。用 sdkmanager 手动装好 `ndk;26.3.11579264`。

### 3.5 NDK 版本不匹配警告（用户实跑第 3 次的红色警告）
8 个插件（workmanager / flutter_inappwebview / flutter_local_notifications /
flutter_secure_storage / path_provider / shared_preferences / sqflite / url_launcher）
要求 **NDK 27.0.12077973**，高于默认的 26.3。修复：
- sdkmanager 安装 `ndk;27.0.12077973`
- `android/app/build.gradle.kts` 显式 `ndkVersion = "27.0.12077973"`

### 3.6 Java 证书校验失败（`unable to find valid certification path`）
用户网络环境对部分 HTTPS 源做 TLS 拦截。双重修复：
- `android/gradle.properties` 加 `systemProp.javax.net.ssl.trustStoreType=WINDOWS-ROOT`
  （Java 信任 Windows 系统证书库）
- 阿里云 Maven 镜像前置（官方源保留兜底）

### 3.7 附注：国内镜像的一个坑
`pub.flutter-io.cn` / `storage.flutter-io.cn` 在部分网络环境下**证书验证失败**（Dart 报
`HandshakeException`），会把 `flutter` 命令卡死数十分钟。本项目最终采用
**官方 pub.dev + 腾讯云 storage 镜像** 的组合，实测稳定。若你复现环境时
Flutter 卡在 `Resolving dependencies...`，优先怀疑镜像源证书问题。

---

## 四、核心算法实测验证（原交接声称项的复核）

`tools/probe.dart`（零第三方依赖）在真实网络下运行：**22 项全部通过，0 失败**。

| 测试组 | 结果 | 说明 |
|---|---|---|
| MD5 自实现 | 5/5 ✅ | 含中文标准向量 |
| 表单编码对齐 `quote_plus` | 4/4 ✅ | WBI 签名最易错点 |
| 规则文件加载 | 2/2 ✅ | 6 个平台端点 |
| WBI mixin_key 获取 | ✅ | 实时从 B 站取得 |
| WBI 签名串生成 | 2/2 ✅ | |
| 直播状态接口 | ✅ | 实时查到碧诗/嘉然状态 |
| Cookie 失效检测 | ✅ | |
| 六种动态类型解析 | 6/6 ✅ | 视频/图文/文字/转发/专栏/直播 |

**结论：原交接文档「B 站闭环算法层已验证」的说法经复核成立。**

复现命令（任意装有 Dart 的机器）：

```bat
set FLUTTER_ROOT=D:\dev\sdk\flutter
"D:\dev\sdk\flutter\bin\cache\dart-sdk\bin\dart.exe" tools\probe.dart
```

---

## 五、构建链路验证状态（沙箱内逐层实测）

在 AI 助手的受限沙箱中直接运行 `gradlew :app:assembleDebug` 的结果：

| 环节 | 结果 |
|---|---|
| flutter_tools Gradle 插件编译 | ✅ |
| 全部 Maven 依赖解析（含证书） | ✅ |
| NDK / SDK 检查与任务配置 | ✅ |
| Android 侧构建任务 | ✅ |
| **Dart 编译（kernel_snapshot）** | ❌ 沙箱特有限制（Dart 无法用命名管道捕获子进程输出，报 `CreateFile failed 231`） |

> 该限制**仅存在于 AI 工具的运行沙箱**（对照实验：Python 可正常启动子进程，Dart/Node 不行；
> Windows 原生管道 API 正常）。**普通本机窗口无此限制**，因此最终编译由
> `BUILD_APK.bat` 在用户本机完成。截至目前，沙箱内能验证的环节已全部验证通过。

---

## 六、目录与文件变更说明

| 文件/目录 | 状态 | 用途 |
|---|---|---|
| `BUILD_APK.bat` | 新增 | 一键编译脚本：校验环境 → pub get → 编译 release APK，失败自动重试 debug |
| `编译说明.txt` | 新增 | 面向非技术用户的图文操作说明 |
| `修复说明.md` | 新增 | 技术向修复清单（与本文档互补） |
| `HANDOVER_V2.md` | 新增 | 本文档 |
| `pubspec.yaml` | 修改 | 新增 `dependency_overrides`（见 2.4） |
| `lib/ui/app.dart` 等 5 个 dart 文件 | 修改 | 见第二节 |
| `android/app/build.gradle.kts` | 修改 | `ndkVersion` 显式指定 27.0.12077973 |
| `android/gradle.properties` | 修改 | Java 证书加固 |
| `android/gradle/wrapper/gradle-wrapper.properties` | 修改 | 腾讯云镜像 |
| `android/settings.gradle.kts`、`android/build.gradle.kts` | 修改 | 阿里云 Maven 镜像前置 |
| `android/_legacy_groovy_bak/` | 新增（备份） | 旧 Groovy 构建配置，**内容完整保留**，确认 .kts 路线稳定后可删 |
| `android_backup/` | 脚本生成（备份） | 首次编译前的 android 配置快照，可删 |
| `.gitignore` | 修改 | 忽略 `android_backup/` |

**GitHub 提交历史**（私有仓库 `zhentou777777/bili_tracker`，main 分支）：

```
824bd93  chore: 原始交接代码快照 (v0.1.0)          ← 原始代码，未动一字
549823e  fix: 修复首次编译错误，新增一键编译脚本与说明
9bbcad8  fix: 修复构建卡点 —— Gradle 下载中断，改用国内镜像
84cf44d  fix: 扫清构建链路全部障碍（沙箱实测验证）
41212e5  fix: ndkVersion 显式指定 27.0.12077973
3cc402c  fix: workmanager 0.9.x 上游缺陷绕过 + bg_service 类型错误修复
```

---

## 七、给原作者 / 后续接手者的建议

1. **更新 HANDOVER.md**：Flutter 版本要求 3.10 → **3.32**（workmanager 强制）；
   删除「flutter create 会保留手写配置」的说法。
2. **编译验证流程**：以后交付 Flutter 项目前至少跑一次 `flutter build apk --debug`，
   本文 2.3 / 2.4 两类问题都能被一次编译暴露。
3. **workmanager 升级路径**：Flutter 升到 3.38+ 后，移除 `dependency_overrides`、
   升 `workmanager: ^0.10.0`，并把 `bg_service.dart` 适配 0.10 API
   （可选新增 `onTaskStopped` 回调处理任务被系统杀死的情况）。
4. **待清理项（删除前需人工确认）**：
   - `android/_legacy_groovy_bak/`（确认 .kts 构建稳定后）
   - `android_backup/`（APK 编译成功后）
   - `D:\dev\_wm010`、`D:\dev\_wmif010`、`D:\dev/_wmand092`、`D:\dev/_wmif093`、
     `D:\dev/_wmapple094`（排障时下载的 workmanager 各版本源码副本）
   - `D:\dev\_dl\`（SDK 安装包，约 1.5GB，确认环境不再重装后可删）

---

## 八、当前状态与下一步

- ✅ 代码：所有已知错误已修复并推送 GitHub
- ✅ 环境：Flutter / Android SDK / JDK / NDK 全部就位且已缓存
- ⏳ **唯一待办：在本机普通窗口双击 `BUILD_APK.bat`，等待 5~15 分钟**
  - 成功 → APK 位于 `build\app\outputs\flutter-apk\app-release.apk`，可直接传手机安装
  - 失败 → 截图报错窗口，按本文档第三节的逐层排查思路继续定位

---

*交接文档 V2 —— 2026-10-02 整理*
