# Draws the Wren browser logo: a rounded square with a soft vertical gradient and a darker border (same family as the
# gui_toolkit logo), carrying a white wren: round body, round head, thin beak, the wren's cocked-up tail, standing on a
# white perch. The eye and the wing line are holes that show the body gradient through. A semicircular notch in the
# top edge of the square nods to WebAssembly (the only execution engine of the browser).
# Small sizes use a simpler drawing (detail level picked from the size by DetailFor): 2 = full (64+), 1 = no legs, perch
# or wing, bigger eye (32-48), 0 = also no eye and no notch, larger bird, thicker tail, thin margin (16-24).
# The dev variant marks the development builds (every build but build.bat release): the same bird on a blueprint, a
# cyanotype blue square ruled with a fine white grid drawn per size on whole pixels (DrawGrid), gone at 32 px and below.
#   powershell -File tools/make_logo.ps1 [-Out assets] [-Variant amber|dev|violet|amber-plain]
# Writes logo.png (512), logo_256/64/32/16.png and wren.ico (16/24/32/48/64/128/256) into -Out; for -Variant dev,
# into assets\dev by default, the icon named wren_dev.ico (src\browser\wren_dev.rc).
#   powershell -File tools/make_logo.ps1 -Out build/logo_variants -Variant violet -Single
# With -Single, only writes logo_<variant>.png (512) and a check sheet logo_<variant>_sizes.png: every size on a dark
# and on a light background, plus 48/32/24/16 magnified (nearest neighbour) on both.
param(
  [string]$Out = '',
  [ValidateSet('amber', 'dev', 'violet', 'amber-plain')][string]$Variant = 'amber',
  [switch]$Single
)
if (-not $Out) {
  $Out = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
  if ($Variant -eq 'dev') { $Out = Join-Path $Out 'dev' }
}
Add-Type -AssemblyName System.Drawing
$SS = 4   # supersampling factor: drawn at 512*S, then downscaled

function Hex($v) { return [Drawing.Color]::FromArgb(255, ($v -shr 16) -band 255, ($v -shr 8) -band 255, $v -band 255) }
function Pt($x, $y) { return New-Object Drawing.PointF ([single]$x), ([single]$y) }

# rounded rectangle; when $nr > 0, a semicircular notch of radius $nr is cut into the middle of the top edge
function NotchRect($x, $y, $w, $h, $r, $nr) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath; $d = 2 * $r
  $p.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90)
  if ($nr -gt 0) {
    $cx = $x + $w / 2
    $p.AddLine([single]($x + $r), [single]$y, [single]($cx - $nr), [single]$y)
    $p.AddArc([single]($cx - $nr), [single]($y - $nr), [single](2 * $nr), [single](2 * $nr), 180, -180)
  }
  $p.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
  $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), [single]$d, [single]$d, 0, 90)
  $p.AddArc([single]$x, [single]($y + $h - $d), [single]$d, [single]$d, 90, 90); $p.CloseFigure(); return $p
}
function RoundRect($x, $y, $w, $h, $r) { return NotchRect $x $y $w $h $r 0 }

# ellipse centred on (cx, cy), rotated by $deg degrees (clockwise, y down)
function RotEllipse($cx, $cy, $w, $h, $deg) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath
  $p.AddEllipse([single]($cx - $w / 2), [single]($cy - $h / 2), [single]$w, [single]$h)
  $m = New-Object Drawing.Drawing2D.Matrix; $m.RotateAt([single]$deg, (Pt $cx $cy)); $p.Transform($m); return $p
}
# rounded rectangle centred on (cx, cy), rotated by $deg degrees
function RotRoundRect($cx, $cy, $w, $h, $r, $deg) {
  $p = RoundRect ($cx - $w / 2) ($cy - $h / 2) $w $h $r
  $m = New-Object Drawing.Drawing2D.Matrix; $m.RotateAt([single]$deg, (Pt $cx $cy)); $p.Transform($m); return $p
}

$palettes = @{
  # body top, body bottom, border top, border bottom
  'amber'       = @(0xf39a2e, 0xc25a0c, 0xd9781c, 0x8c3a05)
  'amber-plain' = @(0xf39a2e, 0xc25a0c, 0xd9781c, 0x8c3a05)
  'violet'      = @(0x7b63f2, 0x4a2fc0, 0x5f47d8, 0x2c1984)
  'dev'         = @(0x2363b8, 0x153f86, 0x1a4f9c, 0x0b2560)
}
$notched = $Variant -ne 'amber-plain'
$layered = $Variant -eq 'dev'   # a grid between the body and the bird (Render)

# the square: 400 units with a 56 margin (like the toolkit), almost full-bleed at the smallest detail level; the notch
# is dropped at the smallest detail level, where it would read as a dent
function Geometry($detail) {
  if ($detail -eq 0) { $m = 20; $r = 110; $bw = 18 } else { $m = 56; $r = 100; $bw = 10 }
  $w = 512 - 2 * $m
  $nr = 0; if ($notched -and $detail -gt 0) { $nr = 34 * $w / 400 }
  return @{ m = $m; r = $r; w = $w; nr = $nr; bw = $bw }
}

# draws a layer of the logo at 512*S in 512-unit coordinates: 'all' (the whole logo), or for the variants that put
# something between the body and the bird (the blueprint grid): 'fill' (the body), 'edge' (border and highlight),
# 'bird' (the wren alone, its eye and wing cut out as transparent holes)
function DrawLayer($detail, $what) {
  $c = $palettes[$Variant]
  $N = 512 * $SS
  $b = New-Object Drawing.Bitmap $N, $N
  $g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
  $g.ScaleTransform([single]$SS, [single]$SS)
  $geo = Geometry $detail; $m = $geo.m; $r = $geo.r; $w = $geo.w; $nr = $geo.nr; $bw = $geo.bw

  $fill = New-Object Drawing.Drawing2D.LinearGradientBrush (Pt 0 $m), (Pt 0 (512 - $m)), (Hex $c[0]), (Hex $c[1])
  if ($what -eq 'all' -or $what -eq 'fill') { $g.FillPath($fill, (NotchRect $m $m $w $w $r $nr)) }
  if ($what -eq 'fill') { $g.Dispose(); return $b }
  if ($what -eq 'bird') {
    # the holes are cleared, not painted: what is under the bird layer (grid lines) shows through them
    $fill = $null
  } else {
  # darker border just inside the edge (a gradient too, so it stays darker than the body everywhere)
  $edge = New-Object Drawing.Drawing2D.LinearGradientBrush (Pt 0 $m), (Pt 0 (512 - $m)), (Hex $c[2]), (Hex $c[3])
  $pen = New-Object Drawing.Pen $edge, ([single]$bw)
  $nb = 0; if ($nr -gt 0) { $nb = $nr + $bw / 2 }
  $g.DrawPath($pen, (NotchRect ($m + $bw / 2) ($m + $bw / 2) ($w - $bw) ($w - $bw) ($r - $bw / 2) $nb))
  # a faint highlight along the top inner edge
  if ($detail -gt 0) {
    $hl = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(40, 255, 255, 255)), ([single]2)
    $nh = 0; if ($nr -gt 0) { $nh = $nr + $bw + 1 }
    $g.DrawPath($hl, (NotchRect ($m + $bw + 1) ($m + $bw + 1) ($w - 2 * $bw - 2) ($w - 2 * $bw - 2) ($r - $bw) $nh))
  }
  if ($what -eq 'edge') { $g.Dispose(); return $b }
  }

  # the wren, facing right, nudged left so the bird (not its bounding box) sits in the middle; drawn larger at the
  # lower detail levels. Every shape is a path moved by $bm, so the holes can be filled with the untouched body brush.
  if ($detail -eq 0) { $k = 1.22 } elseif ($detail -eq 1) { $k = 1.1 } else { $k = 1.0 }
  $bm = New-Object Drawing.Drawing2D.Matrix
  $bm.Translate(256, 268); $bm.Scale([single]$k, [single]$k); $bm.Translate(-256 - 14, -268)
  $white = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
  function Put($brush, $path) {
    $path.Transform($bm)
    if ($brush) { $g.FillPath($brush, $path); return }
    $g.SetClip($path); $g.Clear([Drawing.Color]::Transparent); $g.ResetClip()
  }
  function Stroke($path, $width) {
    $pen = New-Object Drawing.Pen ([Drawing.Color]::Black), ([single]$width)
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $path.Widen($pen); return $path
  }
  if ($detail -eq 2) {
    # perch and legs
    Put $white (RoundRect 150 384 220 26 13)
    $legs = New-Object Drawing.Drawing2D.GraphicsPath
    $legs.AddLine([single]248, [single]340, [single]242, [single]392); $legs.StartFigure()
    $legs.AddLine([single]278, [single]340, [single]280, [single]392)
    Put $white (Stroke $legs 12)
  }
  # cocked tail (a narrow rounded bar standing almost upright), body, head
  $tw = 52; if ($detail -eq 0) { $tw = 62 }
  Put $white (RotRoundRect 176 200 $tw 184 ($tw / 2) -20)
  Put $white (RotEllipse 262 292 214 160 -14)
  Put $white (RotEllipse 330 224 124 124 0)
  # thin beak, slightly drooping
  $beak = New-Object Drawing.Drawing2D.GraphicsPath
  if ($detail -eq 0) { $beak.AddPolygon([Drawing.PointF[]]@((Pt 376 192), (Pt 440 232), (Pt 380 250))) }
  else { $beak.AddPolygon([Drawing.PointF[]]@((Pt 378 198), (Pt 434 230), (Pt 382 242))) }
  Put $white $beak
  if ($detail -ge 1) {
    # eye hole
    $er = 13; if ($detail -eq 1) { $er = 16 }
    Put $fill (RotEllipse 346 214 (2 * $er) (2 * $er) 0)
  }
  if ($detail -eq 2) {
    # wing line: a curve cut through the body, sweeping from the shoulder back toward the tail
    $wing = New-Object Drawing.Drawing2D.GraphicsPath
    $wing.AddBezier((Pt 306 264), (Pt 286 302), (Pt 248 320), (Pt 208 312))
    Put $fill (Stroke $wing 12)
  }
  $g.Dispose()
  return $b
}

# downscales a layer to $size x $size in steps of at most /4 so bicubic stays clean down to 16 px
function Shrink($b, $size) {
  $cur = $b; $cs = $b.Width
  while ($cs -gt $size) {
    $ns = [Math]::Max($size, [int]($cs / 4))
    $o = New-Object Drawing.Bitmap $ns, $ns
    $g2 = [Drawing.Graphics]::FromImage($o); $g2.InterpolationMode = 'HighQualityBicubic'; $g2.PixelOffsetMode = 'HighQuality'
    $g2.CompositingQuality = 'HighQuality'
    $g2.DrawImage($cur, 0, 0, $ns, $ns); $g2.Dispose(); $cur.Dispose()
    $cur = $o; $cs = $ns
  }
  return $cur
}

# The blueprint grid, drawn at the output size (not shrunk from 512, which would blur it into a haze): 1-pixel lines on
# whole pixels, mirrored about the middle of the square, minor and major lines while they are far enough apart to read,
# none at all at 32 px and below (there the blue and the bird say it). Clipped to the inside of the border.
function DrawGrid($bmp, $size, $detail) {
  if ($size -le 32) { return }
  $geo = Geometry $detail
  $k = $size / 512.0
  $lo = ($geo.m + $geo.bw) * $k; $hi = (512 - $geo.m - $geo.bw) * $k
  $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'None'; $g.PixelOffsetMode = 'Half'
  $nc = 0; if ($geo.nr -gt 0) { $nc = ($geo.nr + $geo.bw) * $k }
  $g.SetClip((NotchRect $lo $lo ($hi - $lo) ($hi - $lo) (($geo.r - $geo.bw) * $k) $nc))
  # one cell of 25 units, a major line every 4 cells, one through the middle (the grid is mirrored about the middle of
  # pixel size/2: the half-pixel offset keeps every line on whole pixels)
  $minor = 25 * $k
  $lines = @()   # (pixel offset from the middle, width, alpha)
  if (4 * $minor -ge 10) {
    for ($i = 0; $i * $minor -lt $size / 2; $i++) {
      $isMajor = ($i % 4) -eq 0
      if (-not $isMajor -and $minor -lt 7) { continue }
      $a = if ($isMajor) { 70 } else { 30 }
      $lines += , @([int][Math]::Round($i * $minor), 1, $a)
    }
  } else {
    # 48: a coarse grid of four cells across
    $step = ($hi - $lo) / 4
    $lines += , @(0, 1, 60); $lines += , @([int][Math]::Round($step), 1, 60)
  }
  $c = [int]($size / 2)
  foreach ($l in $lines) {
    $d = $l[0]; $lw = $l[1]
    $br = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($l[2], 255, 255, 255))
    $set = if ($d -eq 0) { @($c) } else { @(($c - $d), ($c + $d)) }
    foreach ($p in $set) {
      $g.FillRectangle($br, [single]$p, [single]0, [single]$lw, [single]$size)
      $g.FillRectangle($br, [single]0, [single]$p, [single]$size, [single]$lw)
    }
  }
  # a dimension line under the perch, the length of the perch, with end ticks (from 128 px, where it reads as one)
  if ($size -ge 128 -and $detail -eq 2) {
    $br = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(150, 255, 255, 255))
    $lw = [Math]::Max(1, [int]($size / 256))
    $x0 = [int][Math]::Round(136 * $k); $x1 = [int][Math]::Round(356 * $k); $y = [int][Math]::Round(426 * $k)
    $t = [Math]::Max(2, [int][Math]::Round(9 * $k))
    $g.FillRectangle($br, [single]$x0, [single]$y, [single]($x1 - $x0 + $lw), [single]$lw)
    foreach ($x in @($x0, $x1)) { $g.FillRectangle($br, [single]$x, [single]($y - $t), [single]$lw, [single](2 * $t + $lw)) }
  }
  $g.Dispose()
}

function Over($dst, $src) {
  $g = [Drawing.Graphics]::FromImage($dst); $g.CompositingMode = 'SourceOver'
  $g.DrawImageUnscaled($src, 0, 0); $g.Dispose(); $src.Dispose()
}

# the logo at $size x $size
function Render($size, $detail) {
  if (-not $layered) { return Shrink (DrawLayer $detail 'all') $size }
  $b = Shrink (DrawLayer $detail 'fill') $size
  DrawGrid $b $size $detail
  Over $b (Shrink (DrawLayer $detail 'edge') $size)
  Over $b (Shrink (DrawLayer $detail 'bird') $size)
  return $b
}

function DetailFor($size) { if ($size -le 24) { return 0 } elseif ($size -le 48) { return 1 } else { return 2 } }

function PngBytes($bmp) {
  $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); return , $ms.ToArray()
}

# classic 32-bit DIB icon image (BITMAPINFOHEADER, bottom-up BGRA, empty AND mask) for the small sizes
function DibBytes($bmp) {
  $n = $bmp.Width
  $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
  $w.Write([int]40); $w.Write([int]$n); $w.Write([int](2 * $n)); $w.Write([int16]1); $w.Write([int16]32)
  $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
  for ($y = $n - 1; $y -ge 0; $y--) {
    for ($x = 0; $x -lt $n; $x++) {
      $p = $bmp.GetPixel($x, $y); $w.Write([byte]$p.B); $w.Write([byte]$p.G); $w.Write([byte]$p.R); $w.Write([byte]$p.A)
    }
  }
  $rowBytes = [int]([Math]::Ceiling($n / 32.0) * 4)
  $w.Write((New-Object byte[] ($rowBytes * $n)))
  $w.Flush(); return , $ms.ToArray()
}

function WriteIco($path, $sizes) {
  $images = @()
  foreach ($s in $sizes) {
    $bmp = Render $s (DetailFor $s)
    if ($s -ge 64) { $images += , (PngBytes $bmp) } else { $images += , (DibBytes $bmp) }
  }
  $fs = [IO.File]::Create($path); $w = New-Object IO.BinaryWriter $fs
  $w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$sizes.Count)
  $offset = 6 + 16 * $sizes.Count
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$images[$i].Length); $w.Write([int]$offset)
    $offset += $images[$i].Length
  }
  foreach ($img in $images) { $w.Write($img) }
  $w.Close()
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path

if ($Single) {
  (Render 512 2).Save((Join-Path $Out "logo_$Variant.png"), [Drawing.Imaging.ImageFormat]::Png)
  # strip: 256, 128, 64, 48, 32, 24, 16 side by side, then 48/32/24/16 magnified (nearest neighbour) on a second row
  # to check the small sizes pixel by pixel; once on a dark grey (a dark taskbar) and once on a light one
  $sizes = @(256, 128, 64, 48, 32, 24, 16)
  $imgs = @{}; foreach ($s in $sizes) { $imgs[$s] = Render $s (DetailFor $s) }
  $sw = 0; foreach ($s in $sizes) { $sw += $s + 16 }
  $bh = 288 + 208
  $strip = New-Object Drawing.Bitmap ([Math]::Max($sw + 16, 4 * 208 + 16)), (2 * $bh)
  $gs = [Drawing.Graphics]::FromImage($strip)
  $gs.InterpolationMode = 'NearestNeighbor'; $gs.PixelOffsetMode = 'Half'
  $bands = @(@(0, 0x2b2f38), @($bh, 0xeef0f4))
  foreach ($band in $bands) {
    $y0 = $band[0]
    $gs.FillRectangle((New-Object Drawing.SolidBrush (Hex $band[1])), 0, $y0, $strip.Width, $bh); $x = 16
    foreach ($s in $sizes) {
      $img = $imgs[$s]; $gs.DrawImage($img, $x, $y0 + 16, $s, $s); $x += $s + 16
      if ($s -le 48) { $zx = 16 + 208 * [Array]::IndexOf(@(48, 32, 24, 16), $s); $gs.DrawImage($img, $zx, $y0 + 288, 192, 192) }
    }
  }
  $strip.Save((Join-Path $Out "logo_${Variant}_sizes.png"), [Drawing.Imaging.ImageFormat]::Png)
  "wrote $Out\logo_$Variant.png and logo_${Variant}_sizes.png"
  return
}

foreach ($s in @(512, 256, 64, 32, 16)) {
  $name = if ($s -eq 512) { 'logo.png' } else { "logo_$s.png" }
  (Render $s (DetailFor $s)).Save((Join-Path $Out $name), [Drawing.Imaging.ImageFormat]::Png)
}
$ico = if ($Variant -eq 'dev') { 'wren_dev.ico' } else { 'wren.ico' }
WriteIco (Join-Path $Out $ico) @(16, 24, 32, 48, 64, 128, 256)
"wrote $Out\logo.png, logo_256/64/32/16.png, $ico"
