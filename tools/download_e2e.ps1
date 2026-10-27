# Downloads end to end, on both network stacks: a Wren with no window shown navigates to an attachment (a navigation
# handed over to the download manager), a binary named by its URL and a slow body, and every file must land whole in
# browser.download.directory. The transport under a download (net.set_max_body, back-pressure, a long body) is what
# differs between the stacks; the result must not.
#   powershell -NoProfile -File tools\download_e2e.ps1 [-Backend rust|winhttp|both]
param([ValidateSet('rust', 'winhttp', 'both')][string]$Backend = 'both')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. (Join-Path $PSScriptRoot 'test_env.ps1')
. (Join-Path $PSScriptRoot 'wrenctl.ps1')

$failures = 0
$srv = Start-WrenTestServer
try {
    $o = "http://127.0.0.1:$($srv.BasePort)"
    $backends = if ($Backend -eq 'both') { @('rust', 'winhttp') } else { @($Backend) }
    foreach ($b in $backends) {
        $dir = Join-Path $env:TEMP "wren_download_e2e_$b`_$PID"
        if (Test-Path $dir) { [IO.Directory]::Delete($dir, $true) }
        New-Item -ItemType Directory $dir | Out-Null
        $name = Start-Wren -Pref @("network.backend=$b", 'browser.download.ask=false', "browser.download.directory=$dir")
        try {
            $want = [ordered]@{ 'att.txt' = 3145728; 'blob.bin' = 5000000; 'slow' = 1048576 }
            foreach ($u in "$o/download/attachment?bytes=3145728&name=att.txt", "$o/download/binary/blob.bin?bytes=5000000", "$o/download/slow?bytes=1048576&ms=50") {
                Wren-Ctl nav $u --wait none -TimeoutSec 30 | Out-Null
            }
            $t0 = Get-Date
            do {
                Start-Sleep -Milliseconds 200
                $done = @(Get-ChildItem $dir -File | Where-Object { $_.Name -notlike '*.wrenpart' }).Count
            } while ($done -lt $want.Count -and ((Get-Date) - $t0).TotalSeconds -lt 30)
            foreach ($k in $want.Keys) {
                $f = Get-ChildItem $dir -File | Where-Object { $_.Name -like "$k*" -and $_.Name -notlike '*.wrenpart' } | Select-Object -First 1
                $got = if ($f) { $f.Length } else { -1 }
                if ($got -eq $want[$k]) { "PASS $b`: $k whole ($got bytes)" } else { "FAIL $b`: $k has $got bytes, want $($want[$k])"; $failures++ }
            }
        } finally {
            Stop-Wren $name
            [IO.Directory]::Delete($dir, $true)
        }
    }
} finally {
    Stop-WrenTestServer $srv
}
"download_e2e: $(if ($failures -eq 0) { 'all passed' } else { "$failures failure(s)" })"
exit $failures
