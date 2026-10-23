# Lists the texts the code passes to the i18n package (tr, trc, trn), and the strings of the user interface that do not go
# through it yet.
#   powershell -NoProfile -File tools\i18n_list.ps1            a summary and the texts per file
#   powershell -NoProfile -File tools\i18n_list.ps1 -Missing   the user interface calls with a literal text that bypass tr
#   powershell -NoProfile -File tools\i18n_list.ps1 -Json out.json   the texts as JSON: { text, context, file, line }
# The extraction is a pattern match on the call sites, not a parse: a text built over several lines or by a call of its own
# is missed (keep each text one literal in the call). Wren's own code is src\; the toolkit's strings are its own.
param([switch]$Missing, [string]$Json = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$files = Get-ChildItem src -Recurse -Filter *.odin | Where-Object { $_.Name -notmatch '_test\.odin$' -and $_.FullName -notmatch '\\src\\i18n\\' }

if ($Missing) {
    # a text in a user interface call that does not go through tr: ui.label("Back"), ui.button("Reload"), ...
    $pat = 'ui\.(label|button|text|checkbox|toggle|menu_item|menu_heading|tab|tooltip\w*|heading|title|set_tooltip)\w*\(\s*"([^"]+)"'
    $n = 0
    foreach ($f in $files) {
        $i = 0
        foreach ($line in [IO.File]::ReadLines($f.FullName)) {
            $i++
            $m = [regex]::Match($line, $pat)
            if ($m.Success -and $line -notmatch 'i18n\.tr|\btr\(') { "{0}:{1}: {2}" -f $f.FullName.Replace("$root\", ''), $i, $m.Groups[2].Value; $n++ }
        }
    }
    "$n interface texts bypass tr"
    return
}

$found = foreach ($f in $files) {
    $i = 0
    foreach ($line in [IO.File]::ReadLines($f.FullName)) {
        $i++
        foreach ($m in [regex]::Matches($line, '(?<![A-Za-z0-9_])(?:i18n\.)?(tr|trc|trn)\(\s*(?:\d+\s*,\s*|"([^"]*)"\s*,\s*)?"([^"]*)"')) {
            $kind = $m.Groups[1].Value
            [pscustomobject]@{ text = $m.Groups[3].Value; context = $(if ($kind -eq 'trc') { $m.Groups[2].Value } else { '' }); file = $f.FullName.Replace("$root\", ''); line = $i }
        }
    }
}
if ($Json) { $found | ConvertTo-Json | Set-Content $Json -Encoding UTF8; "wrote $Json ($(@($found).Count) texts)"; return }
"$(@($found).Count) texts in $(@($found | Select-Object -ExpandProperty file -Unique).Count) files"
$found | Group-Object file | Sort-Object Count -Descending | ForEach-Object { "{0,4}  {1}" -f $_.Count, $_.Name }
