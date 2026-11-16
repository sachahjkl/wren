@echo off
:: Shortcut: build.bat [dev|quick|debug|profile|check|release|bench|deps|help] is wrentool build (src\tools\wrentool\builder).
:: Every other step: odin run src\tools\wrentool -collection:wb=src -collection:toolkit=ext/gui_toolkit/src -out:build\wrentool.exe -keep-executable -- <command> (help lists them).
cd /D "%~dp0"
if not exist build mkdir build
odin run src\tools\wrentool -collection:wb=src -collection:toolkit=ext/gui_toolkit/src -use-separate-modules -out:build\wrentool.exe -keep-executable -- build %*
