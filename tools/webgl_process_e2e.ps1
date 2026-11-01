# The GPU process's life in the real browser (docs/js/webgl.md): a page without WebGL starts no process; the first context starts one,
# with its rights lowered; killed while a page draws, the page gets webglcontextlost and webglcontextrestored and goes on; a browser
# that is killed takes its process along. On whatever adapter the machine has (none: said, not failed).
#   powershell -NoProfile -File tools\webgl_process_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
. (Join-Path $PSScriptRoot 'test_env.ps1')
$root = Split-Path $PSScriptRoot -Parent
if ($Exe -eq '') { $Exe = Join-Path $root 'build\wren.exe' }
$Exe = (Resolve-Path $Exe).Path
$ExeName = Split-Path $Exe -Leaf
$Name = "gpue2e$PID"
$WaitSec = 60      # only ends a failing run
$HangMs = 3000     # webgl.gpu_hang_ms, so that a hung process does not take half a minute
$Restarts = 100    # (what is killed on purpose)
$script:failures = 0

function Check([string]$What, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Output "PASS $What" } else { Write-Output "FAIL $What : $Detail"; $script:failures++ }
}
function Ctl([string[]]$CtlArgs) {
    $ErrorActionPreference = 'Continue'
    return (& $Exe ctl --remote $Name @CtlArgs 2>&1 | Out-String).Trim()
}
function Eval([string]$Script) { return Ctl @('eval', $Script, '--await') }
function WaitUntil([scriptblock]$Cond) {
    $until = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $until) {
        if (& $Cond) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}
function Children([int]$Parent) { return @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Parent" | Where-Object { $_.CommandLine -like '*--wren-gpu-process=*' }) }
function Alive([int]$Id) { return $null -ne (Get-Process -Id $Id -ErrorAction SilentlyContinue) }

function FileUrl([string]$Path) { return 'file:///' + ($Path -replace '\\', '/') }

# (the pages stay in build\, overwritten by the next run)
$dir = Join-Path $root 'build\webgl_e2e'
New-Item -ItemType Directory -Force $dir | Out-Null
$log = Join-Path $dir "$Name.log"
& $Exe ctl start --name $Name --size 800x600 --pref "webgl.gpu_hang_ms=$HangMs" --pref "webgl.gpu_max_restarts=$Restarts" *> $log
try {
    if (-not (WaitUntil { (Ctl @('eval', '40+2')) -eq '42' })) { throw "no Wren answers: $(Get-Content $log -Raw)" }
    $browser = [int](Get-CimInstance Win32_Process -Filter "Name='$ExeName'" | Where-Object { $_.CommandLine -like "*$Name*" } | Select-Object -First 1).ProcessId

    $plain = Join-Path $dir 'plain.html'
    Set-Content -Encoding utf8 $plain '<!doctype html><title>plain</title><h1 id=a>no WebGL here</h1><canvas id=c></canvas><script>document.getElementById("c").getContext("2d")</script>'
    Ctl @('nav', (FileUrl $plain)) | Out-Null
    Check 'a page without WebGL runs' ((Eval 'document.querySelector(''h1'').textContent') -eq 'no WebGL here')
    Check 'a page without WebGL starts no process' (@(Children $browser).Count -eq 0)

    $file = Join-Path $dir 'gl.html'
    Set-Content -Encoding utf8 $file @'
<!doctype html><title>gl</title><canvas id=c width=64 height=64></canvas><script>
window.events = [];
const c = document.getElementById("c");
c.addEventListener("webglcontextlost", e => { events.push("lost"); e.preventDefault(); });
c.addEventListener("webglcontextrestored", () => events.push("restored"));
window.gl = c.getContext("webgl", { antialias: false });
window.has = gl !== null;
window.pixel = () => { gl.clearColor(0, 1, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT); const p = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, p); return p.join(); };
(function spin() { if (!gl.isContextLost()) { gl.clear(gl.COLOR_BUFFER_BIT); gl.drawArrays(gl.TRIANGLES, 0, 0); } requestAnimationFrame(spin); })();
</script>
'@
    $page = FileUrl $file
    Ctl @('nav', $page) | Out-Null
    if ((Eval 'String(window.has)') -ne 'true') {
        Write-Output 'no adapter here: nothing more to check'
        exit 0
    }
    Check 'the context draws' ((Eval 'pixel()') -eq '0,255,0,255')
    $kids = @(Children $browser)
    Check 'one process, started by the first context' ($kids.Count -eq 1) "found $($kids.Count)"
    $first = [int]$kids[0].ProcessId
    Check 'it is the same program' ($kids[0].ExecutablePath -eq $Exe)
    Eval 'new Promise(requestAnimationFrame).then(() => 1)' | Out-Null
    Ctl @('nav', $page) | Out-Null
    Check 'a second page has the same process' ((Eval 'pixel()') -eq '0,255,0,255' -and @(Children $browser).Count -eq 1 -and @(Children $browser)[0].ProcessId -eq $first)

    Stop-Process -Id $first -Force
    Check 'killed: webglcontextlost, then webglcontextrestored' (WaitUntil { (Eval 'events.join()') -eq 'lost,restored' }) (Eval 'events.join()')
    Check 'the browser and its page carry on' ((Eval 'document.title') -eq 'gl')
    Check 'it draws again' ((Eval 'pixel()') -eq '0,255,0,255')
    $kids = @(Children $browser)
    Check 'in a new process' ($kids.Count -eq 1 -and $kids[0].ProcessId -ne $first)
    $second = [int]$kids[0].ProcessId

    # A process that does nothing any more (suspended from outside: what a deadlock in a driver looks like from here): the page's frames
    # have work for it, and at webgl.gpu_hang_ms the watcher kills it.
    Add-Type -Namespace WrenE2e -Name Nt -MemberDefinition '[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);'
    [void][WrenE2e.Nt]::NtSuspendProcess((Get-Process -Id $second).Handle)
    Check 'suspended: killed by the watcher' (WaitUntil { -not (Alive $second) })
    Check 'the page gets its context back' (WaitUntil { (Eval 'events.join()') -eq 'lost,restored,lost,restored' }) (Eval 'events.join()')
    Check 'and draws' ((Eval 'pixel()') -eq '0,255,0,255')
    $second = [int]@(Children $browser)[0].ProcessId

    Stop-Process -Id $browser -Force
    Check 'a killed browser takes its process along' (WaitUntil { -not (Alive $second) })
} finally {
    & $Exe ctl stop $Name *> $null
}
Write-Output "$script:failures failure(s)"
exit $script:failures
