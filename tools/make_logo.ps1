# Draws the Wren browser logo: a rounded square with a soft vertical gradient and a darker border (same family as the
# gui_toolkit logo), carrying a white wren: round body, round head, thin beak, the wren's cocked-up tail, standing on a
# white perch. The eye and the wing line are holes that show the body gradient through. A semicircular notch in the
# top edge of the square nods to WebAssembly (the only execution engine of the browser).
# Small sizes use a simpler drawing (-Detail): 2 = full, 1 = no legs/perch/wing, 0 = also no eye, larger bird, thin margin.
#   powershell -File tools/make_logo.ps1 [-Out assets] [-Variant amber|violet|amber-plain]
# Writes logo.png (512), logo_256/64/32/16.png and wren.ico (16/24/32/48/64/128/256) into -Out.
#   powershell -File tools/make_logo.ps1 -Out build/logo_variants -Variant violet -Single
# With -Single, only writes logo_<variant>.png (512) and a strip of every size: logo_<variant>_sizes.png.
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
  $nr = 0; if ($notched) { $nr = 34 * $w / 400 }
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

  # the wren, facing right, nudged left so the bird (not its bounding box) sits in the middle;
  # at the lower detail levels it is drawn larger. Holes use a copy of the body brush that cancels this transform.
  $state = $g.Save()
  if ($detail -eq 0) { $k = 1.2 } elseif ($detail -eq 1) { $k = 1.08 } else { $k = 1.0 }
  $bm = New-Object Drawing.Drawing2D.Matrix
  $bm.Translate(256, 268); $bm.Scale([single]$k, [single]$k); $bm.Translate(-256 - 16, -268)
  $g.MultiplyTransform($bm)
  $inv = $bm.Clone(); $inv.Invert(); $hole = $fill.Clone(); $hole.Transform = $inv
  $white = New-Object Drawing.SolidBrush ([Drawing.Color]::White)
  if ($detail -eq 2) {
    # perch and legs
    $g.FillPath($white, (RoundRect 140 382 232 26 13))
    $leg = New-Object Drawing.Pen ([Drawing.Color]::White), ([single]11)
    $leg.StartCap = 'Round'; $leg.EndCap = 'Round'
    $g.DrawLine($leg, 246, 340, 238, 388); $g.DrawLine($leg, 276, 340, 276, 388)
  }
  # cocked tail, body, head
  $g.FillPath($white, (RotEllipse 170 196 58 176 -24))
  $g.FillPath($white, (RotEllipse 258 290 214 160 -14))
  $g.FillEllipse($white, [single](328 - 62), [single](222 - 62), [single]124, [single]124)
  # thin beak, slightly drooping
  $beak = New-Object Drawing.Drawing2D.GraphicsPath
  $beak.AddPolygon([Drawing.PointF[]]@((Pt 376 196), (Pt 436 228), (Pt 380 240)))
  $g.FillPath($white, $beak)
  if ($detail -ge 1) {
    # eye hole
    $er = 13; if ($detail -eq 1) { $er = 17 }
    $g.FillEllipse($fill, [single](344 - $er), [single](212 - $er), [single](2 * $er), [single](2 * $er))
  }
  if ($detail -eq 2) {
    # wing line: an arc cut through the body
    $wing = New-Object Drawing.Pen $fill, ([single]12)
    $wing.StartCap = 'Round'; $wing.EndCap = 'Round'
    $g.DrawArc($wing, [single]196, [single]236, [single]132, [single]96, 200, 110)
  }
  $g.Restore($state); $g.Dispose()

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
  # strip: 256, 128, 64, 48, 32, 24, 16 side by side on a mid-grey background
  $sizes = @(256, 128, 64, 48, 32, 24, 16)
  $sw = 0; foreach ($s in $sizes) { $sw += $s + 16 }
  $strip = New-Object Drawing.Bitmap ($sw + 16), 288
  $gs = [Drawing.Graphics]::FromImage($strip); $gs.Clear((Hex 0x3a3f4a)); $x = 16
  foreach ($s in $sizes) { $gs.DrawImageUnscaled((Render $s (DetailFor $s)), $x, 16); $x += $s + 16 }
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
