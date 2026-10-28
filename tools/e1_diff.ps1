# E1 parity: compile one file with the QuickJS C oracle and with the Odin front-end, decode both bytecode
# streams to text and show the differences. Usage: tools\e1_diff.ps1 <file.js> [-Module]
param([Parameter(Mandatory)][string]$File, [switch]$Module)
$ErrorActionPreference = 'Stop'
$o = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle'
$judge = Join-Path (Split-Path $PSScriptRoot -Parent) 'build\e1j.exe'
$ref = Join-Path $o 'one.ref.bin'
$ours = Join-Path $o 'one.ours.bin'
Remove-Item $ref, $ours -ErrorAction SilentlyContinue
$m = if ($Module) { '-m' } else { '' }
cmd /c "`"$o\bc_dump.exe`" $m `"$File`" > `"$ref`""
& $judge ($(if ($Module) { 'emit-module' } else { 'emit' })) $File $ours
& $judge decode $ref | Out-File -Encoding utf8 (Join-Path $o 'one.ref.txt')
& $judge decode $ours | Out-File -Encoding utf8 (Join-Path $o 'one.ours.txt')
git --no-pager diff --no-index --text -U2 (Join-Path $o 'one.ref.txt') (Join-Path $o 'one.ours.txt')
