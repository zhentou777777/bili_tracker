@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "FLUTTER_ROOT=D:\dev\sdk\flutter"
set "ANDROID_HOME=D:\dev\android-sdk"
set "ANDROID_SDK_ROOT=D:\dev\android-sdk"
set "JAVA_HOME=C:\Program Files\Amazon Corretto\jdk17.0.20_10"
set "PATH=%JAVA_HOME%\bin;%FLUTTER_ROOT%\bin;%ANDROID_HOME%\platform-tools;%PATH%"
set "LOG=check_result.txt"

echo ============================================================
echo   追更台 bili_tracker —— 改动自检（分析 + 测试 + 编译）
echo ============================================================
echo.
echo   本脚本会依次执行三步，全部结果同时写入 %LOG%
echo   即使窗口一闪而过，也可以打开 %LOG% 查看。
echo.

> "%LOG%" echo ==== bili_tracker 自检日志 %DATE% %TIME% ====

echo [1/3] 静态分析（应当显示 No issues found!）……
call flutter analyze > "%TEMP%\bt_analyze.txt" 2>&1
type "%TEMP%\bt_analyze.txt"
echo. >> "%LOG%"
echo ---- [1] flutter analyze ---- >> "%LOG%"
type "%TEMP%\bt_analyze.txt" >> "%LOG%"

echo.
echo [2/3] 单元测试……
call flutter test > "%TEMP%\bt_test.txt" 2>&1
type "%TEMP%\bt_test.txt"
echo. >> "%LOG%"
echo ---- [2] flutter test ---- >> "%LOG%"
type "%TEMP%\bt_test.txt" >> "%LOG%"

echo.
echo [3/3] 编译 APK（约 5～15 分钟，请勿关闭窗口）……
call flutter build apk --release > "%TEMP%\bt_build.txt" 2>&1
type "%TEMP%\bt_build.txt" | findstr /C:"BUILD SUCCESSFUL" /C:"BUILD FAILED" /C:"Error" /C:"error:" /C:"app-release.apk"
echo. >> "%LOG%"
echo ---- [3] flutter build apk --release ---- >> "%LOG%"
type "%TEMP%\bt_build.txt" >> "%LOG%"

echo.
echo ============================================================
if exist "build\app\outputs\flutter-apk\app-release.apk" (
  echo   编译成功！APK 已生成：
  dir /b "build\app\outputs\flutter-apk\*.apk"
  echo.
  echo   位置：%cd%\build\app\outputs\flutter-apk\
) else (
  echo   没有生成 APK，说明编译未通过。
  echo   请把 %LOG% 里的内容（或窗口截图）发给助手。
)
echo.
echo   完整日志：%cd%\%LOG%
echo ============================================================
echo.
pause
exit /b 0
