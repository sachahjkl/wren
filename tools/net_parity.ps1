# Runs the subjects of the web tests (src\tools\webtests) that go through the network stack on one backend (network.backend: the
# WREN_NET_BACKEND environment variable, read by net.client_init): what proves the built-in stack (rust) does what WinHTTP did.
# tools\test_all.ps1 runs the same tests on the default backend. Uses build\web_test.exe and the guests as test_all's build steps left them.
#   powershell -NoProfile -File tools\net_parity.ps1 [-Backend rust|winhttp] [-Only name,name]
# Logs: build\parity\<backend>\<subject>.txt. Exit code: the number of subjects that failed.
param([ValidateSet('rust', 'winhttp')][string]$Backend = 'rust', [string[]]$Only)
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. (Join-Path $PSScriptRoot 'test_env.ps1')

$log = Join-Path $root "build\parity\$Backend"
New-Item -ItemType Directory -Force $log | Out-Null

$subjects = 'net', 'policy', 'cache', 'page', 'netapi', 'wsclose', 'webapi', 'workers', 'jsload', 'frames', 'jsweb'
if ($Only) {
    $names = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # (powershell -File passes "a,b" as one string)
    $subjects = @($subjects | Where-Object { $names -contains $_ })
}

$failed = 0
$env:WREN_NET_BACKEND = $Backend
try {
    foreach ($s in $subjects) {
        $out = Join-Path $log "$s.txt"
        $t0 = Get-Date
        $text = Invoke-WrenWebTests 'build\web_test.exe' $s | Out-String
        $pass = $LASTEXITCODE -eq 0
        [IO.File]::WriteAllText($out, $text)
        if (-not $pass) { $failed++ }
        '{0,-12} {1,-5} {2,6:n1} s  {3}' -f $s, $(if ($pass) { 'ok' } else { 'FAIL' }), ((Get-Date) - $t0).TotalSeconds, $out
    }
} finally {
    Remove-Item Env:\WREN_NET_BACKEND
}
"backend $Backend : $failed subject(s) failed"
exit $failed
