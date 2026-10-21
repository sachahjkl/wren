# Wren's text, atlas against Slug, in the real window: each scene is captured twice (--pref text.renderer=atlas|slug) with
# tools\screenshot.ps1 and written as one image, atlas on the left and Slug on the right, plus the mean absolute pixel
# difference. Scenes: the transforms demo, the text demo, the text demo at 300 % page zoom, the tab history tree (and zoomed).
#   powershell -NoProfile -File tools\text_compare.ps1 -Out <dir> [-Only transforms,zoom300] [-Width 1400 -Height 900]
param([string]$Out = "build\textcmp", [string[]]$Only = @(), [int]$Width = 1400, [int]$Height = 900)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
Add-Type -AssemblyName System.Drawing
$site = 'file:///' + ((Join-Path $root 'examples\site') -replace '\\', '/')
New-Item -ItemType Directory -Force $Out | Out-Null
$out = (Resolve-Path $Out).Path

$zoom = ('key:Ctrl+Plus;' * 7)
$scenes = @(
    @{ n = 'transforms'; u = "$site/transforms.html"; a = 'wait:2000' }
    @{ n = 'text';       u = "$site/text.html"; a = 'wait:2000' }
    @{ n = 'zoom300';    u = "$site/text.html"; a = "wait:1500; $zoom wait:1500" }
    @{ n = 'tree';       u = "$site/about.html"; a = 'wait:1200; key:Ctrl+L; wait:300; type:about:demos; key:Enter; wait:1200; key:Ctrl+L; wait:300; type:about:config; key:Enter; wait:1200; key:Ctrl+Shift+P; wait:600; type:Tab history tree; wait:400; key:Enter; wait:1500' }
    @{ n = 'tree_zoom';  u = "$site/about.html"; a = 'wait:1200; key:Ctrl+L; wait:300; type:about:demos; key:Enter; wait:1200; key:Ctrl+L; wait:300; type:about:config; key:Enter; wait:1200; key:Ctrl+Shift+P; wait:600; type:Tab history tree; wait:400; key:Enter; wait:1500; wheel:700,450,4,ctrl; wait:1200' }
)
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Only.Count) { $scenes = $scenes | Where-Object { $Only -contains $_.n } }

foreach ($s in $scenes) {
    $files = @{}
    foreach ($mode in 'atlas', 'slug') {
        $png = Join-Path $out "$($s.n)_$mode.png"
        $acts = ($s.a + "; shot:$png")
        powershell -NoProfile -File (Join-Path $PSScriptRoot 'screenshot.ps1') -Url $s.u -Out (Join-Path $out "_first_$mode.png") -WaitMs 1500 -Width $Width -Height $Height -Extra "--pref,text.renderer=$mode" -Actions $acts | Out-Null
        $files[$mode] = $png
    }
    $a = [Drawing.Bitmap]::FromFile($files['atlas']); $b = [Drawing.Bitmap]::FromFile($files['slug'])
    $w = [Math]::Min($a.Width, $b.Width); $h = [Math]::Min($a.Height, $b.Height)
    $sum = 0.0
    $ra = New-Object Drawing.Rectangle 0, 0, $w, $h
    $da = $a.LockBits($ra, 'ReadOnly', 'Format32bppArgb'); $db = $b.LockBits($ra, 'ReadOnly', 'Format32bppArgb')
    $n = $da.Stride * $h
    $ba = New-Object byte[] $n; $bb = New-Object byte[] $n
    [Runtime.InteropServices.Marshal]::Copy($da.Scan0, $ba, 0, $n); [Runtime.InteropServices.Marshal]::Copy($db.Scan0, $bb, 0, $n)
    $a.UnlockBits($da); $b.UnlockBits($db)
    for ($i = 0; $i -lt $n; $i += 4) { $sum += ([Math]::Abs($ba[$i] - $bb[$i]) + [Math]::Abs($ba[$i + 1] - $bb[$i + 1]) + [Math]::Abs($ba[$i + 2] - $bb[$i + 2])) / 3 }
    $side = New-Object Drawing.Bitmap ($w * 2), $h
    $g = [Drawing.Graphics]::FromImage($side)
    $g.DrawImage($a, 0, 0, $w, $h); $g.DrawImage($b, $w, 0, $w, $h)
    $g.Dispose()
    $side.Save((Join-Path $out "$($s.n)_atlas_vs_slug.png"), [Drawing.Imaging.ImageFormat]::Png)
    $a.Dispose(); $b.Dispose(); $side.Dispose()
    "{0,-11} mean |difference| {1:N2} / 255  ->  {2}" -f $s.n, ($sum / ($w * $h)), (Join-Path $out "$($s.n)_atlas_vs_slug.png")
}
