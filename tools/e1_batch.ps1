# E1 parity: compile every manifest entry with the Odin front-end (build\e1_judge.exe batch), in chunks, with a
# watchdog: a chunk that crashes or stalls is re-run one file at a time so each culprit is recorded as
# "crash" / "hang" instead of stopping the run. Writes <OutDir>\<idx>.bin and <Status> ("idx<TAB>status<TAB>len").
param(
    [string]$Manifest = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle\positive.manifest',
    [string]$OutDir = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle\ours2',
    [string]$Status = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle\ours2_status.txt',
    [int]$Chunk = 1000,
    [int]$ChunkTimeoutSec = 240,
    [int]$FileTimeoutSec = 15
)
$ErrorActionPreference = 'Stop'
$judge = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\e1_judge.exe'
if (Test-Path $OutDir) { Get-ChildItem $OutDir -Filter *.bin | Remove-Item -Force } else { New-Item -ItemType Directory $OutDir | Out-Null }
$total = ([IO.File]::ReadAllLines($Manifest)).Count
$tmp = Join-Path $env:TEMP "e1_chunk_$PID.txt"
$all = [System.Collections.Generic.List[string]]::new()

function Run-Range([int]$start, [int]$count, [int]$timeoutSec) {
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $judge -ArgumentList 'batch', "`"$Manifest`"", "`"$OutDir`"", $start, $count -NoNewWindow -PassThru -RedirectStandardOutput $tmp
    $ok = $p.WaitForExit($timeoutSec * 1000)
    if (-not $ok) { $p.Kill(); $p.WaitForExit(); return @{ ok = $false; why = 'hang'; lines = @() } }
    $lines = if (Test-Path $tmp) { [IO.File]::ReadAllLines($tmp) } else { @() }
    return @{ ok = ($p.ExitCode -eq 0); why = 'crash'; lines = $lines }
}

for ($s = 0; $s -lt $total; $s += $Chunk) {
    $n = [Math]::Min($Chunk, $total - $s)
    $r = Run-Range $s $n $ChunkTimeoutSec
    if ($r.ok -and $r.lines.Count -eq $n) { $all.AddRange([string[]]$r.lines); continue }
    for ($i = $s; $i -lt $s + $n; $i++) {
        $r1 = Run-Range $i 1 $FileTimeoutSec
        if ($r1.ok -and $r1.lines.Count -eq 1) { $all.Add($r1.lines[0]) } else { $all.Add("$i`t$($r1.why)`t0"); Remove-Item (Join-Path $OutDir "$i.bin") -ErrorAction SilentlyContinue }
    }
}
[IO.File]::WriteAllLines($Status, $all)
$all | ForEach-Object { ($_ -split "`t")[1] } | Group-Object | ForEach-Object { "$($_.Name) $($_.Count)" }
