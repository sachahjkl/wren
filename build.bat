@echo off
:: build.bat [dev|debug|profile|check|release|help]: Wren's build is `wrentool build` (src\tools\wrentool\builder\builder.odin); this only runs it,
:: through an exe of its own deleted after (two builds at once cannot share one).
setlocal
cd /D "%~dp0"
if not exist build mkdir build
set "WRENTOOL=build\wrentool_%RANDOM%%RANDOM%.exe"
odin build src/tools/wrentool -collection:wb=src -use-separate-modules -out:%WRENTOOL% || exit /b 1
%WRENTOOL% build %*
set "CODE=%ERRORLEVEL%"
del "%WRENTOOL%" 2>nul
exit /b %CODE%
