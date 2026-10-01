@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "FLUTTER_ROOT=D:\dev\sdk\flutter"
set "ANDROID_HOME=D:\dev\android-sdk"
set "ANDROID_SDK_ROOT=D:\dev\android-sdk"
set "JAVA_HOME=C:\Program Files\Amazon Corretto\jdk17.0.20_10"
set "PATH=%JAVA_HOME%\bin;%FLUTTER_ROOT%\bin;%ANDROID_HOME%\platform-tools;%PATH%"

echo ============================================================
echo    追更台 bili_tracker —— 一键编译 APK
echo ============================================================
echo.

echo [1/3] 检查编译环境……
call flutter --version
if errorlevel 1 goto :envfail

echo.
echo [2/3] 拉取依赖包（已全部缓存，通常十几秒）……
call flutter pub get
if errorlevel 1 goto :fail

echo.
echo [3/3] 开始编译 APK（预计 5～15 分钟，请勿关闭窗口！）……
echo.
call flutter build apk --release
if errorlevel 1 (
  echo.
  echo      release 编译未通过，改为尝试 debug 版本……
  call flutter build apk --debug
  if errorlevel 1 goto :fail
)

echo.
echo ============================================================
echo   编译完成！
echo.
echo   APK 输出目录：
echo   %cd%\build\app\outputs\flutter-apk\
echo.
echo   生成的安装包：
dir /b "build\app\outputs\flutter-apk\*.apk" 2>nul
echo.
echo   把上面列出的 .apk 传到手机，点击安装即可。
echo   若手机提示"未知来源"，请在设置里允许安装。
echo ============================================================
echo.
pause
exit /b 0

:envfail
echo.
echo ============================================================
echo   错误：找不到可用的 Flutter 环境
echo   请确认目录存在：%FLUTTER_ROOT%
echo ============================================================
echo.
pause
exit /b 1

:fail
echo.
echo ============================================================
echo   编译失败。请把窗口里的错误信息截图发给助手，我来分析。
echo   （源码和配置都有备份，不会丢失）
echo ============================================================
echo.
pause
exit /b 1
