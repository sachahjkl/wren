# One line per run of tools\perf.ps1, from build\perf\*.csv and *.txt.
$dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\perf'
function Pct($v, $p) { if ($v.Count -eq 0) { return 0 }; $s = $v | Sort-Object; $s[[Math]::Min($s.Count - 1, [int]($s.Count * $p / 100))] }
$rows = foreach ($csv in Get-ChildItem $dir -Filter *.csv | Sort-Object Name) {
    $d = Import-Csv $csv.FullName
    if ($d.Count -eq 0) { continue }
    $txt = Get-Content ($csv.FullName -replace '\.csv$', '.txt') -TotalCount 1
    $cpu = if ($txt -match '= ([\d\.]+) % of one core') { [double]$Matches[1] } else { 0 }
    $wall = if ($txt -match 'wall ([\d\.]+) s') { [double]$Matches[1] } else { 0 }
    $work = $d | Where-Object { [double]$_.Styles -gt 0 -or [double]$_.Layout -gt 0 -or [double]$_.Build_UI -gt 0 }
    $frame = $d | ForEach-Object { [double]$_.Frame - [double]$_.Wait }   # CPU work of the frame: everything but the vsync wait
    $gpu = $d | Where-Object { [double]$_.gpu_ms -gt 0 } | ForEach-Object { [double]$_.gpu_ms }
    [pscustomobject]@{
        run = $csv.BaseName; cpu_pct = $cpu; fps = [math]::Round($d.Count / [math]::Max($wall, 0.001), 1)
        work_mean = [math]::Round(($frame | Measure-Object -Average).Average, 2); work_p95 = [math]::Round((Pct $frame 95), 2); work_max = [math]::Round(($frame | Measure-Object -Maximum).Maximum, 1)
        styles_max = [math]::Round(($d | ForEach-Object { [double]$_.Styles } | Measure-Object -Maximum).Maximum, 1)
        layout_max = [math]::Round(($d | ForEach-Object { [double]$_.Layout } | Measure-Object -Maximum).Maximum, 1)
        paint_mean = [math]::Round(($d | ForEach-Object { [double]$_.Paint_Items } | Measure-Object -Average).Average, 2)
        submit_mean = [math]::Round(($d | ForEach-Object { [double]$_.Submit } | Measure-Object -Average).Average, 2)
        gpu_min = [math]::Round(($gpu | Measure-Object -Minimum).Minimum, 2); gpu_p10 = [math]::Round((Pct $gpu 10), 2)
        items = ($d | Select-Object -Last 1).items; insts = ($d | Select-Object -Last 1).insts; nodes = ($d | Select-Object -Last 1).elements
    }
}
$rows | Format-Table -AutoSize | Out-String -Width 250
