# E1 parity harness: fetch the pinned test262 suite, the unpatched QuickJS-ng release source, and the pinned Zig,
# into a scratch area (not build\, which other agents hold). Reuses the exact pins from test262.ps1 / build_js.ps1
# so the oracle matches the suite the rest of Wren tests against. Idempotent: each piece is skipped when present.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scratch = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle'
New-Item -ItemType Directory -Force $scratch | Out-Null

$Test262Commit = '5ef1e5723be95296f36afb0386676fed0205869c'
$Test262Sha256 = 'd67ff29d7bcee3493f38b3ef54db068ea5ad6d5a67b67b3f505dfee581dd3879'
$QjsVersion = '0.17.0'
$QjsSha256 = '559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9'
$ZigVersion = '0.15.2'

function Get-Pinned([string]$url, [string]$file, [string]$sha) {
    if ((Test-Path $file) -and (Get-FileHash $file -Algorithm SHA256).Hash -eq $sha.ToUpper()) { "have $file"; return }
    "downloading $url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -ErrorAction Stop
    if ($sha) {
        $got = (Get-FileHash $file -Algorithm SHA256).Hash
        if ($got -ne $sha.ToUpper()) { Remove-Item $file -Force; throw "SHA mismatch $url expected $sha got $got" }
    }
}

# test262
$tarball = Join-Path $scratch "test262-$Test262Commit.tar.gz"
if (-not (Test-Path (Join-Path $scratch 'test262\test\language'))) {
    Get-Pinned "https://codeload.github.com/tc39/test262/tar.gz/$Test262Commit" $tarball $Test262Sha256
    & tar -xzf $tarball -C $scratch
    if (Test-Path (Join-Path $scratch 'test262')) { Remove-Item (Join-Path $scratch 'test262') -Recurse -Force }
    Rename-Item (Join-Path $scratch "test262-$Test262Commit") 'test262'
}
"test262 ready: $(Join-Path $scratch 'test262')"

# unpatched QuickJS-ng source
$qjsTar = Join-Path $scratch "quickjs-ng-v$QjsVersion.tar.gz"
Get-Pinned "https://github.com/quickjs-ng/quickjs/archive/refs/tags/v$QjsVersion.tar.gz" $qjsTar $QjsSha256
if (-not (Test-Path (Join-Path $scratch "quickjs-$QjsVersion\quickjs.c"))) {
    & tar -xzf $qjsTar -C $scratch
}
"quickjs source ready: $(Join-Path $scratch "quickjs-$QjsVersion")"

# Zig (pinned). The build already uses the Windows x86_64 tarball.
$zigDir = Join-Path $scratch "zig-x86_64-windows-$ZigVersion"
$zig = Join-Path $zigDir 'zig.exe'
if (-not (Test-Path $zig)) {
    $zigZip = Join-Path $scratch "zig-$ZigVersion.zip"
    $zigUrl = "https://ziglang.org/download/$ZigVersion/zig-x86_64-windows-$ZigVersion.zip"
    "downloading $zigUrl"
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $zigUrl -OutFile $zigZip -UseBasicParsing -ErrorAction Stop }
    catch {
        $zigUrl2 = "https://ziglang.org/download/$ZigVersion/zig-windows-x86_64-$ZigVersion.zip"
        "retry $zigUrl2"
        Invoke-WebRequest -Uri $zigUrl2 -OutFile $zigZip -UseBasicParsing -ErrorAction Stop
    }
    Expand-Archive -Path $zigZip -DestinationPath $scratch -Force
    $extracted = Get-ChildItem $scratch -Directory | Where-Object { $_.Name -like "zig-*$ZigVersion*" } | Select-Object -First 1
    if ($extracted.FullName -ne $zigDir) { if (Test-Path $zigDir) { Remove-Item $zigDir -Recurse -Force }; Rename-Item $extracted.FullName (Split-Path $zigDir -Leaf) }
}
"zig ready: $zig"
"OK"
