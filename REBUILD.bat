@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "FLUTTER_ROOT=D:\dev\sdk\flutter"
set "ANDROID_HOME=D:\dev\android-sdk"
set "ANDROID_SDK_ROOT=D:\dev\android-sdk"
set "JAVA_HOME=C:\Program Files\Amazon Corretto\jdk17.0.20_10"
set "PATH=%JAVA_HOME%\bin;%FLUTTER_ROOT%\bin;%ANDROID_HOME%\platform-tools;%PATH%"
set "LOG=rebuild_result.txt"

echo ============================================================
echo   追更台 —— 强制重新编译（先清缓存，再重新打包）
echo ============================================================
echo.
echo   为什么要清理？
echo     上一次编译（01:21）把改动后的 Dart 代码误判成「没变化」，
echo     直接重用了旧的编译产物 —— 只花 2.9 秒，产出的 APK 里
echo     其实还是改动前的老代码（已逐字节核对确认）。
echo     Flutter 的增量编译偶尔会漏判源码变更，需要干净重编强制刷新。
echo.
echo   本脚本会删除下面这些【编译缓存】，它们全部可以自动重建：
echo       .dart_tool\flutter_build\      （Dart 编译中间产物）
echo       build\                          （打包中间产物）
echo.
echo   不会动的东西：源码 lib\、配置 android\、assets\、git 记录、
echo                 以及你的任何文档。删除前会先请你确认。
echo.
set /p ANS=确认开始吗？输入 Y 再回车继续，其它键回车即取消： 
if /i not "%ANS%"=="Y" (
  echo.
  echo   已取消，未删除任何文件。
  echo.
  pause
  exit /b 0
)

echo.
echo [1/4] 清理编译缓存（flutter clean）……
call flutter clean

echo.
echo [2/4] 刷新依赖（flutter pub get）……
call flutter pub get

echo.
echo [3/4] 重新编译 APK（约 5～15 分钟，请勿关闭窗口）……
call flutter build apk --release > "%TEMP%\bt_rebuild.txt" 2>&1
type "%TEMP%\bt_rebuild.txt" | findstr /C:"BUILD SUCCESSFUL" /C:"BUILD FAILED" /C:"error:" /C:"Built build"

echo.
echo [4/4] 结果
echo.
echo ==== 强制重编日志 %DATE% %TIME% ==== > "%LOG%"
echo. >> "%LOG%"
type "%TEMP%\bt_rebuild.txt" >> "%LOG%"
echo. >> "%LOG%"

if exist "build\app\outputs\flutter-apk\app-release.apk" (
  echo   编译成功！新的 APK：
  dir /b "build\app\outputs\flutter-apk\*.apk"
  echo.
  echo   位置：%cd%\build\app\outputs\flutter-apk\
  echo.
  echo   看看这个文件的「修改时间」应当是刚刚，才是这次真正新编的包。
  echo   把它传到手机安装即可（若手机提示"未知来源"，允许安装未知应用）。
) else (
  echo   没有生成 APK，说明编译未通过。
  echo   请把 %LOG% 的内容或窗口截图发给助手。
)

echo.
echo   完整日志：%cd%\%LOG%
echo ============================================================
echo.
pause
exit /b 0
