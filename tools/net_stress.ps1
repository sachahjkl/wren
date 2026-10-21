# Network stress / correctness checks: build\fetch.exe against build\testserver.exe (tools\testserver, Go).
#   powershell -File tools\net_stress.ps1 [-SizeMB 400]
# Build first:  odin build src/tools/fetch -collection:wb=src -out:build/fetch.exe
#               cd tools\testserver; go build -o ..\..\build\testserver.exe .
param([int]$SizeMB = 400)
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'build\fetch.exe'
. (Join-Path $PSScriptRoot 'test_env.ps1')
# a server on a block of ports of its own (tools\test_env.ps1): no lock, other runs keep theirs
$srv = Start-WrenTestServer
$script:failed = 0

function Run([string]$title, [string[]]$a, [string]$expect = '', [int]$maxPeakMB = 0) {
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = ($a -join ' '); $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $peak = 0L
    $task = $p.StandardOutput.ReadToEndAsync()
    while (-not $p.HasExited) { try { $p.Refresh(); $peak = [Math]::Max($peak, $p.WorkingSet64) } catch {}; Start-Sleep -Milliseconds 10 }
    $text = $task.Result.Trim()
    $ok = $true
    if ($expect -ne '' -and $text -notmatch $expect) { $ok = $false }
    if ($maxPeakMB -gt 0 -and $peak / 1MB -gt $maxPeakMB) { $ok = $false }
    if (-not $ok) { $script:failed++ }
    "{0} {1}  (exit {2}, peak {3:N0} MB)" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $title, $p.ExitCode, ($peak / 1MB)
    if (-not $ok) { ($text -split "`n" | Select-Object -Last 8) -join "`n" }
}

try {
    $h = $srv.Origin
    Run 'hello over http' @("$h/", '--print') 'hello</h1>'
    Run 'gzip is decompressed'  @("$h/gzip", '--collect') 'done: 130000 bytes'
    Run 'redirect chain is followed' @("$h/redirect?n=4") "final=$h/\s"
    Run '404 is a response, not an error' @("$h/status/404") '404'
    Run 'POST with body and header' @("$h/echo", '--method', 'POST', '--body', 'abcdef', '--header', '"X-Test: yes"', '--print') 'POST 6 bytes, X-Test="yes"'
    Run 'self-signed https is rejected' @("https://127.0.0.1:$($srv.BasePort + 1)/") 'FAILED: secure connection failed'
    Run 'bad URL fails cleanly' @('http://') 'invalid URL'
    Run 'unreachable port fails cleanly' @('http://127.0.0.1:12345/') 'FAILED: could not connect'
    Run 'real https (example.com)' @('https://example.com/') 'done:'
    Run "stream $SizeMB MB with a slow consumer: memory stays flat" @('--slow-ms', '2', "$h/big?mb=$SizeMB") "done: $($SizeMB * 1048576) bytes" 60
    Run "collect $SizeMB MB" @('--collect', "$h/big?mb=$SizeMB") "done: $($SizeMB * 1048576) bytes"
    Run 'max-body 10 MB fails early' @('--max-body', '10000000', "$h/big?mb=$SizeMB") 'response body too large' 60
    Run 'cancel mid-stream leaves nothing in flight' @('--cancel-ms', '50', "$h/slow") 'cancel -> true, in flight now: 0'
    Run 'cancel a big download' @('--cancel-ms', '30', "$h/big?mb=$SizeMB") 'after scope close: in_flight=0' 60
    Run '200 concurrent requests' @('--many', '200', "$h/") 'pending=0 in_flight=0 failures=0'
    Run '24 queued 10 MB streams (6 per host at a time, none may time out)' @('--many', '24', '--slow-ms', '1', "$h/big?mb=10") 'pending=0 in_flight=0 failures=0' 100
} finally {
    Stop-WrenTestServer $srv
}
"failed: $script:failed"
exit $script:failed
