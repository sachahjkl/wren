# Makes the pages and images tools\perf.ps1 uses to measure what the GPU should do: big photos (JPEG / PNG / WebP / AVIF),
# many thumbnails, SVG icons (inline and <img>), CSS paint effects (gradients, shadows, radius, borders, clip-path).
#   powershell -NoProfile -File tools\gpu_corpus.ps1 [-Force]
# Output: build\perf\gpu\ (not committed). Needs ImageMagick 7 (magick) on PATH, like tools\gen_media_fixtures.ps1.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\perf\gpu'
New-Item -ItemType Directory -Force $out | Out-Null
function M { & magick @args; if ($LASTEXITCODE -ne 0) { throw "magick $args" } }
function Need($name) { $p = Join-Path $out $name; if ((Test-Path $p) -and -not $Force) { return $null }; return $p }

# ---- photos: plasma + noise looks like a photo for the codecs (it does not compress to nothing) ----
for ($i = 1; $i -le 6; $i++) {
    $p = Need "photo$i.jpg"
    if ($p) { M -seed $i -size 4000x3000 plasma:fractal -blur 0x1.5 +noise Gaussian -attenuate 0.15 -quality 88 $p }
}
$p = Need 'photo_big.png';   if ($p) { M (Join-Path $out 'photo1.jpg') -resize 3000x2250 "PNG24:$p" }
$p = Need 'photo_big.webp';  if ($p) { M (Join-Path $out 'photo2.jpg') -resize 3000x2250 -quality 80 $p }
$p = Need 'photo_big.avif';  if ($p) { M (Join-Path $out 'photo3.jpg') -resize 2000x1500 -quality 60 $p }
$p = Need 'photo_alpha.png'; if ($p) { M (Join-Path $out 'photo2.jpg') -resize 2000x1500 -alpha set -channel A -evaluate set 70% +channel "PNG32:$p" }
$p = Need 'photo_adobe.jpg'; if ($p) { M (Join-Path $out 'photo1.jpg') -resize 3000x2250 -profile 'C:\Windows\System32\spool\drivers\color\AdobeRGB1998.icc' -quality 88 $p }
# a screenshot-like PNG (flat areas, text): what PNG filters are good at
$p = Need 'shot.png'
if ($p) { M -size 1920x1080 gradient:'#223-#88a' -font Arial -pointsize 28 -fill white -annotate +40+80 'Screenshot-like PNG with flat areas and text' -fill '#fc3' -draw 'roundrectangle 100,200 900,700 24,24' -fill '#235' -draw 'rectangle 960,200 1800,900' "PNG24:$p" }
# thumbnails
for ($i = 1; $i -le 40; $i++) {
    $p = Need ("thumb{0:00}.jpg" -f $i)
    if ($p) { M -seed (100 + $i) -size 800x600 plasma:fractal -blur 0x1 +noise Gaussian -attenuate 0.1 -quality 82 $p }
}

# ---- SVG icons: paths, gradients, masks, a filter (what GitHub / froment.software icons look like) ----
$icons = @(
  '<path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/>',
  '<path d="M8 .25a.75.75 0 01.673.418l1.882 3.815 4.21.612a.75.75 0 01.416 1.279l-3.046 2.97.719 4.192a.75.75 0 01-1.088.791L8 12.347l-3.766 1.98a.75.75 0 01-1.088-.79l.72-4.194L.818 6.374a.75.75 0 01.416-1.28l4.21-.611L7.327.668A.75.75 0 018 .25z"/>',
  '<path d="M1.5 8a6.5 6.5 0 1113 0 6.5 6.5 0 01-13 0zM8 0a8 8 0 100 16A8 8 0 008 0zm.5 4.75a.75.75 0 00-1.5 0v3.5a.75.75 0 00.471.696l2.5 1a.75.75 0 00.557-1.392L8.5 7.742V4.75z"/>',
  '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f90"/><stop offset="1" stop-color="#e0f"/></linearGradient></defs><circle cx="8" cy="8" r="7" fill="url(#g)"/><path d="M4 8l3 3 5-6" stroke="#fff" stroke-width="1.6" fill="none" stroke-linecap="round"/>',
  '<defs><radialGradient id="r"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#36f"/></radialGradient><mask id="m"><rect width="16" height="16" fill="#fff"/><circle cx="11" cy="5" r="3" fill="#000"/></mask></defs><rect width="16" height="16" rx="3" fill="url(#r)" mask="url(#m)"/>',
  '<defs><filter id="f"><feGaussianBlur stdDeviation="0.8"/></filter></defs><circle cx="8" cy="8" r="5" fill="#2a8" filter="url(#f)"/><circle cx="8" cy="8" r="3" fill="#fff" fill-opacity=".8"/>'
)
$sb = New-Object Text.StringBuilder
for ($i = 0; $i -lt $icons.Count; $i++) {
    $f = Need "icon$i.svg"
    if ($f) { [IO.File]::WriteAllText($f, "<svg xmlns=`"http://www.w3.org/2000/svg`" viewBox=`"0 0 16 16`" width=`"16`" height=`"16`" fill=`"#24292f`">$($icons[$i])</svg>") }
}

# ---- pages ----
function Page($name, $head, $body) {
    $p = Join-Path $out $name
    if ((Test-Path $p) -and -not $Force) { return }
    [IO.File]::WriteAllText($p, "<!doctype html><html><head><meta charset=utf-8><title>$name</title><style>body{margin:0;font:15px sans-serif;background:#f4f6fb}$head</style></head><body>$body</body></html>")
}
# gallery_big: 6 x 12 MP JPEG + big PNG / WebP / AVIF + screenshot, shown 420 px wide
$s = New-Object Text.StringBuilder
foreach ($n in 'photo1.jpg', 'photo2.jpg', 'photo3.jpg', 'photo4.jpg', 'photo5.jpg', 'photo6.jpg', 'photo_big.png', 'photo_big.webp', 'photo_big.avif', 'shot.png') { [void]$s.Append("<img src='$n'>") }
Page 'gallery_big.html' 'img{width:420px;margin:8px;vertical-align:top}' $s.ToString()
# alpha_big: translucent PNGs (premultiplied on upload) and a colour-managed JPEG, shown 800 px wide
$s = New-Object Text.StringBuilder
for ($i = 0; $i -lt 6; $i++) { [void]$s.Append("<img src='photo_alpha.png?$i'>") }
[void]$s.Append("<img src='photo_adobe.jpg'>")
Page 'alpha_big.html' 'img{width:800px;margin:8px;vertical-align:top;background:#ccd}' $s.ToString()
# gallery_many: 160 thumbnails (40 files, each four times with a different size)
$s = New-Object Text.StringBuilder
for ($i = 0; $i -lt 160; $i++) { [void]$s.Append(("<img src='thumb{0:00}.jpg' loading=eager style='width:{1}px'>" -f (($i % 40) + 1), (150 + ($i % 4) * 30))) }
Page 'gallery_many.html' 'img{margin:6px;vertical-align:top;border-radius:6px}' $s.ToString()
# gallery_tall: 40 photos one under the other (a long page of images: fast scroll)
$s = New-Object Text.StringBuilder
for ($i = 0; $i -lt 40; $i++) { [void]$s.Append(("<img src='thumb{0:00}.jpg' loading=eager>" -f (($i % 40) + 1))) }
Page 'gallery_tall.html' 'img{display:block;width:900px;margin:16px auto;border-radius:10px;box-shadow:0 8px 24px #0004}' $s.ToString()
# svg_icons: 600 inline icons and 400 <img> icons, two sizes
$s = New-Object Text.StringBuilder
for ($i = 0; $i -lt 600; $i++) { $k = $i % $icons.Count; [void]$s.Append("<svg viewBox='0 0 16 16' width='$(20 + ($i % 3) * 8)' height='$(20 + ($i % 3) * 8)' fill='#24292f'>$($icons[$k].Replace('id="g"', "id='g$i'").Replace('url(#g)', "url(#g$i)").Replace('id="r"', "id='r$i'").Replace('url(#r)', "url(#r$i)").Replace('id="m"', "id='m$i'").Replace('url(#m)', "url(#m$i)").Replace('id="f"', "id='f$i'").Replace('url(#f)', "url(#f$i)"))</svg>") }
for ($i = 0; $i -lt 400; $i++) { [void]$s.Append("<img src='icon$($i % $icons.Count).svg' width='$(24 + ($i % 4) * 12)' height='$(24 + ($i % 4) * 12)'>") }
Page 'svg_icons.html' 'svg,img{margin:4px;vertical-align:middle}' $s.ToString()
# css_fx: 300 cards with every cheap-looking paint effect
$s = New-Object Text.StringBuilder
for ($i = 0; $i -lt 300; $i++) {
    $h = ($i * 37) % 360
    $deco = switch ($i % 6) { 0 { 'border:2px dashed #557' } 1 { 'border:3px double #557' } 2 { 'border:3px groove #99b' } 3 { 'border:2px dotted #557' } 4 { 'border:4px outset #99b' } default { 'border:1px solid #bbc' } }
    $clip = switch ($i % 5) { 0 { 'clip-path:circle(46% at 50% 50%)' } 1 { 'clip-path:polygon(0 0,100% 8%,92% 100%,6% 92%)' } 2 { 'clip-path:inset(6px round 14px)' } default { '' } }
    [void]$s.Append("<div class=c style='background:linear-gradient(135deg,hsl($h 80% 60%),hsl($(($h + 80) % 360) 80% 50%)),radial-gradient(circle at 30% 20%,#fff8,#fff0 60%);border-radius:$(6 + ($i % 5) * 6)px;box-shadow:0 $(2 + $i % 8)px $(8 + $i % 20)px hsl($h 50% 20% / .35),inset 0 1px 0 #fff6;$deco;$clip'><b style='text-shadow:0 1px 3px #0006;text-decoration:underline wavy #f40'>Card $i</b><span style='background:conic-gradient(from $($i*9)deg,#f60,#fc0,#6c3,#39f,#f60);display:inline-block;width:34px;height:34px;border-radius:50%'></span></div>")
}
Page 'css_fx.html' '.c{display:inline-block;width:210px;height:130px;margin:14px;padding:10px;box-sizing:border-box;color:#fff;vertical-align:top}' $s.ToString()
# css_filters: blur / drop-shadow / backdrop / opacity / blend on a page of images and text
$s = New-Object Text.StringBuilder
for ($i = 0; $i -lt 60; $i++) {
    $f = switch ($i % 6) { 0 { 'filter:blur(3px)' } 1 { 'filter:drop-shadow(0 6px 8px #0006)' } 2 { 'backdrop-filter:blur(10px) saturate(1.4);background:#fff4' } 3 { 'opacity:.7' } 4 { 'mix-blend-mode:multiply' } default { 'filter:grayscale(.8) contrast(1.2)' } }
    [void]$s.Append(("<div class=f style='$f'><img src='thumb{0:00}.jpg'><p>Filtered card $i with some text</p></div>" -f (($i % 40) + 1)))
}
Page 'css_filters.html' '.f{display:inline-block;width:240px;margin:12px;vertical-align:top;background:#fffa}.f img{width:100%;display:block}' $s.ToString()
Write-Host "corpus in $out"
