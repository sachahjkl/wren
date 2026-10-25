# Per-phase statistics (p50 / p95 / max, ms) of the frames of a WREN_PROF csv inside the window of its .act file.
#   powershell -File tools\prof_phases.ps1 build\rszbench\win_bottom_console_site_before_win.1 [-Cols Build_UI,UI_Draw,...]
param([Parameter(Mandatory)][string]$Prefix, [string[]]$Cols = @('Frame', 'Build_UI', 'UI_Draw', 'Paint_Items', 'Styles', 'Layout', 'Submit', 'Present', 'Wait', 'Tex_Create', 'Tex_Upload', 'gpu_ms', 'items', 'insts', 'batches'))
$Cols = @($Cols | ForEach-Object { $_ -split ',' })
$a = (Get-Content "$Prefix.act").Split(' ')
$t0 = [double]$a[0]; $t1 = [double]$a[1]
$d = @(Import-Csv "$Prefix.csv" | Where-Object { [double]$_.t_ms -ge $t0 -and ($t1 -lt 0 -or [double]$_.t_ms -le $t1) })
function Pct($v, $p) { $s = @($v | Sort-Object); $s[[Math]::Min($s.Count - 1, [Math]::Max(0, [int][Math]::Ceiling($s.Count * $p / 100) - 1))] }
"frames: $($d.Count)"
foreach ($c in $Cols) {
    $v = @($d | ForEach-Object { [double]$_.$c })
    '{0,-12} p50 {1,8:N2}  p95 {2,8:N2}  max {3,8:N2}  mean {4,8:N2}' -f $c, (Pct $v 50), (Pct $v 95), ($v | Measure-Object -Maximum).Maximum, ($v | Measure-Object -Average).Average
}
