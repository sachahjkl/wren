# Refreshes native\js\webref: the Web IDL of the specifications the JavaScript bindings are generated from, taken from
# the W3C webref project's npm package @webref/idl at a pinned version, checked by the registry's SHA-512 integrity.
#   powershell -NoProfile -File tools\update_webref.ps1
# To move to another release: change $Version and $Integrity (npm view @webref/idl@<version> dist.integrity), run this
# script, then bindgen (build.bat): the bindings, docs\js\coverage.md and the interface table follow.
# Only the files listed in $Files are vendored (the specifications the browser binds, plus those their IDL refers to).
param()
$ErrorActionPreference = 'Stop'
$Version = '3.85.2'
$Integrity = 'sha512-rpl9CwsQi9Ft+KmkC6YvgaTbWtusqUzIGiI3qHKIQ8skjph+W47OlSdaUGERwzzVGhtwMCOsQ+tMm9x9LGw8jg=='
$Files = @(
    'dom', 'html', 'webidl', 'console', 'hr-time', 'uievents', 'url', 'encoding', 'fetch', 'xhr', 'FileAPI', 'streams',
    'cssom', 'cssom-view', 'css-conditional', 'css-font-loading', 'css-animations', 'css-transitions', 'web-animations',
    'geometry', 'selection-api', 'pointerevents', 'touch-events', 'input-events', 'clipboard-apis', 'fullscreen',
    'user-timing', 'performance-timeline', 'navigation-timing', 'resource-timing', 'requestidlecallback',
    'intersection-observer', 'resize-observer', 'websockets', 'webcrypto', 'permissions', 'page-lifecycle',
    'service-workers', 'storage', 'referrer-policy', 'trusted-types', 'SVG', 'mathml-core', 'wai-aria', 'IndexedDB',
    'scroll-to-text-fragment', 'web-share', 'notifications', 'gamepad', 'screen-orientation', 'media-source', 'mediasession',
    'cookiestore', 'beacon', 'compression', 'web-locks', 'scheduling-apis', 'paint-timing', 'largest-contentful-paint',
    'event-timing', 'longtasks', 'device-memory', 'netinfo', 'ua-client-hints', 'vibration', 'css-highlight-api',
    'css-typed-om', 'css-view-transitions', 'speech-api', 'webaudio', 'mediacapture-streams', 'html-media-capture',
    'entries-api', 'badging', 'credential-management', 'storage-access', 'is-input-pending', 'css-properties-values-api', 'webauthn'
)

$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'native\js\webref'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "wren-webref-$Version"
New-Item -ItemType Directory -Force $tmp | Out-Null
$tgz = Join-Path $tmp "idl-$Version.tgz"
$url = "https://registry.npmjs.org/@webref/idl/-/idl-$Version.tgz"
function Get-Integrity([string]$path) {
    $sha = [Security.Cryptography.SHA512]::Create()
    $fs = [IO.File]::OpenRead($path)
    try { return 'sha512-' + [Convert]::ToBase64String($sha.ComputeHash($fs)) } finally { $fs.Close() }
}
if (-not (Test-Path $tgz) -or (Get-Integrity $tgz) -ne $Integrity) {
    "downloading $url"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $tgz -UseBasicParsing
}
$got = Get-Integrity $tgz
if ($got -ne $Integrity) { Remove-Item $tgz -Force; throw "integrity mismatch for $url`: expected $Integrity, got $got" }
$x = Join-Path $tmp 'x'
if (Test-Path $x) { [IO.Directory]::Delete($x, $true) }
New-Item -ItemType Directory -Force $x | Out-Null
& tar -xzf $tgz -C $x
if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }
if (Test-Path $out) { Get-ChildItem $out -Filter *.idl | Remove-Item -Force }
New-Item -ItemType Directory -Force $out | Out-Null
$sums = New-Object System.Text.StringBuilder
foreach ($f in ($Files | Sort-Object)) {
    $src = Join-Path $x "package\$f.idl"
    if (-not (Test-Path $src)) { throw "$f.idl is not in @webref/idl $Version" }
    Copy-Item $src (Join-Path $out "$f.idl") -Force
    $h = (Get-FileHash (Join-Path $out "$f.idl") -Algorithm SHA256).Hash.ToLower()
    [void]$sums.Append("$h  $f.idl`n")
}
[IO.File]::WriteAllText((Join-Path $out 'VERSION'), "@webref/idl $Version`n$Integrity`n")
[IO.File]::WriteAllText((Join-Path $out 'SHA256SUMS'), $sums.ToString())
[IO.Directory]::Delete($x, $true)
"vendored $($Files.Count) IDL files of @webref/idl $Version into $out"
