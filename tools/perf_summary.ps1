# One line per run of tools\perf.ps1, from build\perf\*.csv and *.txt.
#   powershell -File tools\perf_summary.ps1 [-Filter 'p10k_*'] [-Budget]
# -Budget: the frame pacing view: each frame's CPU work (the frame without its wait for the screen) and GPU time against
# the budget it was made with (1000 / target rate, the budget_ms column), missed refreshes and input -> screen latency
# (the report's "on screen" line).
param([string]$Filter = '*', [switch]$Budget)
$dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\perf'
function Pct($v, $p) { if ($v.Count -eq 0) { return 0 }; $s = $v | Sort-Object; $s[[Math]::Min($s.Count - 1, [Math]::Max(0, [int][Math]::Ceiling($s.Count * $p / 100) - 1))] }
function Rnd($x, $n = 2) { [math]::Round([double]$x, $n) }
$rows = foreach ($csv in Get-ChildItem $dir -Filter "$Filter.csv" | Where-Object { $_.Name -notlike '*.shown.csv' } | Sort-Object Name) {
    $d = Import-Csv $csv.FullName
    if ($d.Count -eq 0) { continue }
    # -Budget: only the frames of the input (perf.ps1 Mark), not the load before it
    $actFile = $csv.FullName -replace '\.csv$', '.act'
    $act = if ($Budget -and (Test-Path $actFile)) { [double](Get-Content $actFile) } else { -1 }
    if ($act -ge 0) { $d = @($d | Where-Object { [double]$_.t_ms -ge $act }); if ($d.Count -eq 0) { continue } }
    $lines = Get-Content ($csv.FullName -replace '\.csv$', '.txt') -TotalCount 6
    $txt = $lines[0]
    $cpu = if ($txt -match '= ([\d\.]+) % of one core') { [double]$Matches[1] } else { 0 }
    $wall = if ($txt -match 'wall ([\d\.]+) s') { [double]$Matches[1] } else { 0 }
    $frame = $d | ForEach-Object { [double]$_.Frame - [double]$_.Wait }   # CPU work of the frame: everything but the vsync wait
    $gpu = @($d | Where-Object { [double]$_.gpu_ms -gt 0 } | ForEach-Object { [double]$_.gpu_ms })
    if ($Budget) {
        # CPU work: without the wait for the screen nor Present (which only blocks when the compositor still holds the
        # previous frame: waiting too)
        $frame = $d | ForEach-Object { [double]$_.Frame - [double]$_.Wait - [double]$_.Present }
        $pres = $d | ForEach-Object { [double]$_.Present }
        $hasBudget = $d[0].PSObject.Properties.Name -contains 'budget_ms'
        $b = if ($hasBudget) { [double]$d[0].budget_ms } else { 1000.0 / 60 }
        $over = @($d | Where-Object { ([double]$_.Frame - [double]$_.Wait - [double]$_.Present) -gt $(if ($hasBudget) { [double]$_.budget_ms } else { $b }) }).Count
        $gover = @($gpu | Where-Object { $_ -gt $b }).Count
        $shownFile = $csv.FullName -replace '\.csv$', '.shown.csv'
        $shown = 0; $missed = 0; $lat = '-'
        if (Test-Path $shownFile) {
            $sh = @(Import-Csv $shownFile | Where-Object { [double]$_.t_ms -ge $act })
            $shown = $sh.Count
            $missed = ($sh | ForEach-Object { [int]$_.missed } | Measure-Object -Sum).Sum
            $lv = @($sh | Where-Object { [double]$_.latency_ms -ge 0 } | ForEach-Object { [double]$_.latency_ms })
            if ($lv.Count -gt 0) { $lat = "$(Rnd ($lv | Measure-Object -Average).Average 1) / $(Rnd (Pct $lv 95) 1)" }
        }
        $hz = if (($lines -join "`n") -match 'target ([\d\.]+) Hz') { Rnd $Matches[1] 1 } else { '' }
        $span = ([double]$d[$d.Count - 1].t_ms - [double]$d[0].t_ms) / 1000
        [pscustomobject]@{
            run = $csv.BaseName; hz = $hz; budget = Rnd $b; fps = Rnd ($d.Count / [math]::Max($span, 0.001)) 1
            cpu_p50 = Rnd (Pct $frame 50); cpu_p95 = Rnd (Pct $frame 95); cpu_p99 = Rnd (Pct $frame 99); cpu_max = Rnd ($frame | Measure-Object -Maximum).Maximum 1
            over = "$over/$($d.Count)"; present_p99 = Rnd (Pct $pres 99)
            gpu_p50 = Rnd (Pct $gpu 50); gpu_p95 = Rnd (Pct $gpu 95); gpu_p99 = Rnd (Pct $gpu 99); gpu_over = "$gover/$($gpu.Count)"
            shown = $shown; missed = $missed; 'lat_mean/p95' = $lat
        }
        continue
    }
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
$props = if ($rows) { @($rows)[0].PSObject.Properties.Name } else { @() }
$rows | Format-Table -Property $props -AutoSize | Out-String -Width 400
