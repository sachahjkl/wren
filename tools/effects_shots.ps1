# Captures examples/site/effects.html section by section (filter, backdrop-filter, mix-blend-mode, clip-path, shadows) with the
# real browser, for a visual check. Each section is cut into its own page next to effects.html (same relative URLs),
# captured, then deleted. No test server; each capture (tools\screenshot.ps1) holds desktop.lock while its window lives.
#   powershell -File tools\effects_shots.ps1 [-OutDir build\effects_shots] [-WaitMs 3000] [-Exe wren.exe]
param([string]$OutDir = 'build\effects_shots', [int]$WaitMs = 3000)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$site = Join-Path $root 'examples\site'
$out = Join-Path $root $OutDir
New-Item -ItemType Directory -Force $out | Out-Null
$src = [IO.File]::ReadAllText((Join-Path $site 'effects.html'))
$head = $src.Substring(0, $src.IndexOf('<h2>'))
$tail = '</body></html>'
$parts = [regex]::Split($src.Substring($src.IndexOf('<h2>')).Replace('</body>', '').Replace('</html>', ''), '(?=<h2>)') | Where-Object { $_.Trim() }
$names = @('filter', 'backdrop', 'blend', 'clip', 'shadows')
for ($i = 0; $i -lt $parts.Count -and $i -lt $names.Count; $i++) {
    $page = Join-Path $site ("_shot_" + $names[$i] + '.html')
    [IO.File]::WriteAllText($page, $head + $parts[$i] + $tail)
    try {
        $url = 'file:///' + ($page -replace '\\', '/')
        & powershell -NoProfile -File (Join-Path $PSScriptRoot 'screenshot.ps1') -Url $url -Out (Join-Path $out ($names[$i] + '.png')) -WaitMs $WaitMs
    } finally { Remove-Item $page -ErrorAction SilentlyContinue }
}
& powershell -NoProfile -File (Join-Path $PSScriptRoot 'screenshot.ps1') -Url ('file:///' + ((Join-Path $site 'effects.html') -replace '\\', '/')) -Out (Join-Path $out 'page.png') -WaitMs $WaitMs
Get-ChildItem $out -Filter *.png | ForEach-Object { $_.FullName }
