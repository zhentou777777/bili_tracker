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

echo [1/6] 检查编译环境……
call flutter --version
if errorlevel 1 goto :envfail

echo.
echo [2/6] 备份现有 android 目录（防止模板覆盖手写配置）……
if exist "android_backup" rd /s /q "android_backup"
xcopy /e /i /q /y "android" "android_backup" >nul
echo      OK —— 已备份到 android_backup\

echo.
echo [3/6] 补齐 Android 构建模板（缺失的 gradle wrapper 等）……
call flutter create --platforms=android . >nul 2>&1
echo      正在还原手写配置文件……
xcopy /e /i /q /y "android_backup" "android" >nul
echo      OK

echo.
echo [4/6] 拉取依赖包（第一次会下载，请耐心等）……
call flutter pub get
if errorlevel 1 goto :fail

echo.
echo [5/6] 开始编译 APK —— 第一次约 5 到 15 分钟，请勿关闭窗口！
echo.
call flutter build apk --release
if errorlevel 1 (
  echo.
  echo      release 编译未通过，改为尝试 debug 版本……
  call flutter build apk --debug
  if errorlevel 1 goto :fail
)

echo.
echo [6/6] 编译完成！
echo.
echo   APK 输出目录：
echo   %cd%\build\app\outputs\flutter-apk\
echo.
echo   生成的安装包：
dir /b "build\app\outputs\flutter-apk\*.apk" 2>nul
echo.
echo ------------------------------------------------------------
echo   把上面列出的 .apk 传到手机，点击安装即可。
echo   若手机提示"未知来源"，请在设置里允许安装。
echo ------------------------------------------------------------
echo.
pause
exit /b 0

:envfail
echo.
echo ============================================================
echo   错误：找不到可用的 Flutter 环境
echo   请确认目录存在：%FLUTTER_ROOT%
echo   如目录不存在，请先安装 Flutter SDK。
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
