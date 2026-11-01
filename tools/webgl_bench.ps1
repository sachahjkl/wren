# What WebGL costs on this machine's GPU: examples\site\webgl-stress.html (frames, questions, pixels, uploads) and the frame rate of
# examples\site\webgl.html, with the memory of the browser and of its GPU process. A performance measure: nothing here runs on the CI.
#   powershell -NoProfile -File tools\webgl_bench.ps1 [-Exe build\wren.exe] [-Runs 3] [-Software] [-Json file]
# -Exe: another build, to compare (it may be anywhere; the pages are this tree's). -Software: webgl.force_software.
param([string]$Exe = '', [int]$Runs = 3, [switch]$Software, [string]$Json = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if ($Exe -eq '') { $Exe = Join-Path $root 'build\wren.exe' }
$Exe = (Resolve-Path $Exe).Path

$FrameRateMs = 4000         # how long the frame rate of webgl.html is counted
$SettleMs = 1500            # after the load: its first frames make pipelines
$StartTries = 60            # half-second looks for a Wren that is starting

function Ctl([string[]]$CtlArgs) {
    # (what a native tool writes on stderr is no reason to stop: the answers are looked at)
    $ErrorActionPreference = 'Continue'
    $out = & $Exe ctl --remote $script:Name @CtlArgs 2>&1 | Out-String
    return $out.Trim()
}

function Url([string]$Page) { return 'file:///' + ((Join-Path $root "examples\site\$Page") -replace '\\', '/') }

# The working sets, in MB: the browser's and that of its children (the GPU process, when it has one).
function Memory([int]$BrowserPid) {
    $browser = Get-Process -Id $BrowserPid -ErrorAction SilentlyContinue
    $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$BrowserPid" | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
    $kidMb = 0.0
    foreach ($k in $kids) { $kidMb += $k.WorkingSet64 / 1MB }
    return [ordered]@{ browserMb = [math]::Round($browser.WorkingSet64 / 1MB); childMb = [math]::Round($kidMb); children = $kids.Count }
}


$all = @()
for ($run = 0; $run -lt $Runs; $run++) {
    $script:Name = "wglb$PID$run"
    $start = @('ctl', 'start', '--name', $script:Name, '--visible', '--size', '1300x900')
    $prefs = @()
    if ($Software) { $prefs = @('--pref', 'webgl.force_software=true') }
    # (to a file: the Wren it starts stays in the background and keeps what it inherited)
    $log = Join-Path $env:TEMP "$($script:Name).log"
    & $Exe @start @prefs (Url 'about.html') *> $log
    try {
        $alive = $false
        for ($i = 0; $i -lt $StartTries -and -not $alive; $i++) {
            $alive = (Ctl @('eval', '40+2')) -eq '42'
            if (-not $alive) { Start-Sleep -Milliseconds 500 }
        }
        if (-not $alive) { throw "no Wren answers: $(Get-Content $log -Raw)" }
        $bp = [int](Get-CimInstance Win32_Process -Filter "Name='$(Split-Path $Exe -Leaf)'" | Where-Object { $_.CommandLine -like "*$($script:Name)*" } | Select-Object -First 1).ProcessId
        $r = [ordered]@{}
        $r.memNoWebGl = Memory $bp
        Ctl @('nav', (Url 'webgl.html')) | Out-Null
        Start-Sleep -Milliseconds $SettleMs
        $fps = Ctl @('eval', "new Promise(ok => { let n = 0; const s = performance.now(); const f = () => { n++; const e = performance.now() - s; if (e >= $FrameRateMs) ok(n / e * 1000); else requestAnimationFrame(f); }; requestAnimationFrame(f); })", '--await')
        $r.demoFps = [math]::Round([double]$fps, 1)
        $r.memDemo = Memory $bp
        Ctl @('nav', (Url 'webgl-stress.html')) | Out-Null
        Start-Sleep -Milliseconds $SettleMs
        $m = Ctl @('eval', 'measure()', '--await')
        ($m | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $r[$_.Name] = [math]::Round([double]$_.Value, 2) }
        $r.memStress = Memory $bp
        $all += [pscustomobject]$r
        Write-Output ("run {0}: {1}" -f $run, ($m))
    } finally {
        & $Exe ctl stop $script:Name *> $null
        Remove-Item $log -ErrorAction SilentlyContinue
    }
}

$table = [ordered]@{}
# The best of the runs: what other programs did to a run only makes it worse.
foreach ($k in 'demoFps', 'fps') { $table[$k] = (@($all | ForEach-Object { [double]$_.$k }) | Measure-Object -Maximum).Maximum }
foreach ($k in 'scriptMsPerFrame', 'firstContextMs', 'getErrorUs', 'readPixelMs', 'readCanvasMs', 'uploadMs', 'bufferMs', 'linkMs') { $table[$k] = (@($all | ForEach-Object { [double]$_.$k }) | Measure-Object -Minimum).Minimum }
foreach ($k in 'memNoWebGl', 'memDemo', 'memStress') {
    $last = $all[$all.Count - 1].$k
    $table["$k.browserMb"] = $last.browserMb
    $table["$k.childMb"] = $last.childMb
    $table["$k.children"] = $last.children
}
$table | Format-Table -AutoSize | Out-String | Write-Output
if ($Json -ne '') { $table | ConvertTo-Json | Set-Content -Encoding utf8 $Json }
