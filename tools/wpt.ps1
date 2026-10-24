# web-platform-tests in Wren without a window: the folders of wpt\suites.txt at a pinned WPT commit, run by
# src\tools\wpt against the test server (tools\testserver\wpt.go), compared with the
# expectations of wpt\expectations.
#   powershell -NoProfile -File tools\wpt.ps1 [-Quick] [-Update] [-Only /dom/nodes/] [-Jobs n] [-TimeoutMs 10000]
#       [-Fetch] [-UpdateManifest] [-NoServer] [-Port 8778] [-Pref name=value,...] [-Edge]
# Pinned: the WPT commit below; the checkout (build\wpt\wpt, a partial sparse clone of that commit: the measured folders
# and the shared ones) is verified file by file against wpt\MANIFEST.txt (SHA-256 of every file). -UpdateManifest
# rewrites that list after a change of the commit or of the folders (and says so); -Fetch only fetches and verifies.
# The server: build\testserver.exe -wpt-only (as build\wptserver.exe) from port $Port (8778 by default), or the next free
# pair (8788, 8798...; tools\test_env.ps1): the WPT origin alone, on ports of its own, so that runs of several worktrees
# go side by side without any lock. -NoServer uses a server already running: its WPT origin is on -Port, by default
# the fourth port of the block of WREN_TEST_BASE_PORT (tools\test_all.ps1 sets it), else 8768. Subtest names that print
# the server's ports are compared under 8778 / 8779, the ports the expectations were recorded on (src\tools\wpt).
# Outputs in build\wpt: report.md (pass rates per folder), results.txt (every test and subtest), children\ (logs).
# Exit status: 1 on a regression against the expectations (not on an expected failure). -Update rewrites them (full
# run only). -Quick: a fixed sample of a few tests per folder (tools\test_all.ps1 -Quick).
# -Edge runs the same tests in Microsoft Edge headless instead (build\wpt\edge_results.txt): the reference columns of
# the table of later runs (how many subtests there are, how many Edge passes, the share of those Wren passes).
param([switch]$Quick, [switch]$Update, [string]$Only = '', [int]$Jobs = 0, [int]$TimeoutMs = 10000, [switch]$Fetch,
      [switch]$UpdateManifest, [switch]$NoServer, [int]$Port = 0, [string[]]$Pref = @(), [switch]$Edge)
# (failures are checked by exit status: what native tools write on stderr is not an error; throw stops the script)
$ErrorActionPreference = 'Continue'
$WptCommit = '4ad507b28db0a636f528def9161d109fe11b93a3'
# what the tests of the measured folders load from elsewhere in WPT
$Shared = @('/resources/', '/common/', '/interfaces/', '/images/', '/fonts/', '/dom/common.js', '/dom/events/resources/',
            '/html/resources/', '/fetch/api/resources/', '/fetch/resources/', '/xhr/resources/', '/encoding/resources/',
            '/service-workers/service-worker/resources/', '/workers/support/', '/webidl/resources/', '/dom/constants.js',
            '/trusted-types/support/', '/storage/buckets/resources/', '/loading/resources/', '/webrtc/RTCPeerConnection-helper.js',
            '/css/support/parsing-testcommon.js', '/css/support/computed-testcommon.js', '/css/support/shadow-helper.js', '/media/')

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
. (Join-Path $PSScriptRoot 'test_env.ps1')
$exe = Join-Path $root 'build\wpt.exe'
Push-Location $root
try {
    # -Quick (a sample of a few dozen tests): one module per package compiles in 5 s instead of 40 s and runs the sample as fast; the whole-program
    # build pays off on a full run (thousands of tests).
    $modules = if ($Quick) { @('-use-separate-modules') } else { @() }
    $ok = Invoke-WrenBuildIfStale $exe "wpt $($modules -join ' ')" { & odin build src/tools/wpt -collection:wb=src -vet -o:speed @modules -out:$exe "-extra-linker-flags:/STACK:33554432" }
    if (-not $ok) { throw 'building src\tools\wpt failed' }
    if (-not $NoServer) {
        Push-Location tools\testserver
        try { & go build -o ..\..\build\testserver.exe . ; if ($LASTEXITCODE -ne 0) { throw 'building the test server failed' } } finally { Pop-Location }
    }
} finally { Pop-Location }

if ($Port -le 0) { $Port = if (-not $NoServer) { 8778 } elseif ($env:WREN_TEST_BASE_PORT) { [int]$env:WREN_TEST_BASE_PORT + 3 } else { 8768 } }
$runArgs = @('-server', "http://127.0.0.1:PORT", '-root', $wpt, '-suites', $suitesFile, '-expect', (Join-Path $root 'wpt\expectations'), '-timeout', $TimeoutMs,
             '-md', (Join-Path $out 'report.md'), '-results', (Join-Path $out 'results.txt'))
# media tests call play() without a gesture (the harness of other browsers runs with autoplay allowed too)
$runArgs += @('--pref', 'media.autoplay.policy=allow-all')
if ($Jobs -gt 0) { $runArgs += @('-jobs', $Jobs) }
if ($Quick) { $runArgs += '-quick' }
if ($Update) { $runArgs += '-update' }
if ($Only) { $runArgs += @('-only', $Only) }
foreach ($p in @($Pref | ForEach-Object { $_ -split ',' } | Where-Object { $_ })) { $runArgs += @('--pref', $p) }

$edgeResults = Join-Path $out 'edge_results.txt'
if ((Test-Path $edgeResults) -and -not $Edge) { $runArgs += @('-reference', $edgeResults) }

# The reference run in Edge (-Edge): the same tests, the same server, testharnessreport.js puts its JSON in the document
# (<pre id="wren-wpt-result">), read with --dump-dom after a virtual time budget of the test's timeout. Written to
# build\wpt\edge_results.txt (the expectations' format), which later runs of Wren add to their table.
function Run-Edge([string]$server) {
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $edge) { throw 'Microsoft Edge not found' }
    $listArgs = @($runArgs | Where-Object { $_ -ne '-update' }) + @('-list')
    $tests = @(& $exe @listArgs 2>$null | Where-Object { $_ -match "`t" } | ForEach-Object { $p = $_ -split "`t"; [pscustomobject]@{ path = $p[0]; long = $p[1] -eq '1' } })
    $slots = if ($Jobs -gt 0) { $Jobs } else { [Math]::Max(1, [Environment]::ProcessorCount / 2) }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "wren_wpt_edge_$PID"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $running = @{}; $results = @{}; $next = 0; $n = 0
    # throwaway profiles and outputs, removed once Edge's helper processes let go of them
    $pending = New-Object System.Collections.Generic.List[string]
    $sweep = { foreach ($f in @($pending)) { try { if (Test-Path $f -PathType Container) { [IO.Directory]::Delete($f, $true) } elseif (Test-Path $f) { [IO.File]::Delete($f) }; $pending.Remove($f) | Out-Null } catch { } } }
    $harness = @('OK', 'ERROR', 'TIMEOUT', 'PRECONDITION_FAILED'); $sub = @('PASS', 'FAIL', 'TIMEOUT', 'NOTRUN', 'PRECONDITION_FAILED')
    $finish = {
        param($slot)
        $r = $running[$slot]
        # (Edge's helper processes inherit its standard output and may still hold the file: read it shared)
        $html = ''
        try {
            $fs = [IO.File]::Open($r.dom, 'Open', 'Read', 'ReadWrite, Delete')
            try { $html = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Close() }
        } catch { }
        $m = [regex]::Match($html, '<pre id="wren-wpt-result">([\s\S]*?)</pre>')
        $lines = New-Object System.Collections.Generic.List[string]
        $j = $null
        if ($m.Success) { try { $j = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value) | ConvertFrom-Json } catch { $j = $null } }
        if ($j) {
            $lines.Add("$($r.test.path): $($harness[[int]$j.status])")
            foreach ($t in ($j.tests | Sort-Object name -Unique)) {
                $name = ([string]$t.name).Replace('\', '\\').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
                $lines.Add("`t${name}: $($sub[[int]$t.status])")
            }
        } else {
            $lines.Add("$($r.test.path): TIMEOUT")
        }
        $results[$r.test.path] = $lines -join "`n"
        $pending.Add($r.profile); $pending.Add($r.dom)
        $running.Remove($slot)
    }
    while ($next -lt $tests.Count -or $running.Count -gt 0) {
        foreach ($slot in @($running.Keys)) {
            $r = $running[$slot]
            if ($r.process.HasExited) { & $finish $slot }
            elseif (((Get-Date) - $r.started).TotalSeconds -gt $r.limit) { try { $r.process.Kill() } catch { }; Start-Sleep -Milliseconds 200; & $finish $slot }
        }
        if ($script:srv -and $script:srv.HasExited) { throw "the WPT server stopped (build\wpt\server.log) after $n tests" }
        for ($slot = 0; $slot -lt $slots -and $next -lt $tests.Count; $slot++) {
            if ($running.ContainsKey($slot)) { continue }
            $t = $tests[$next]; $next++; $n++
            $budget = $TimeoutMs * $(if ($t.long) { 6 } else { 1 })
            $profile = Join-Path $tmp "p$n"
            $dom = Join-Path $tmp "d$n.html"
            $a = @('--headless=new', '--disable-gpu', '--no-first-run', '--disable-extensions', "--user-data-dir=$profile", "--virtual-time-budget=$budget", '--dump-dom', "$server$($t.path)")
            $proc = Start-Process $edge -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardOutput $dom
            $running[$slot] = [pscustomobject]@{ process = $proc; test = $t; dom = $dom; profile = $profile; started = Get-Date; limit = $budget / 1000 + 60 }
        }
        Write-Host -NoNewline ("`r{0}/{1}" -f ($n - $running.Count), $tests.Count)
        if ($pending.Count -gt 4 * $slots) { & $sweep }
        Start-Sleep -Milliseconds 100
    }
    $deadline = (Get-Date).AddSeconds(30)
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) { & $sweep; Start-Sleep -Milliseconds 500 }
    Write-Host ''
    $text = "# web-platform-tests in Edge $((Get-Item $edge).VersionInfo.ProductVersion) (tools\wpt.ps1 -Edge): the reference of the table`n"
    $text += (($results.Keys | Sort-Object { $_ } -CaseSensitive) | ForEach-Object { $results[$_] }) -join "`n"
    [IO.File]::WriteAllText($edgeResults, $text + "`n")
    try { [IO.Directory]::Delete($tmp, $true) } catch { }
    "Edge results: $edgeResults ($($tests.Count) tests)"
}

$srv = $null
try {
    if (-not $NoServer) {
        # a copy under its own name: what stops the shared test servers by name (other worktrees' scripts) leaves it alone
        $wptServer = Join-Path $root 'build\wptserver.exe'
        Copy-Item (Join-Path $root 'build\testserver.exe') $wptServer -Force
        $server = Start-WrenTestServer -WptOnly -BasePort $Port -Exe $wptServer -Log (Join-Path $out 'server.log')
        $srv = $server.Process
        $Port = $server.BasePort
    }
    $runArgs[1] = "http://127.0.0.1:$Port"
    Push-Location $root
    try {
        if ($Edge) {
            Run-Edge "http://127.0.0.1:$Port"
            $status = 0
        } else {
            & $exe @runArgs 2>$null
            $status = $LASTEXITCODE
        }
    } finally { Pop-Location }
} finally {
    if ($srv) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
}
exit $status
