# JavaScript benchmarks: Octane in Wren's engine (QuickJS-ng compiled to Wasm, under Wasmtime) against the same engine
# release compiled natively (qjs.exe of the QuickJS-ng release) and against Microsoft Edge (V8); the DOM and binding
# micro-benchmarks of examples\jsbench\dom.html in Wren (headless page) and in Edge; realm start-up and memory.
#   powershell -NoProfile -File tools\js_bench.ps1 [-Mode octane|dom|startup|all] [-Runs 3] [-Benchmarks a,b]
#       [-Engines wasm,native,edge] [-OutDir build\bench]
# Pinned inputs: Octane at commit $OctaneCommit of github.com/chromium/octane (every file by SHA-256 below), qjs.exe of
# the QuickJS-ng release the engine is built from (version from tools\build_js.ps1, SHA-256 below). Edge is the installed
# one (its version is printed). Each figure is the median of -Runs runs (a fresh realm or process each); Octane scores
# are Octane's own (higher is better, geometric mean of each benchmark's runs).
# Outputs in -OutDir: octane.md, dom.md, startup.md (Markdown tables) and the raw lines of every run (*.log).
param(
    [ValidateSet('octane', 'dom', 'startup', 'all')][string]$Mode = 'octane',
    [int]$Runs = 3,
    [string[]]$Benchmarks = @(),
    [string[]]$Engines = @('wasm', 'native', 'edge'),
    [string]$OutDir = 'build\bench',
    [int]$EdgeTimeoutSec = 900,
    [string[]]$WasmArgs = @()   # extra arguments of build\jsengine.exe bench (-jit, -jit-threshold n...)
)
$ErrorActionPreference = 'Continue'
$Benchmarks = @($Benchmarks | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Engines = @($Engines | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$WasmArgs = @($WasmArgs | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$root = Split-Path $PSScriptRoot -Parent
if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $root $OutDir }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$inv = [Globalization.CultureInfo]::InvariantCulture

$OctaneCommit = '570ad1ccfe86e3eecba0636c8f932ac08edec517'
$OctaneFiles = [ordered]@{
    'base.js' = '216612c2e7096a02b3e52b57e9cf9351bbaf180d60938d5c60b85fd756232733'
    'richards.js' = '1246a64a24b931158bf01c24640343259fa74b0226e73bad630bd1f686aa0fa7'
    'deltablue.js' = '6c4784e82f3e8f5c18306d289653d08b17b38838f1bac16b38611d7318fa5a36'
    'crypto.js' = 'b01b6b3fe534327fdef05131162927bc5508f100a3208e185d0c5a4efb200a39'
    'raytrace.js' = '64b8ff90969966dd69659100e28754976dfc3e9a4f8ee55b9232f974c66ed08c'
    'earley-boyer.js' = '8dd28a505f7e705642f86816232b012fd3c770ec8afc9f719ce89ce772dab347'
    'regexp.js' = 'a292d6047900c5296ea9e2628453832cc3bfe397e49fddade8aff7b5876c8263'
    'splay.js' = 'f9a6a60d8f205908f5542ad1180abc1902dcdab3dcb4278017c5ce179ee123f7'
    'navier-stokes.js' = '27926de809451c60b0c49a4185c08f97081310d0db166a30c1d202fb656556a2'
    'box2d.js' = '83b10c280f004e7b156a9e04d09ce4109892ea92788f7c6c963f7fadf29c7bd4'
    'code-load.js' = '32fd38d49bb8794b40e947c70c0c51276bfc2588833a8451a25b1b2bfccad96c'
    'gbemu-part1.js' = '67ae8c639b7acc5ebbcf0995c8b68821251a629f72c604e74cae8526c8e85965'
    'gbemu-part2.js' = 'acd923e085cf70fce8a15b1420d1fa489bd8315e4a8c066775aeaa7104e609d3'
    'pdfjs.js' = 'ced89e66a178a4b63a69ea33fc6f47d405bf9bd379817be25f060a4b2dcce351'
    'mandreel.js' = 'fc4a9516e8899bb33df63a69db30797959a138d33233e9fb1ccc57cb91dcd164'
    'typescript-input.js' = 'e23d2fe7b3df9dc069c720ab3fb112006c235d0eb416556ecde7c3a2766a0396'
    'typescript-compiler.js' = '9e99fe0ddfe48a2462eca622ade1e1ddd13bf49f8e461a6c53463bbbc1d5363a'
    'typescript.js' = 'fbc5ec16d9c60b1bdcca7e7b9f66fba2fe46c0e04da64088203052e47922ff21'
    'zlib-data.js' = 'b8d093321289574f36116e933e2b3b211bb98df9fe3e761ffb1be550d0e82aed'
    'zlib.js' = 'd8c4bca32e84b38f573d3ee50a38b194afc9fb4e2f79754d952524bff01a898c'
}
# Octane's order; the files of each benchmark after base.js
$Suite = [ordered]@{
    'richards' = @('richards.js'); 'deltablue' = @('deltablue.js'); 'crypto' = @('crypto.js'); 'raytrace' = @('raytrace.js')
    'earley-boyer' = @('earley-boyer.js'); 'regexp' = @('regexp.js'); 'splay' = @('splay.js'); 'navier-stokes' = @('navier-stokes.js')
    'box2d' = @('box2d.js'); 'code-load' = @('code-load.js'); 'gbemu' = @('gbemu-part1.js', 'gbemu-part2.js'); 'pdfjs' = @('pdfjs.js')
    'mandreel' = @('mandreel.js'); 'typescript' = @('typescript-input.js', 'typescript-compiler.js', 'typescript.js')
    'zlib' = @('zlib-data.js', 'zlib.js')
}
$QjsExeSha256 = '2aeabf0092c3262d6b2609824418f7dd7ed1f1df939f73b2b15645230cac0d77'   # qjs-windows-x86_64.exe

function Get-Pinned([string]$url, [string]$file, [string]$sha) {
    if ((Test-Path $file) -and (Get-FileHash $file -Algorithm SHA256).Hash -eq $sha.ToUpper()) { return }
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing -ErrorAction Stop
    $got = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($got -ne $sha.ToUpper()) { Remove-Item $file -Force; throw "SHA-256 mismatch for $url`: expected $sha, got $got" }
}

function Median([double[]]$v) {
    if ($v.Count -eq 0) { return [double]::NaN }
    $s = $v | Sort-Object
    return $s[[int][math]::Floor(($s.Count - 1) / 2)]
}

function Geomean([double[]]$v) {
    $v = @($v | Where-Object { $_ -gt 0 })
    if ($v.Count -eq 0) { return [double]::NaN }
    $l = 0.0; foreach ($x in $v) { $l += [math]::Log($x) }
    return [math]::Exp($l / $v.Count)
}

function Fmt([double]$x, [string]$f = '0') { if ([double]::IsNaN($x)) { 'n/a' } else { $x.ToString($f, $inv) } }

function Find-Edge {
    foreach ($p in "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") { if (Test-Path $p) { return $p } }
    return $null
}

# Edge headless on a page; the page writes its results in <pre id="results"> before the load event (its scripts are
# synchronous): --dump-dom prints the document once loaded. A throwaway profile, waited for and removed.
function Invoke-EdgePage([string]$page) {
    $edge = Find-Edge
    if (-not $edge) { throw 'Microsoft Edge not found' }
    $profileDir = Join-Path ([IO.Path]::GetTempPath()) "wren_bench_edge_$PID"
    $dom = Join-Path ([IO.Path]::GetTempPath()) "wren_bench_edge_$PID.html"
    $url = 'file:///' + ($page -replace '\\', '/')
    $a = @('--headless=new', '--disable-gpu', '--no-first-run', '--disable-extensions', '--allow-file-access-from-files', "--user-data-dir=$profileDir", '--dump-dom', $url)
    $p = Start-Process $edge -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardOutput $dom
    if (-not $p.WaitForExit($EdgeTimeoutSec * 1000)) { $p.Kill(); throw "Edge did not finish $page" }
    $tag = [IO.Path]::GetFileName($profileDir)
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and (Get-CimInstance Win32_Process -Filter "name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$tag*" })) { Start-Sleep -Milliseconds 300 }
    try { [IO.Directory]::Delete($profileDir, $true) } catch { }
    $html = [IO.File]::ReadAllText($dom)
    Remove-Item $dom -ErrorAction SilentlyContinue
    $m = [regex]::Match($html, '<pre id="results">([\s\S]*?)</pre>')
    if (-not $m.Success) { return '' }
    return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
}

function Edge-Version {
    $edge = Find-Edge
    if (-not $edge) { return 'not installed' }
    return (Get-Item $edge).VersionInfo.ProductVersion
}

$wasmExe = Join-Path $root 'build\jsengine.exe'
function Build-Jsengine {
    Push-Location $root
    try {
        & odin build src/tools/jsengine -collection:wb=src -vet -out:$wasmExe -o:speed "-extra-linker-flags:/STACK:33554432"
        if ($LASTEXITCODE -ne 0) { throw 'building src\tools\jsengine failed' }
    } finally { Pop-Location }
}

#########################################################################################################
# Octane

function Run-Octane {
    $dir = Join-Path $OutDir 'octane'
    foreach ($f in $OctaneFiles.Keys) {
        Get-Pinned "https://raw.githubusercontent.com/chromium/octane/$OctaneCommit/$f" (Join-Path $dir $f) $OctaneFiles[$f]
    }
    $names = if ($Benchmarks.Count) { $Benchmarks } else { @($Suite.Keys) }
    $log = Join-Path $OutDir 'octane.log'
    [IO.File]::WriteAllText($log, '')
    $scores = @{}   # engine -> name -> [double[]]
    foreach ($e in $Engines) { $scores[$e] = @{}; foreach ($n in $names) { $scores[$e][$n] = New-Object System.Collections.Generic.List[double] } }
    $runner = 'BenchmarkSuite.RunSuites({ NotifyResult: function(n, r) {}, NotifyError: function(n, e) { print("ERROR " + n + " " + e); }, NotifyScore: function(s) { print("SCORE " + s); } });'

    if ($Engines -contains 'wasm') {
        Build-Jsengine
        foreach ($n in $names) {
            # (jsengine bench: one realm per run, the median of -iterations; the runs are taken one by one here to keep them all)
            for ($i = 0; $i -lt $Runs; $i++) {
                $o = & $wasmExe bench -iterations 1 @WasmArgs $dir $n 2>&1 | ForEach-Object { "$_" }
                Add-Content $log "wasm $n $($o -join ' / ')"
                $line = $o | Where-Object { $_ -match "^$([regex]::Escape($n))\s+(\d+)\s" } | Select-Object -First 1
                if ($line -and $line -match "^\S+\s+(\d+)") { $scores['wasm'][$n].Add([double]$Matches[1]) }
            }
            Write-Host ("wasm   {0,-14} {1}" -f $n, ($scores['wasm'][$n] -join ' '))
        }
    }
    if ($Engines -contains 'native') {
        $buildJs = Get-Content (Join-Path $PSScriptRoot 'build_js.ps1') -Raw
        $qv = [regex]::Match($buildJs, "\`$QjsVersion = '([^']+)'").Groups[1].Value
        $qjs = Join-Path $root "build\tools\qjs-$qv-windows-x86_64.exe"
        Get-Pinned "https://github.com/quickjs-ng/quickjs/releases/download/v$qv/qjs-windows-x86_64.exe" $qjs $QjsExeSha256
        foreach ($n in $names) {
            $file = Join-Path $OutDir "native_$n.js"
            # (zlib's Emscripten code takes a shell without a window for d8 and assigns its read(): qjs has none)
            $text = "if (typeof read === 'undefined') { var read = function (f) { throw new Error('read() is not available: ' + f); }; }`n"
            $text += [IO.File]::ReadAllText((Join-Path $dir 'base.js'))
            foreach ($f in $Suite[$n]) { $text += "`n" + [IO.File]::ReadAllText((Join-Path $dir $f)) }
            [IO.File]::WriteAllText($file, $text + "`n" + $runner + "`n")
            for ($i = 0; $i -lt $Runs; $i++) {
                $o = & $qjs --script $file 2>&1 | ForEach-Object { "$_" }
                Add-Content $log "native $n $($o -join ' / ')"
                $line = $o | Where-Object { $_ -match '^SCORE ' } | Select-Object -Last 1
                if ($line) { $scores['native'][$n].Add([double]::Parse($line.Substring(6), $inv)) }
            }
            Write-Host ("native {0,-14} {1}" -f $n, ($scores['native'][$n] -join ' '))
        }
    }
    if ($Engines -contains 'edge') {
        foreach ($n in $names) {
            $page = Join-Path $OutDir "edge_$n.html"
            $tags = (@('base.js') + $Suite[$n] | ForEach-Object { "<script src=`"octane/$_`"></script>" }) -join "`n"
            # synchronous, like the shells: base.js steps through setTimeout only when window.setTimeout exists
            $html = "<!doctype html><meta charset=utf-8><title>Octane $n</title><pre id=`"results`"></pre>`n<script>var __st = window.setTimeout; window.setTimeout = undefined; var __out = []; function print(s) { __out.push(s); }</script>`n$tags`n<script>$runner window.setTimeout = __st; document.getElementById('results').textContent = __out.join('\n');</script>`n"
            [IO.File]::WriteAllText($page, $html)
            for ($i = 0; $i -lt $Runs; $i++) {
                $o = Invoke-EdgePage $page
                Add-Content $log "edge $n $($o -replace "`n", ' / ')"
                $line = $o -split "`n" | Where-Object { $_ -match '^SCORE ' } | Select-Object -Last 1
                if ($line) { $scores['edge'][$n].Add([double]::Parse($line.Substring(6), $inv)) }
            }
            Write-Host ("edge   {0,-14} {1}" -f $n, ($scores['edge'][$n] -join ' '))
        }
    }

    $head = '| benchmark |'; $sep = '|---|'
    foreach ($e in $Engines) { $head += " $(@{wasm='Wren (Wasm)'; native='QuickJS native'; edge='Edge (V8)'}[$e]) |"; $sep += '---:|' }
    if ($Engines -contains 'wasm' -and $Engines -contains 'native') { $head += ' Wasm / native |'; $sep += '---:|' }
    if ($Engines -contains 'wasm' -and $Engines -contains 'edge') { $head += ' Wasm / Edge |'; $sep += '---:|' }
    $md = @($head, $sep)
    $med = @{}; foreach ($e in $Engines) { $med[$e] = @{} }
    foreach ($n in $names) {
        $row = "| $n |"
        foreach ($e in $Engines) { $med[$e][$n] = Median $scores[$e][$n].ToArray(); $row += " $(Fmt $med[$e][$n]) |" }
        if ($Engines -contains 'wasm' -and $Engines -contains 'native') { $row += " $(Fmt ($med['wasm'][$n] / $med['native'][$n]) '0.00') |" }
        if ($Engines -contains 'wasm' -and $Engines -contains 'edge') { $row += " $(Fmt ($med['wasm'][$n] / $med['edge'][$n]) '0.000') |" }
        $md += $row
    }
    $row = '| **score (geometric mean)** |'
    $g = @{}
    foreach ($e in $Engines) { $g[$e] = Geomean @($names | ForEach-Object { $med[$e][$_] }); $row += " **$(Fmt $g[$e])** |" }
    if ($Engines -contains 'wasm' -and $Engines -contains 'native') { $row += " **$(Fmt ($g['wasm'] / $g['native']) '0.00')** |" }
    if ($Engines -contains 'wasm' -and $Engines -contains 'edge') { $row += " **$(Fmt ($g['wasm'] / $g['edge']) '0.000')** |" }
    $md += $row
    $md += ''
    $md += "Octane $($OctaneCommit.Substring(0, 12)), median of $Runs runs (a fresh realm or process each). Wren: build\jsengine.exe bench (worker realm, Wasmtime/Cranelift); native: qjs.exe of the QuickJS-ng release; Edge $(Edge-Version) headless. A benchmark that fails shows n/a."
    $text = $md -join "`n"
    [IO.File]::WriteAllText((Join-Path $OutDir 'octane.md'), $text + "`n")
    $text
}

#########################################################################################################
# DOM and binding micro-benchmarks (examples\jsbench\dom.html)

function Run-Dom {
    $page = Join-Path $root 'examples\jsbench\dom.html'
    $log = Join-Path $OutDir 'dom.log'
    [IO.File]::WriteAllText($log, '')
    $res = @{}   # engine -> case -> list
    $order = New-Object System.Collections.Generic.List[string]
    $collect = {
        param($engine, $text)
        foreach ($l in ($text -split "`n")) {
            if ($l -match '^CASE\t([^\t]+)\t([^\t]+)\t([^\t]*)') {
                $name = $Matches[1]; $v = $Matches[2]
                if (-not $order.Contains($name)) { $order.Add($name) }
                if (-not $res[$engine].ContainsKey($name)) { $res[$engine][$name] = New-Object System.Collections.Generic.List[string] }
                $res[$engine][$name].Add($v)
            }
        }
    }
    $engines = @($Engines | Where-Object { $_ -in 'wasm', 'edge' })
    foreach ($e in $engines) { $res[$e] = @{} }
    if ($engines -contains 'wasm') {
        $exe = Join-Path $root 'build\jspage.exe'
        Push-Location $root
        try {
            & odin build src/tools/jspage -collection:wb=src -vet -o:speed -out:$exe "-extra-linker-flags:/STACK:33554432"
            if ($LASTEXITCODE -ne 0) { throw 'building src\tools\jspage failed' }
        } finally { Pop-Location }
        for ($i = 0; $i -lt $Runs; $i++) {
            $o = (& $exe -wait 60000 -until 'DONE' ('file:///' + ($page -replace '\\', '/')) 2>&1 | ForEach-Object { "$_" }) -join "`n"
            Add-Content $log "wasm run $i`n$o"
            & $collect 'wasm' $o
        }
    }
    if ($engines -contains 'edge') {
        for ($i = 0; $i -lt $Runs; $i++) {
            $o = Invoke-EdgePage $page
            Add-Content $log "edge run $i`n$o"
            & $collect 'edge' $o
        }
    }
    $md = @('| case | Wren | Edge | Wren / Edge |', '|---|---:|---:|---:|')
    foreach ($name in $order) {
        $cells = @()
        $nums = @{}
        foreach ($e in 'wasm', 'edge') {
            $vals = if ($res.ContainsKey($e) -and $res[$e].ContainsKey($name)) { $res[$e][$name] } else { @() }
            $numeric = @($vals | Where-Object { $_ -match '^[0-9.]+$' } | ForEach-Object { [double]::Parse($_, $inv) })
            if ($numeric.Count) { $nums[$e] = Median $numeric; $cells += ((Fmt $nums[$e] '0.0') + ' ns') }
            elseif ($vals.Count) { $cells += ($vals[0] -replace '\|', '\|') }
            else { $cells += 'n/a' }
        }
        $ratio = if ($nums.ContainsKey('wasm') -and $nums.ContainsKey('edge') -and $nums['edge'] -gt 0) { Fmt ($nums['wasm'] / $nums['edge']) '0.0' } else { '' }
        $md += "| $name | $($cells[0]) | $($cells[1]) | $ratio |"
    }
    # the floor of a call from Wasm to the browser, without JavaScript (src\tools\wasmbench, Cranelift)
    Push-Location $root
    try {
        & odin build examples/wasmbench -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:build/wasmbench.wasm -o:speed
        & odin build src/tools/wasmbench -collection:wb=src -vet -o:speed -out:build/wasmbench.exe "-extra-linker-flags:/STACK:33554432"
        $wb = @(& (Join-Path $root 'build\wasmbench.exe') (Join-Path $root 'build\wasmbench.wasm') 2>$null | ForEach-Object { "$_" })
        $raw = $wb | Where-Object { $_ -match '^\| 1 M host calls \(\) \(ns/call\) \| ([0-9.]+)' } | Select-Object -First 1
        if ($raw -and $raw -match '\| ([0-9.]+) \|') { $md += "| raw call Wasm -> browser, no argument (src\tools\wasmbench) | $($Matches[1]) ns | | |" }
    } finally { Pop-Location }
    $md += ''
    $md += "Time per operation (median of $Runs runs; ns). Wren: build\jspage.exe (the page loaded as in the browser, without a window); Edge $(Edge-Version) headless. A case whose API Wren lacks shows the error it threw."
    $text = $md -join "`n"
    [IO.File]::WriteAllText((Join-Path $OutDir 'dom.md'), $text + "`n")
    $text
}

#########################################################################################################
# Realm start-up and memory

function Run-Startup {
    Build-Jsengine
    $md = @('| measure | value |', '|---|---:|')
    $o = & $wasmExe startup -n 50 2>&1 | ForEach-Object { "$_" }
    foreach ($l in $o) {
        if ($l -match '^first realm .*: ([0-9.]+) ms') { $md += "| first realm of the process (compiles or reads the code cache) | $($Matches[1]) ms |" }
        if ($l -match '^realm creation: median ([0-9.]+) ms, min ([0-9.]+) ms, max ([0-9.]+) ms over (\d+)') { $md += "| realm creation (instantiate the pre-initialized image + wj_realm_start), median of $($Matches[4]) | $($Matches[1]) ms (min $($Matches[2]), max $($Matches[3])) |" }
        if ($l -match '^private memory per realm: ([0-9.]+) KiB; JS heap of a fresh realm: ([0-9.]+) KiB') { $md += "| private memory per realm (process, 50 realms alive) | $($Matches[1]) KiB |"; $md += "| JavaScript heap of a fresh realm | $($Matches[2]) KiB |" }
    }
    $o2 = & $wasmExe startup -raw -n 10 2>&1 | ForEach-Object { "$_" }
    foreach ($l in $o2) {
        if ($l -match '^realm creation: median ([0-9.]+) ms') { $md += "| realm creation without the pre-initialized image (-raw: the engine's start-up runs per realm) | $($Matches[1]) ms |" }
    }
    $exe = Join-Path $root 'build\jspage.exe'
    Push-Location $root
    try { & odin build src/tools/jspage -collection:wb=src -vet -o:speed -out:$exe "-extra-linker-flags:/STACK:33554432" } finally { Pop-Location }
    if (Test-Path $exe) {
        $page = Join-Path $root 'examples\jsbench\startup.html'
        $o3 = (& $exe -wait 10000 -until 'DONE' -stats ('file:///' + ($page -replace '\\', '/')) 2>&1 | ForEach-Object { "$_" })
        foreach ($l in $o3) {
            if ($l -match '^STAT\tfirst_script_ms\t([0-9.]+)') { $md += "| first page of the process: from the navigation to its first script's output (fetch, parse, realm created on first use, engine code compiled or read from the cache) | $($Matches[1]) ms |" }
            if ($l -match '^STAT\tnext_page_first_script_ms\t([0-9.]+)') { $md += "| next page: the same | $($Matches[1]) ms |" }
            if ($l -match '^STAT\tjs_heap_kib\t([0-9.]+)') { $md += "| page: JavaScript heap after a small script | $($Matches[1]) KiB |" }
            if ($l -match '^STAT\tprivate_per_page_kib\t([0-9.]+)') { $md += "| page: private memory per page with a realm (20 pages alive) | $($Matches[1]) KiB |" }
        }
    }
    $md += ''
    $md += 'build\jsengine.exe startup (pre-initialized image, src\wasm\preinit.odin) and build\jspage.exe -stats (a real page).'
    $text = $md -join "`n"
    [IO.File]::WriteAllText((Join-Path $OutDir 'startup.md'), $text + "`n")
    $text
}

if ($Mode -in 'octane', 'all') { Run-Octane }
if ($Mode -in 'dom', 'all') { Run-Dom }
if ($Mode -in 'startup', 'all') { Run-Startup }
