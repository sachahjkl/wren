# Downloads the official Wasmtime C API release (pinned version, SHA-256 checked) into build\wasmtime:
#   build\wasmtime\include\...      headers (reference for src\wasm\wasmtime.odin)
#   build\wasmtime\lib\wasmtime.lib static library (linked into wren.exe: no DLL to ship)
#   build\wasmtime\VERSION          the version installed (the script does nothing when it already matches)
# Usage: powershell -NoProfile -File tools\fetch_wasmtime.ps1 [-Force]
# To move to another release: change $Version and $Sha256 (the digest GitHub shows for the x86_64-windows-c-api asset),
# then the WASMTIME_VERSION constant of src\wasm\wasmtime.odin (it is part of the compiled-code cache key).
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$Version = '49.0.3'
$Sha256 = 'f8dabbc1df2358f15effbd6e50c940c03df3836e13cbf4f09cdf6369057aed01'
$Name = "wasmtime-v$Version-x86_64-windows-c-api"
$Url = "https://github.com/bytecodealliance/wasmtime/releases/download/v$Version/$Name.zip"

$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\wasmtime'
$stamp = Join-Path $out 'VERSION'
if (-not $Force -and (Test-Path (Join-Path $out 'lib\wasmtime.lib')) -and (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $Version)) {
    "wasmtime $Version already in $out"
    exit 0
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) "wren-wasmtime-$Version"
New-Item -ItemType Directory -Force $tmp | Out-Null
$zip = Join-Path $tmp "$Name.zip"
if (-not (Test-Path $zip) -or (Get-FileHash $zip -Algorithm SHA256).Hash -ne $Sha256.ToUpper()) {
    "downloading $Url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $zip -UseBasicParsing
}
$got = (Get-FileHash $zip -Algorithm SHA256).Hash
if ($got -ne $Sha256.ToUpper()) {
    Remove-Item $zip -Force
    throw "SHA-256 mismatch for $Name.zip: expected $Sha256, got $got"
}

$x = Join-Path $tmp 'x'
if (Test-Path $x) { [IO.Directory]::Delete($x, $true) }
Expand-Archive -Path $zip -DestinationPath $x -Force
$src = Join-Path $x $Name
New-Item -ItemType Directory -Force (Join-Path $out 'lib') | Out-Null
if (Test-Path (Join-Path $out 'include')) { [IO.Directory]::Delete((Join-Path $out 'include'), $true) }
Copy-Item -Recurse (Join-Path $src 'include') (Join-Path $out 'include')
Copy-Item (Join-Path $src 'lib\wasmtime.lib') (Join-Path $out 'lib\wasmtime.lib') -Force
Copy-Item (Join-Path $src 'LICENSE') (Join-Path $out 'LICENSE') -Force
[IO.File]::WriteAllText($stamp, $Version)
[IO.Directory]::Delete($x, $true)
"wasmtime $Version installed in $out"
