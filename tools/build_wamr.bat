@echo off
:: Builds WAMR (ext\wamr, a pinned release) into build\wamr\wamr.lib with MSVC. No CMake: the sources and defines mirror
:: product-mini/platforms/windows with the fast interpreter, no WASI, no libc, no threads, no AOT/JIT.
::   tools\build_wamr.bat [debug]
setlocal
cd /D "%~dp0.."
set "W=%CD%\ext\wamr"
if exist "%W%\core\iwasm" goto have_src
echo ext\wamr is empty: run  git submodule update --init
exit /b 1
:have_src
if defined VCINSTALLDIR goto have_vc
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -property installationPath`) do set "VS=%%i"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
:have_vc
set "OUT=%CD%\build\wamr"
if not exist "%OUT%\obj" mkdir "%OUT%\obj"

:: /MD: Odin links the dynamic CRT, so the library must too
set "OPT=/O2 /DNDEBUG /MD"
if "%1"=="debug" set "OPT=/Od /Zi /MD"

set "DEFS=/DBH_PLATFORM_WINDOWS /DBUILD_TARGET_X86_64 /DHAVE_STRUCT_TIMESPEC /D_WINSOCK_DEPRECATED_NO_WARNINGS /D_CRT_SECURE_NO_WARNINGS"
set "DEFS=%DEFS% /DBH_MALLOC=wasm_runtime_malloc /DBH_FREE=wasm_runtime_free"
set "DEFS=%DEFS% /DWASM_ENABLE_INTERP=1 /DWASM_ENABLE_FAST_INTERP=1 /DWASM_ENABLE_AOT=0 /DWASM_ENABLE_JIT=0 /DWASM_ENABLE_FAST_JIT=0"
set "DEFS=%DEFS% /DWASM_ENABLE_LIBC_BUILTIN=0 /DWASM_ENABLE_LIBC_WASI=0 /DWASM_ENABLE_THREAD_MGR=0 /DWASM_ENABLE_SHARED_MEMORY=0"
set "DEFS=%DEFS% /DWASM_ENABLE_BULK_MEMORY=1 /DWASM_ENABLE_BULK_MEMORY_OPT=1 /DWASM_ENABLE_REF_TYPES=1 /DWASM_ENABLE_TAIL_CALL=1 /DWASM_ENABLE_SIMD=0"
set "DEFS=%DEFS% /DWASM_ENABLE_MINI_LOADER=0 /DWASM_ENABLE_MULTI_MODULE=0 /DWASM_ENABLE_GC=0 /DWASM_ENABLE_DUMP_CALL_STACK=0"
set "DEFS=%DEFS% /DWASM_ENABLE_CUSTOM_NAME_SECTION=1 /DWASM_ENABLE_NAME_SECTION=1"
:: a script must not be able to hang the UI: per-call instruction budget + wasm_runtime_terminate from a watchdog
set "DEFS=%DEFS% /DWASM_ENABLE_INSTRUCTION_METERING=1 /DWASM_API_EXTERN= /DWASM_RUNTIME_API_EXTERN= /DCOMPILING_WASM_RUNTIME_API=1"

set "INC=/I%W%\core\iwasm\include /I%W%\core\iwasm\common /I%W%\core\iwasm\interpreter /I%W%\core\shared\platform\include /I%W%\core\shared\platform\windows /I%W%\core\shared\utils /I%W%\core\shared\mem-alloc /I%W%\core\shared\mem-alloc\ems /I%W%\core"

:: no wasm_c_api.c: the standard wasm-c-api symbols (wasm_engine_new...) come from Wasmtime, linked in the same binary
set "C=%W%\core\iwasm\common"
set "SRC="%C%\wasm_application.c" "%C%\wasm_blocking_op.c" "%C%\wasm_exec_env.c" "%C%\wasm_loader_common.c" "%C%\wasm_memory.c" "%C%\wasm_native.c" "%C%\wasm_runtime_common.c" "%C%\wasm_shared_memory.c""
set "SRC=%SRC% "%W%\core\iwasm\interpreter\wasm_loader.c" "%W%\core\iwasm\interpreter\wasm_runtime.c" "%W%\core\iwasm\interpreter\wasm_interp_fast.c""
set "SRC=%SRC% "%W%\core\shared\mem-alloc\mem_alloc.c" "%W%\core\shared\mem-alloc\ems\*.c" "%W%\core\shared\utils\*.c""
set "SRC=%SRC% "%W%\core\shared\platform\windows\platform_init.c" "%W%\core\shared\platform\windows\win_clock.c" "%W%\core\shared\platform\windows\win_malloc.c""
set "SRC=%SRC% "%W%\core\shared\platform\windows\win_memmap.c" "%W%\core\shared\platform\windows\win_socket.c" "%W%\core\shared\platform\windows\win_thread.c""
set "SRC=%SRC% "%W%\core\shared\platform\windows\win_time.c" "%W%\core\shared\platform\windows\win_util.c" "%W%\core\shared\platform\common\memory\*.c""

del /q "%OUT%\obj\*.obj" 2>nul
cl /nologo /c /MP /W1 %OPT% %DEFS% %INC% /Fo"%OUT%\obj\\" %SRC% > "%OUT%\build.log" 2>&1
findstr /c:" error " "%OUT%\build.log" && ( echo build failed, see %OUT%\build.log & exit /b 1 )
ml64 /nologo /c /Fo"%OUT%\obj\invokeNative_em64.obj" "%W%\core\iwasm\common\arch\invokeNative_em64.asm" || exit /b 1
lib /nologo /OUT:"%OUT%\wamr.lib" "%OUT%\obj\*.obj" || exit /b 1
:: build.bat rebuilds the library when this stamp differs (the set of sources changed)
>"%OUT%\STAMP" echo no-c-api-1
echo built %OUT%\wamr.lib
