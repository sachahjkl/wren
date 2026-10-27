# Writes the notes of a release: docs\releases\<tag>.md when it exists (the highlights, written by hand), the version's
# section of CHANGELOG.md when there is one, then the changes since the previous version tag, generated from the first-parent history (merges of feature branches and
# direct commits, one line each).
#   powershell -NoProfile -File tools\release_notes.ps1 -Tag v0.2.0 [-Ref HEAD] [-Out build\dist\NOTES.md]
# -Ref: the commit the tag is (or will be) on, to preview the notes before tagging (default: the tag itself).
# A change line is the commit's subject up to its first sentence (subjects carry their details after "(" or "; "),
# and merges of master (or main, the old name) back into a branch are left out: they repeat changes already listed.
# The body of a GitHub release is at most 125 000 characters (a longer one is refused with HTTP 422: it stopped the release of
# 0.4.0, whose notes were 185 000): -Limit (120 000) keeps what fits, in this order: the highlights, the CHANGELOG section, the
# list of changes; a part that does not fit whole is replaced by a line that says where to read it.
param([Parameter(Mandatory)][string]$Tag, [string]$Ref = '', [string]$Out = '', [int]$MaxLine = 200, [int]$Limit = 120000)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (-not $Ref) { $Ref = $Tag }

$intro = ''
$introFile = Join-Path $root "docs\releases\$Tag.md"
if (Test-Path $introFile) { $intro = [IO.File]::ReadAllText($introFile).TrimEnd() + "`n`n" }

# what CHANGELOG.md says of the version (assembled from changelog.d by tools\changelog.ps1 -Assemble -Version)
$changelog = ''
$section = Join-Path ([IO.Path]::GetTempPath()) "wren-notes-$([guid]::NewGuid().ToString('N')).md"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'changelog.ps1') -Section -Version ($Tag -replace '^v', '') -Out $section | Out-Null
if ($LASTEXITCODE -eq 0 -and (Test-Path $section)) {
    $s = [IO.File]::ReadAllText($section).Trim()
    if ($s) { $changelog = $s + "`n`n" }
}
Remove-Item $section -ErrorAction SilentlyContinue

$ErrorActionPreference = 'Continue'   # no earlier tag is a normal case: git's message on stderr must not stop the script
$prev = (& git describe --tags --abbrev=0 --match 'v*' "$Ref^" 2>$null)
$found = $LASTEXITCODE -eq 0 -and $prev
$ErrorActionPreference = 'Stop'
$range = if ($found) { "$prev..$Ref" } else { $Ref }
$subjects = & git log --first-parent --reverse --format=%s $range
if ($LASTEXITCODE -ne 0) { throw "git log $range failed" }

function Shorten([string]$s) {
    $s = $s -replace '^Merge (branch )?''?[\w./-]+''?: ', ''   # a merge's subject says what the branch brings
    $cut = $s.Length
    foreach ($sep in ' (', '; ') { $i = $s.IndexOf($sep); if ($i -ge 40 -and $i -lt $cut) { $cut = $i } }
    $s = $s.Substring(0, $cut).TrimEnd(' ', ',', ':')
    if ($s.Length -gt $MaxLine) {
        $i = $s.LastIndexOf(' ', $MaxLine)
        $s = $s.Substring(0, $(if ($i -gt 0) { $i } else { $MaxLine })).TrimEnd(' ', ',', ':') + ' ' + [char]0x2026
    }
    return $s
}

$title = if ($range -eq $Ref) { 'Changes (the whole history)' } else { "Changes since $prev" }
$lines = New-Object Collections.Generic.List[string]
$lines.Add("<details><summary>$title</summary>")
$lines.Add('')
foreach ($s in $subjects) {
    if ($s -match "^Merge (remote-tracking )?branch '?(origin/)?(main|master)'? into ") { continue }
    $lines.Add("- $(Shorten $s)")
}
$lines.Add('')
$lines.Add('</details>')
$history = ($lines -join "`n") + "`n"

$text = $intro
if (($text + $changelog).Length -le $Limit) {
    $text += $changelog
} elseif ($changelog) {
    $text += "The full list of what this version changes is in [CHANGELOG.md](https://github.com/sachahjkl/wren/blob/$Tag/CHANGELOG.md): too long for these notes.`n`n"
}
if (($text + $history).Length -le $Limit) {
    $text += $history
} else {
    $text += "The changes since $prev are in the history of the repository (``git log --first-parent $range``): too long for these notes.`n"
}
if ($text.Length -gt $Limit) {   # (the highlights alone are too long: cut at a line)
    $cut = $text.LastIndexOf("`n", $Limit - 200)
    $text = $text.Substring(0, $cut) + "`n`n(cut here)`n"
}
if ($Out) { New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null; [IO.File]::WriteAllText($Out, $text) } else { $text }
