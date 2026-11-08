#!/usr/bin/env bash
# Shortcut: ./build.sh [dev|quick|debug|profile|check|release|bench|deps|help] is wrentool build (src/tools/wrentool/builder).
# Every other step: odin run src/tools/wrentool -collection:wb=src -out:build/wrentool -keep-executable -- <command> (help lists them).
cd "$(dirname "$0")" && mkdir -p build && exec odin run src/tools/wrentool -collection:wb=src -out:build/wrentool -keep-executable -- build "$@"
