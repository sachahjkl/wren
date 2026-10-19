# Makes the AVIF / WebP / colour-managed test files of examples\site\media (committed: tests do not need these tools).
# Needs ImageMagick 7 (libheif + libaom for AVIF, libwebp) and FFmpeg (libaom-av1, the avif muxer) on PATH.
#   powershell -NoProfile -File tools\gen_media_fixtures.ps1
# The SVG files of that directory are written by hand. Pixel layout of "quad": 32 x 16, quadrants red (top left), lime
# (top right), blue (bottom left), white (bottom right); "a" variants have the bottom right quadrant at alpha 128.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'examples\site\media'
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'wren-media-fixtures'
New-Item -ItemType Directory -Force $out, $tmp | Out-Null
function M { & magick @args; if ($LASTEXITCODE -ne 0) { throw "magick $args" } }
function F { & ffmpeg -hide_banner -loglevel error -y @args; if ($LASTEXITCODE -ne 0) { throw "ffmpeg $args" } }

$quad = Join-Path $tmp 'quad.png'
$quada = Join-Path $tmp 'quada.png'
M -size 16x8 xc:red xc:lime +append '(' -size 16x8 xc:blue xc:white +append ')' -append "PNG24:$quad"
M $quad '(' -size 32x16 xc:white -fill gray50 -draw 'rectangle 16,8 31,15' ')' -alpha off -compose CopyOpacity -composite "PNG32:$quada"

# AVIF: 8 bits with alpha, 10 bits with alpha, 4:4:4 opaque
M $quada -quality 92 -depth 8 (Join-Path $out 'quad8a.avif')
M $quada -quality 92 -depth 10 (Join-Path $out 'quad10a.avif')
M $quad -quality 95 -define heic:chroma=444 (Join-Path $out 'quad444.avif')
# orientation: libheif writes irot / imir from the EXIF orientation it is given (RightTop: irot; TopRight: imir;
# RightBottom: both); `magick file.avif` (libheif applies them) is the reference of what must be shown
M $quad -orient RightTop -quality 95 (Join-Path $out 'rot90.avif')
M $quad -orient TopRight -quality 95 (Join-Path $out 'mirror.avif')
M $quad -orient RightBottom -quality 95 (Join-Path $out 'transverse.avif')
# Display P3 (nclx primaries 12, sRGB transfer): encoded as BT.709, then the colr box rewritten in place
$mid = Join-Path $tmp 'mid.png'
M -size 16x16 'xc:rgb(40,160,60)' "PNG24:$mid"
$p3 = Join-Path $out 'p3.avif'
M $mid -quality 100 -define heic:chroma=444 $p3
$bytes = [IO.File]::ReadAllBytes($p3)
$at = [Text.Encoding]::ASCII.GetString($bytes).IndexOf('nclx')
if ($at -lt 0) { throw 'p3.avif: no nclx colr box' }
$bytes[$at + 4] = 0; $bytes[$at + 5] = 12; $bytes[$at + 6] = 0; $bytes[$at + 7] = 13
[IO.File]::WriteAllBytes($p3, $bytes)
# animation: three 10 x 10 frames (red, blue, green), 200 ms each
foreach ($c in 'red', 'blue', 'lime') { M -size 10x10 "xc:$c" "PNG24:$(Join-Path $tmp "f_$c.png")" }
$i = 1
foreach ($c in 'red', 'blue', 'lime') { Copy-Item (Join-Path $tmp "f_$c.png") (Join-Path $tmp "g_$i.png"); $i++ }
F -framerate 5 -i (Join-Path $tmp 'g_%d.png') '-c:v' libaom-av1 -crf 10 -pix_fmt yuv420p (Join-Path $out 'anim.avif')

# WebP: lossy, lossless with alpha, animation (delays 100 / 200 / 300 ms, 3 plays)
M $quad -quality 90 (Join-Path $out 'quad-lossy.webp')
M $quada -define webp:lossless=true (Join-Path $out 'quad-lossless.webp')
M $quada -quality 90 -define webp:alpha-quality=100 (Join-Path $out 'quad-lossy-alpha.webp')
M -delay 10 (Join-Path $tmp 'f_red.png') -delay 20 (Join-Path $tmp 'f_blue.png') -delay 30 (Join-Path $tmp 'f_lime.png') -loop 3 -define webp:lossless=true (Join-Path $out 'anim.webp')

# ICC: Adobe RGB (1998) profile embedded in a JPEG and a PNG (the profile Windows ships)
$adobe = Join-Path $env:WINDIR 'System32\spool\drivers\color\AdobeRGB1998.icc'
if (Test-Path $adobe) {
    M $mid -profile $adobe -quality 95 (Join-Path $out 'adobe.jpg')
    M $mid -profile $adobe "PNG24:$(Join-Path $out 'adobe.png')"
}
Get-ChildItem $out -File | Where-Object { $_.Extension -ne '.svg' -and $_.Extension -ne '.html' } | ForEach-Object { '{0,-24} {1,7} bytes' -f $_.Name, $_.Length }
