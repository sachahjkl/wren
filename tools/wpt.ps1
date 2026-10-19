# web-platform-tests in Wren without a window: the folders of wpt\suites.txt at a pinned WPT commit, run by
# src\tools\wpt against the test server (tools\testserver\wpt.go, http://127.0.0.1:8768/), compared with the
# expectations of wpt\expectations.
#   powershell -NoProfile -File tools\wpt.ps1 [-Quick] [-Update] [-Only /dom/nodes/] [-Jobs n] [-TimeoutMs 10000]
#       [-Fetch] [-UpdateManifest] [-NoServer] [-Port 8778] [-Pref name=value,...]
# Pinned: the WPT commit below; the checkout (build\wpt\wpt, a partial sparse clone of that commit: the measured folders
# and the shared ones) is verified file by file against wpt\MANIFEST.txt (SHA-256 of every file). -UpdateManifest
# rewrites that list after a change of the commit or of the folders (and says so); -Fetch only fetches and verifies.
# The server: build\testserver.exe -wpt-only -wpt-port $Port (8778 by default): the WPT origin alone, on ports of its
# own, so that a long run holds none of the shared test ports (8765-8768) and needs no shared lock. -NoServer uses the
# server already running (tools\test_all.ps1 starts it, under the shared lock: the WPT origin is then on 8768).
# Outputs in build\wpt: report.md (pass rates per folder), results.txt (every test and subtest), children\ (logs).
# Exit status: 1 on a regression against the expectations (not on an expected failure). -Update rewrites them (full
# run only). -Quick: a fixed sample of a few tests per folder (tools\test_all.ps1 -Quick).
param([switch]$Quick, [switch]$Update, [string]$Only = '', [int]$Jobs = 0, [int]$TimeoutMs = 10000, [switch]$Fetch,
      [switch]$UpdateManifest, [switch]$NoServer, [int]$Port = 0, [string[]]$Pref = @())
# (failures are checked by exit status: what native tools write on stderr is not an error; throw stops the script)
$ErrorActionPreference = 'Continue'
$WptCommit = '4ad507b28db0a636f528def9161d109fe11b93a3'
# what the tests of the measured folders load from elsewhere in WPT
$Shared = @('/resources/', '/common/', '/interfaces/', '/images/', '/fonts/', '/dom/common.js', '/dom/events/resources/',
            '/html/resources/', '/fetch/api/resources/', '/fetch/resources/', '/xhr/resources/', '/encoding/resources/',
            '/service-workers/service-worker/resources/', '/workers/support/', '/webidl/resources/')

$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\wpt'
$wpt = Join-Path $out 'wpt'
$manifest = Join-Path $root 'wpt\MANIFEST.txt'
$suitesFile = Join-Path $root 'wpt\suites.txt'
New-Item -ItemType Directory -Force $out | Out-Null

$folders = @(Get-Content $suitesFile | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { ($_.Trim() -split '\s+')[0].Trim('/') })
$patterns = @($Shared) + @($folders | ForEach-Object { "/$_/" })

function Get-TreeHashes([string]$dir) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $lines = New-Object System.Collections.Generic.List[string]
    $prefix = $dir.Length + 1
    foreach ($f in (Get-ChildItem $dir -Recurse -File -Force | Where-Object { $_.FullName -notlike "$dir\.git\*" } | Sort-Object FullName)) {
        $h = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($f.FullName))).Replace('-', '').ToLower()
        $lines.Add("$h  $($f.FullName.Substring($prefix).Replace('\', '/'))")
    }
    return $lines
}

# the checkout: a partial clone (blobs of the sparse set only), bytes as committed (no CRLF conversion)
$stamp = Join-Path $out 'CHECKOUT'
$want = "$WptCommit`n" + ($patterns -join "`n")
if (-not (Test-Path $stamp) -or [IO.File]::ReadAllText($stamp) -ne $want) {
    $env:GIT_CEILING_DIRECTORIES = $out
    if (-not (Test-Path (Join-Path $wpt '.git'))) {
        New-Item -ItemType Directory -Force $wpt | Out-Null
        git -C $wpt init -q
        git -C $wpt remote add origin https://github.com/web-platform-tests/wpt.git
    }
    git -C $wpt config core.autocrlf false
    git -C $wpt config core.eol lf
    git -C $wpt sparse-checkout init --no-cone
    [IO.File]::WriteAllText((Join-Path $wpt '.git\info\sparse-checkout'), ($patterns -join "`n") + "`n")
    "fetching web-platform-tests $WptCommit"
    git -C $wpt fetch -q --depth 1 --filter=blob:none origin $WptCommit
    if ($LASTEXITCODE -ne 0) { throw 'git fetch of the WPT commit failed' }
    git -C $wpt -c core.autocrlf=false checkout -q -f FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git checkout of the WPT commit failed' }
    # files of an earlier sparse set or converted line endings: the index decides
    git -C $wpt -c core.autocrlf=false read-tree -mu HEAD
    git -C $wpt -c core.autocrlf=false reset -q --hard HEAD
    $head = (git -C $wpt rev-parse HEAD).Trim()
    if ($head -ne $WptCommit) { throw "the checkout is at $head, not $WptCommit" }
    # verification against the pinned list
    $lines = Get-TreeHashes $wpt
    if ($UpdateManifest) {
        [IO.File]::WriteAllText($manifest, "# web-platform-tests ${WptCommit}: SHA-256 of every file fetched by tools\wpt.ps1`n" + ($lines -join "`n") + "`n")
        "wpt\MANIFEST.txt rewritten ($($lines.Count) files)"
    } else {
        if (-not (Test-Path $manifest)) { throw 'wpt\MANIFEST.txt is missing: run tools\wpt.ps1 -UpdateManifest' }
        $pinned = @(Get-Content $manifest | Where-Object { $_ -and -not $_.StartsWith('#') })
        if ((Get-Content $manifest -TotalCount 1) -notmatch $WptCommit) { throw 'wpt\MANIFEST.txt is for another commit: run tools\wpt.ps1 -UpdateManifest' }
        $diff = Compare-Object $pinned $lines
        if ($diff) {
            $diff | Select-Object -First 10 | ForEach-Object { "  $($_.SideIndicator) $($_.InputObject)" }
            throw "the WPT checkout does not match wpt\MANIFEST.txt ($(@($diff).Count) differences)"
        }
        "verified $($lines.Count) files against wpt\MANIFEST.txt"
    }
    [IO.File]::WriteAllText($stamp, $want)
} elseif ($UpdateManifest) {
    $lines = Get-TreeHashes $wpt
    [IO.File]::WriteAllText($manifest, "# web-platform-tests ${WptCommit}: SHA-256 of every file fetched by tools\wpt.ps1`n" + ($lines -join "`n") + "`n")
    "wpt\MANIFEST.txt rewritten ($($lines.Count) files)"
}
if ($Fetch) { exit 0 }

# the runner (its children are the same executable)
$exe = Join-Path $root 'build\wpt.exe'
Push-Location $root
try {
    & odin build src/tools/wpt -collection:wb=src -vet -o:speed -out:$exe "-extra-linker-flags:/STACK:33554432"
    if ($LASTEXITCODE -ne 0) { throw 'building src\tools\wpt failed' }
    if (-not $NoServer) {
        Push-Location tools\testserver
        try { & go build -o ..\..\build\testserver.exe . ; if ($LASTEXITCODE -ne 0) { throw 'building the test server failed' } } finally { Pop-Location }
    }
} finally { Pop-Location }

if ($Port -le 0) { $Port = if ($NoServer) { 8768 } else { 8778 } }
$runArgs = @('-server', "http://127.0.0.1:$Port", '-root', $wpt, '-suites', $suitesFile, '-expect', (Join-Path $root 'wpt\expectations'), '-timeout', $TimeoutMs,
             '-md', (Join-Path $out 'report.md'), '-results', (Join-Path $out 'results.txt'))
if ($Jobs -gt 0) { $runArgs += @('-jobs', $Jobs) }
if ($Quick) { $runArgs += '-quick' }
if ($Update) { $runArgs += '-update' }
if ($Only) { $runArgs += @('-only', $Only) }
foreach ($p in @($Pref | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) { $runArgs += @('--pref', $p) }

$srv = $null
try {
    if (-not $NoServer) {
        $srv = Start-Process (Join-Path $root 'build\testserver.exe') -ArgumentList '-wpt-only', '-wpt-port', $Port -PassThru -WindowStyle Hidden -WorkingDirectory $root
        Start-Sleep -Seconds 1
    }
    Push-Location $root
    try {
        & $exe @runArgs 2>$null
        $status = $LASTEXITCODE
    } finally { Pop-Location }
} finally {
    if ($srv) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
}
exit $status
