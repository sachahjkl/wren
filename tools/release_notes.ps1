# Writes the notes of a release: docs\releases\<tag>.md when it exists (the highlights, written by hand), then the
# changes since the previous version tag, generated from the first-parent history (merges of feature branches and
# direct commits, one line each).
#   powershell -NoProfile -File tools\release_notes.ps1 -Tag v0.1.0 [-Out build\dist\NOTES.md]
param([Parameter(Mandatory)][string]$Tag, [string]$Out = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$notes = New-Object Collections.Generic.List[string]
$intro = Join-Path $root "docs\releases\$Tag.md"
if (Test-Path $intro) { $notes.Add([IO.File]::ReadAllText($intro).TrimEnd()); $notes.Add('') }

$ErrorActionPreference = 'Continue'   # no earlier tag is a normal case: git's message on stderr must not stop the script
$prev = (& git describe --tags --abbrev=0 --match 'v*' "$Tag^" 2>$null)
$found = $LASTEXITCODE -eq 0 -and $prev
$ErrorActionPreference = 'Stop'
$range = if ($found) { "$prev..$Tag" } else { $Tag }
$subjects = & git log --first-parent --reverse --format=%s $range
if ($LASTEXITCODE -ne 0) { throw "git log $range failed" }
$title = if ($range -eq $Tag) { 'Changes (the whole history)' } else { "Changes since $prev" }
$notes.Add("<details><summary>$title</summary>")
$notes.Add('')
foreach ($s in $subjects) { $notes.Add("- $s") }
$notes.Add('')
$notes.Add('</details>')

$text = ($notes -join "`n") + "`n"
if ($Out) { New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null; [IO.File]::WriteAllText($Out, $text) } else { $text }
