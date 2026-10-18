# Draws the Wren browser logo: a rounded square with a soft vertical gradient and a darker border (same family as the
# gui_toolkit logo), carrying a white wren: round body, round head, thin beak, the wren's cocked-up tail, standing on a
# white perch. The eye and the wing line are holes that show the body gradient through. A semicircular notch in the
# top edge of the square nods to WebAssembly (the only execution engine of the browser).
# Small sizes use a simpler drawing (detail level picked from the size by DetailFor): 2 = full (64+), 1 = no legs, perch
# or wing, bigger eye (32-48), 0 = also no eye and no notch, larger bird, thicker tail, thin margin (16-24).
#   powershell -File tools/make_logo.ps1 [-Out assets] [-Variant amber|violet|amber-plain]
# Writes logo.png (512), logo_256/64/32/16.png and wren.ico (16/24/32/48/64/128/256) into -Out.
#   powershell -File tools/make_logo.ps1 -Out build/logo_variants -Variant violet -Single
# With -Single, only writes logo_<variant>.png (512) and a check sheet logo_<variant>_sizes.png: every size, plus
# 48/32/24/16 magnified (nearest neighbour).
param(
  [string]$Out = (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'),
  [ValidateSet('amber', 'violet', 'amber-plain')][string]$Variant = 'amber',
  [switch]$Single
)
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
}
$notched = $Variant -ne 'amber-plain'

# renders the logo at 512*S in 512-unit coordinates and returns a $size x $size bitmap
function Render($size, $detail) {
  $c = $palettes[$Variant]
  $N = 512 * $SS
  $b = New-Object Drawing.Bitmap $N, $N
  $g = [Drawing.Graphics]::FromImage($b); $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
  $g.ScaleTransform([single]$SS, [single]$SS)

  # the square: 400 units with a 56 margin (like the toolkit), almost full-bleed at the smallest detail level
  if ($detail -eq 0) { $m = 20; $r = 110 } else { $m = 56; $r = 100 }
  $w = 512 - 2 * $m
  # the notch is dropped at the smallest detail level, where it would read as a dent
  $nr = 0; if ($notched -and $detail -gt 0) { $nr = 34 * $w / 400 }
  $bw = 10; if ($detail -eq 0) { $bw = 18 }

  $fill = New-Object Drawing.Drawing2D.LinearGradientBrush (Pt 0 $m), (Pt 0 (512 - $m)), (Hex $c[0]), (Hex $c[1])
  $g.FillPath($fill, (NotchRect $m $m $w $w $r $nr))
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

  # the wren, facing right, nudged left so the bird (not its bounding box) sits in the middle; drawn larger at the
  # lower detail levels. Every shape is a path moved by $bm, so the holes can be filled with the untouched body brush.
  if ($detail -eq 0) { $k = 1.22 } elseif ($detail -eq 1) { $k = 1.1 } else { $k = 1.0 }
  $bm = New-Object Drawing.Drawing2D.Matrix
  $bm.Translate(256, 268); $bm.Scale([single]$k, [single]$k); $bm.Translate(-256 - 14, -268)
  $white = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
  function Put($brush, $path) { $path.Transform($bm); $g.FillPath($brush, $path) }
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

  # downscale in steps of at most /4 so bicubic stays clean down to 16 px
  $cur = $b; $cs = $N
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
  # strip: 256, 128, 64, 48, 32, 24, 16 side by side on a mid-grey background, then 48/32/24/16 magnified
  # (nearest neighbour) on a second row to check the small sizes pixel by pixel
  $sizes = @(256, 128, 64, 48, 32, 24, 16)
  $sw = 0; foreach ($s in $sizes) { $sw += $s + 16 }
  $strip = New-Object Drawing.Bitmap ([Math]::Max($sw + 16, 4 * 208 + 16)), (288 + 208)
  $gs = [Drawing.Graphics]::FromImage($strip); $gs.Clear((Hex 0x3a3f4a)); $x = 16
  $gs.InterpolationMode = 'NearestNeighbor'; $gs.PixelOffsetMode = 'Half'
  foreach ($s in $sizes) {
    $img = Render $s (DetailFor $s); $gs.DrawImage($img, $x, 16, $s, $s); $x += $s + 16
    if ($s -le 48) { $zx = 16 + 208 * [Array]::IndexOf(@(48, 32, 24, 16), $s); $gs.DrawImage($img, $zx, 304, 192, 192) }
  }
  $strip.Save((Join-Path $Out "logo_${Variant}_sizes.png"), [Drawing.Imaging.ImageFormat]::Png)
  "wrote $Out\logo_$Variant.png and logo_${Variant}_sizes.png"
  return
}

foreach ($s in @(512, 256, 64, 32, 16)) {
  $name = if ($s -eq 512) { 'logo.png' } else { "logo_$s.png" }
  (Render $s (DetailFor $s)).Save((Join-Path $Out $name), [Drawing.Imaging.ImageFormat]::Png)
}
WriteIco (Join-Path $Out 'wren.ico') @(16, 24, 32, 48, 64, 128, 256)
"wrote $Out\logo.png, logo_256/64/32/16.png, wren.ico"
