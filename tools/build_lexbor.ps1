# Builds Lexbor (ext\lexbor, a pinned release) + our shim (src\html\shim\wb_html.c) into build\lexbor\lexbor.lib with MSVC.
# HTML5 tokenizer/tree builder, CSS parser, selectors. No CMake.
#   powershell -File tools\build_lexbor.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$L = Join-Path $root 'ext\lexbor\source'
if (-not (Test-Path "$L\lexbor")) { throw 'ext\lexbor is empty: run  git submodule update --init' }

if (-not $env:VCINSTALLDIR) {
    $vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
    cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul && set" | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
    }
}

$out = Join-Path $root 'build\lexbor'
Remove-Item -Recurse -Force "$out\obj" -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$out\obj" | Out-Null

# same file names exist in several directories (state.c, res.c...): one object directory per source directory
$sources = Get-ChildItem "$L\lexbor" -Recurse -Filter *.c | Where-Object { $_.FullName -notmatch '\\ports\\posix\\' }
$groups = $sources | Group-Object DirectoryName
$flags = @('/nologo', '/c', '/MP', '/O2', '/DNDEBUG', '/MD', '/W1', '/wd4100', '/wd4255', '/wd4820', '/wd4668',
           '/D_CRT_SECURE_NO_WARNINGS', '/DLEXBOR_STATIC', "/I$L", "/I$L\lexbor\ports\windows_nt")
$log = Join-Path $out 'build.log'
Remove-Item $log -ErrorAction SilentlyContinue
$i = 0
foreach ($g in $groups) {
    $dir = "$out\obj\d$i"; $i++
    New-Item -ItemType Directory -Force $dir | Out-Null
    & cl @flags "/Fo$dir\" ($g.Group | ForEach-Object { $_.FullName }) *>> $log
}
New-Item -ItemType Directory -Force "$out\obj\shim" | Out-Null
& cl @flags "/Fo$out\obj\shim\" (Join-Path $root 'src\html\shim\wb_html.c') *>> $log

$errors = Select-String -Path $log -Pattern ' error ' -SimpleMatch
if ($errors) { $errors | Select-Object -First 10; throw "build failed, see $log" }
$objs = Get-ChildItem "$out\obj" -Recurse -Filter *.obj | ForEach-Object { $_.FullName }
& lib /nologo "/OUT:$out\lexbor.lib" @objs
"built $out\lexbor.lib ($($objs.Count) objects)"
