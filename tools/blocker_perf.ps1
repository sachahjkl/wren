# Loads each site with and without the content blocker in the real browser and collects the load report
# (src\browser\blocker_measure.odin) of every run: tools\blocker_perf.ps1 -Profile <dir with blocker\ lists and cache> -Out report.tsv url...
param([string]$Profile, [string]$Out = "build\blocker_perf.tsv", [int]$Runs = 2, [int]$SettleMs = 12000, [string]$Exe = "build\wren.exe", [string[]]$Urls)
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$Urls = @($Urls | ForEach-Object { $_ -split "," } | Where-Object { $_ })
Remove-Item $Out -ErrorAction SilentlyContinue
$work = Join-Path $root "build\perf_profile"
foreach ($url in $Urls) {
  for ($r = 0; $r -lt $Runs; $r++) {
    foreach ($mode in @(($r % 2), (1 - ($r % 2)))) {
      $on = $mode -eq 1
      if (Test-Path $work) { cmd /c "rmdir /s /q `"$work`"" | Out-Null }
      robocopy $Profile $work /E /NFL /NDL /NJH /NJS /NP | Out-Null
      $before = if (Test-Path $Out) { @(Get-Content $Out).Count } else { 0 }
      $env:WREN_LOAD_REPORT = (Join-Path $root $Out)
      $env:WREN_LOAD_REPORT_MS = "$SettleMs"
      $prefs = @("--profile", $work, "--pref", "blocker.update.enabled=false", "--pref", "blocker.enabled=$($on.ToString().ToLower())")
      $p = Start-Process -PassThru -FilePath (Join-Path $root $Exe) -ArgumentList ($prefs + $url)
      $deadline = (Get-Date).AddSeconds(($SettleMs / 1000) + 60)
      while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ((Test-Path $Out) -and @(Get-Content $Out).Count -gt $before) { break }
        if ($p.HasExited) { break }
      }
      if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
      Start-Sleep -Milliseconds 500
    }
  }
}
Remove-Item Env:WREN_LOAD_REPORT, Env:WREN_LOAD_REPORT_MS -ErrorAction SilentlyContinue
if (Test-Path $work) { cmd /c "rmdir /s /q `"$work`"" | Out-Null }
