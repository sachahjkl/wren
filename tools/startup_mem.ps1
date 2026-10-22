# Start-up time and memory of one or more builds of the browser, for comparing render backends.
#   powershell -File tools\startup_mem.ps1 [-Exes browser_prof.exe,browser_prof_wgpu.exe] [-Runs 5] [-Url about:home] [-SettleMs 6000]
# Per run: time from the process start to the first present (TOOLKIT_RENDER_TRACE), then after the settle time the
# working set, the private bytes and the GPU memory of the process (the "GPU Process Memory" performance counter). The binary's
# size and the DLLs next to it are listed too. Medians over the runs.
param([string[]]$Exes = @('browser_prof.exe', 'browser_prof_wgpu.exe'), [int]$Runs = 5, [string]$Url = 'about:home', [int]$SettleMs = 6000)
$ErrorActionPreference = 'Stop'
$Exes = @($Exes | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test_env.ps1')
function Median($v) { $s = @($v | Sort-Object); if ($s.Count -eq 0) { return 0 }; $s[[int][Math]::Floor(($s.Count - 1) / 2)] }
$rows = foreach ($name in $Exes) {
	$exe = Join-Path $root "build\$name"
	$first = @(); $ws = @(); $priv = @(); $gpu = @()
	for ($i = 0; $i -lt $Runs; $i++) {
		$bench = Enter-WrenLock bench "startup_mem.ps1 $name"
		$err = Join-Path $root 'build\startup.err'
		$env:TOOLKIT_RENDER_TRACE = '1'
		try {
			$p = Start-Process $exe -ArgumentList $Url -PassThru -RedirectStandardError $err -RedirectStandardOutput (Join-Path $root 'build\startup.out')
			Start-Sleep -Milliseconds $SettleMs
			$p.Refresh()
			$ws += $p.WorkingSet64 / 1MB; $priv += $p.PrivateMemorySize64 / 1MB
			try {
				$c = Get-Counter "\GPU Process Memory(pid_$($p.Id)*)\Dedicated Usage" -ErrorAction Stop
				$gpu += ($c.CounterSamples | Measure-Object CookedValue -Sum).Sum / 1MB
			} catch { }
			$p.Kill(); $p.WaitForExit(5000) | Out-Null
		} finally { Remove-Item Env:TOOLKIT_RENDER_TRACE -ErrorAction SilentlyContinue; Exit-WrenLock $bench }
		$m = Select-String -Path $err -Pattern 'first present ([\d\.]+) ms' | Select-Object -First 1
		if ($m) { $first += [double]$m.Matches[0].Groups[1].Value }
	}
	$dir = Split-Path $exe
	$dlls = (Get-ChildItem $dir -Filter '*.dll' | Where-Object { $_.Name -in 'wgpu_native.dll', 'dxcompiler.dll', 'dxil.dll' } | ForEach-Object { '{0} {1:N1} MB' -f $_.Name, ($_.Length / 1MB) }) -join ', '
	[pscustomobject]@{
		exe = $name; size_MB = [math]::Round((Get-Item $exe).Length / 1MB, 2)
		first_present_ms = [math]::Round((Median $first), 0); working_set_MB = [math]::Round((Median $ws), 0); private_MB = [math]::Round((Median $priv), 0)
		gpu_MB = if ($gpu.Count) { [math]::Round((Median $gpu), 0) } else { '' }; runs = $first.Count
	}
}
$rows | Format-Table -AutoSize | Out-String -Width 200
