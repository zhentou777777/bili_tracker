@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set "FLUTTER_ROOT=D:\dev\sdk\flutter"
set "ANDROID_HOME=D:\dev\android-sdk"
set "ANDROID_SDK_ROOT=D:\dev\android-sdk"
set "JAVA_HOME=C:\Program Files\Amazon Corretto\jdk17.0.20_10"
set "PATH=%JAVA_HOME%\bin;%FLUTTER_ROOT%\bin;%ANDROID_HOME%\platform-tools;%PATH%"
set "LOG=build_theme_result.txt"
set "OUTDIR=build\app\outputs\flutter-apk"

echo ============================================================
echo   追更台 —— 分别打出「纯浅色」和「纯深色」两个安装包
echo ============================================================
echo.
echo   背景：
echo     应用本身已经内置浅色 / 深色两套配色，装一个包就能在
echo     「设置 - 外观」里随时切换，还能跟随系统。
echo     所以正常只要跑 REBUILD.bat 出一个包就够了。
echo.
echo   什么情况才需要这个脚本：
echo     你想**把主题写死**（比如给只用浅色的长辈装、或者两台
echo     手机各装一版），不希望它跟着系统变。
echo.
echo   本脚本会依次产出两个 APK：
echo     app-release-light.apk   强制浅色
echo     app-release-dark.apk    强制深色
echo.
echo   实现方式：编译参数 --dart-define=FORCE_THEME=light / dark，
echo   运行时「设置 - 外观」里的开关会置灰并显示锁定原因。
echo   两个包互不影响，可以同时装在手机里（但包名相同，后装的会覆盖先装的）。
echo.
echo   预计总耗时 10～30 分钟（编译两遍）。中途请勿关闭窗口。
echo.
set /p ANS=确认开始吗？输入 Y 再回车继续，其它键回车即取消： 
if /i not "%ANS%"=="Y" (
  echo.
  echo   已取消，未做任何改动。
  echo.
  pause
  exit /b 0
)

echo.
echo [1/3] 清理编译缓存并刷新依赖……
call flutter clean
call flutter pub get

echo.
echo [2/3] 编译「纯浅色」包……
call flutter build apk --release --dart-define=FORCE_THEME=light > "%TEMP%\bt_theme.txt" 2>&1
type "%TEMP%\bt_theme.txt" | findstr /C:"BUILD SUCCESSFUL" /C:"BUILD FAILED" /C:"error:"
if exist "%OUTDIR%\app-release.apk" copy /y "%OUTDIR%\app-release.apk" "%OUTDIR%\app-release-light.apk" >nul

echo.
echo [3/3] 编译「纯深色」包……
call flutter build apk --release --dart-define=FORCE_THEME=dark >> "%TEMP%\bt_theme.txt" 2>&1
type "%TEMP%\bt_theme.txt" | findstr /C:"BUILD SUCCESSFUL" /C:"BUILD FAILED" /C:"error:"
if exist "%OUTDIR%\app-release.apk" copy /y "%OUTDIR%\app-release.apk" "%OUTDIR%\app-release-dark.apk" >nul

echo.
echo ==== 主题双包构建日志 %DATE% %TIME% ==== > "%LOG%"
echo. >> "%LOG%"
type "%TEMP%\bt_theme.txt" >> "%LOG%"
echo. >> "%LOG%"

echo ============================================================
echo   结果
echo ============================================================
if exist "%OUTDIR%\app-release-light.apk" (
  echo   浅色包：%cd%\%OUTDIR%\app-release-light.apk
) else (
  echo   浅色包：未生成
)
if exist "%OUTDIR%\app-release-dark.apk" (
  echo   深色包：%cd%\%OUTDIR%\app-release-dark.apk
) else (
  echo   深色包：未生成
)
echo.
echo   请核对两个文件的「修改时间」应当是刚刚 —— 只看日志里的
echo   Built 字样会误判（本项目遇到过增量编译假成功）。
echo.
echo   完整日志：%cd%\%LOG%
echo ============================================================
echo.
pause
exit /b 0
