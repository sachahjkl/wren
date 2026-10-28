# E1 parity: list the manifest entries where exactly one side failed to compile, with our error message.
#   -Kind ours : we fail, the oracle compiles (default);  -Kind ref : the oracle fails, we compile.
param(
    [string]$Manifest = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle\positive.manifest',
    [string]$Ref = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle\ref2_status.txt',
    [string]$Ours = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle\ours2_status.txt',
    [ValidateSet('ours', 'ref')][string]$Kind = 'ours',
    [int]$Max = 400
)
$judge = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\e1j.exe'
$man = [IO.File]::ReadAllLines($Manifest)
$r = @{}; foreach ($l in [IO.File]::ReadAllLines($Ref)) { $p = $l -split "`t"; $r[[int]$p[0]] = $p[1] }
$o = @{}; foreach ($l in [IO.File]::ReadAllLines($Ours)) { $p = $l -split "`t"; $o[[int]$p[0]] = $p[1] }
$n = 0
for ($i = 0; $i -lt $man.Count -and $n -lt $Max; $i++) {
    $hit = if ($Kind -eq 'ours') { $o[$i] -ne 'ok' -and $r[$i] -eq 'ok' } else { $r[$i] -ne 'ok' -and $o[$i] -eq 'ok' }
    if (-not $hit) { continue }
    $n++
    $mode = $man[$i].Substring(0, 1); $path = $man[$i].Substring(2)
    $msg = & $judge ($(if ($mode -eq 'm') { 'parse-module' } else { 'parse' })) $path | Select-Object -First 1
    "$i $mode $($path -replace '^.*test262\\test\\','') :: $msg"
}
