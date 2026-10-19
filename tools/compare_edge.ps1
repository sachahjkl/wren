# Captures a page in Wren and in Microsoft Edge (headless) at the same viewport size and device scale, and writes a
# side-by-side image, a difference image and a measure of the difference.
#   powershell -NoProfile -File tools\compare_edge.ps1 -Url https://example.com [-Name example] [-Width 1280] [-Height 720]
#       [-WaitMs 6000] [-OutDir build\cmp] [-NoWren] [-NoEdge] [-NoScript [-UserAgent <ua>] [-AcceptLanguage <list>]]
# -Exe: another build of Wren (an older one, to measure a change; default build\browser.exe).
# -NoScript compares on equal terms with Wren, which runs no JavaScript: Edge runs with scripts disabled and sends Wren's
# User-Agent and Accept-Language (the defaults of network.user_agent and network.accept_language), so that servers that
# pick a page by browser (Google serves its plain HTML page to unknown browsers) send both the same document. Edge's DOM
# after loading is kept as <name>_edge.html (check which page it got). Some servers still tell them apart by other
# headers (Google's page for script-less Chromium has a <noscript> refresh to another page): -Snapshot (implies
# -NoScript) has Edge render the document fetched with Wren's headers, saved as <name>_snapshot.html with a <base>.
# Outputs in -OutDir: <name>_wren.png, <name>_edge.png (the viewport only, physical pixels), <name>_side.png (Wren left,
# Edge right), <name>_diff.png (differing pixels in red over a faded Edge capture), and one line of JSON on stdout:
#   {"name":..., "width":..., "height":..., "scale":..., "diff_pixels": <fraction of pixels whose largest channel
#    difference is over 32>, "mean_abs": <mean absolute channel difference, 0..255>}
# The Wren capture goes through tools\screenshot.ps1 and opens a window: take the shared lock first (S:\wb_wt\BRIEF.md).
# Wren's viewport is found by calibration: a page that is one solid color is captured once per window size, and the
# rectangle of that color is the viewport. Edge runs headless with its own throwaway profile, at the system's device
# scale, so that both captures have the same physical size. Scroll bars: Edge hides them; the comparison is cropped to
# the smaller of the two widths.
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Name = '',
    [int]$Width = 1280,
    [int]$Height = 720,
    [int]$WaitMs = 6000,
    [string]$OutDir = 'build\cmp',
    [switch]$NoWren,
    [switch]$NoEdge,
    [switch]$NoScript,
    [switch]$Snapshot,
    [string]$UserAgent = 'Wren/0.1',
    [string]$AcceptLanguage = 'en-US,en;q=0.9',
    [string]$Exe = ''
)
$ErrorActionPreference = 'Stop'
if ($Snapshot) { $NoScript = [switch]$true }
$root = Split-Path $PSScriptRoot -Parent
if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $root $OutDir }
New-Item -ItemType Directory -Force $OutDir | Out-Null
if (-not $Name) { $Name = ($Url -replace '^[a-z]+://', '' -replace '[^A-Za-z0-9._-]+', '_').Trim('_') }

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
public static class Cmp {
  [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr c);
  static int[] Pixels(Bitmap b) {
    var r = new Rectangle(0, 0, b.Width, b.Height);
    var d = b.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    var px = new int[b.Width * b.Height];
    for (int y = 0; y < b.Height; y++) Marshal.Copy(d.Scan0 + y * d.Stride, px, y * b.Width, b.Width);
    b.UnlockBits(d);
    return px;
  }
  static Bitmap FromPixels(int[] px, int w, int h) {
    var b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
    var d = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
    for (int y = 0; y < h; y++) Marshal.Copy(px, y * w, d.Scan0 + y * d.Stride, w);
    b.UnlockBits(d);
    return b;
  }
  // The bounding box of the pixels close to `rgb` (calibration): x, y, w, h; w = 0 when none.
  public static int[] FindColor(string path, int rgb, int tol) {
    using (var b = new Bitmap(path)) {
      var px = Pixels(b);
      int x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
      for (int y = 0; y < b.Height; y++) for (int x = 0; x < b.Width; x++) {
        int p = px[y * b.Width + x];
        if (Math.Abs(((p >> 16) & 255) - ((rgb >> 16) & 255)) <= tol && Math.Abs(((p >> 8) & 255) - ((rgb >> 8) & 255)) <= tol && Math.Abs((p & 255) - (rgb & 255)) <= tol) {
          if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y;
        }
      }
      if (x1 < 0) return new int[] { 0, 0, 0, 0 };
      return new int[] { x0, y0, x1 - x0 + 1, y1 - y0 + 1 };
    }
  }
  public static void Crop(string src, string dst, int x, int y, int w, int h) {
    using (var b = new Bitmap(src)) using (var c = b.Clone(new Rectangle(x, y, Math.Min(w, b.Width - x), Math.Min(h, b.Height - y)), PixelFormat.Format32bppArgb)) c.Save(dst, ImageFormat.Png);
  }
  // Writes the side-by-side and difference images; returns [fraction of differing pixels, mean absolute difference].
  public static double[] Compare(string a, string b, string side, string diff, string labelA, string labelB) {
    using (var ba = new Bitmap(a)) using (var bb = new Bitmap(b)) {
      int w = Math.Min(ba.Width, bb.Width), h = Math.Min(ba.Height, bb.Height);
      var pa = Pixels(ba); var pb = Pixels(bb);
      var pd = new int[w * h];
      long differing = 0; double sum = 0;
      for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int p = pa[y * ba.Width + x], q = pb[y * bb.Width + x];
        int dr = Math.Abs(((p >> 16) & 255) - ((q >> 16) & 255)), dg = Math.Abs(((p >> 8) & 255) - ((q >> 8) & 255)), db = Math.Abs((p & 255) - (q & 255));
        sum += dr + dg + db;
        int m = Math.Max(dr, Math.Max(dg, db));
        if (m > 32) { differing++; pd[y * w + x] = unchecked((int)0xFFFF0000); }
        else { int g = 255 - (255 - (((q >> 16) & 255) * 30 + ((q >> 8) & 255) * 59 + (q & 255) * 11) / 100) / 4; pd[y * w + x] = unchecked((int)0xFF000000) | (g << 16) | (g << 8) | g; }
      }
      using (var d = FromPixels(pd, w, h)) d.Save(diff, ImageFormat.Png);
      int gap = 16, top = 48;
      using (var s = new Bitmap(ba.Width + gap + bb.Width, Math.Max(ba.Height, bb.Height) + top, PixelFormat.Format32bppArgb))
      using (var g = Graphics.FromImage(s)) using (var f = new Font("Segoe UI", 20, FontStyle.Bold, GraphicsUnit.Pixel)) {
        g.Clear(Color.FromArgb(40, 40, 48));
        g.DrawImage(ba, 0, top, ba.Width, ba.Height);
        g.DrawImage(bb, ba.Width + gap, top, bb.Width, bb.Height);
        g.DrawString(labelA, f, Brushes.White, 8, 12);
        g.DrawString(labelB, f, Brushes.White, ba.Width + gap + 8, 12);
        s.Save(side, ImageFormat.Png);
      }
      return new double[] { (double)differing / (w * h), sum / (3.0 * w * h) };
    }
  }
}
'@
[Cmp]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$scale = [Cmp]::GetDpiForSystem() / 96.0
$physW = [int][math]::Round($Width * $scale)
$physH = [int][math]::Round($Height * $scale)
$wrenPng = Join-Path $OutDir "${Name}_wren.png"
$edgePng = Join-Path $OutDir "${Name}_edge.png"

if (-not $NoWren) {
    $exeArgs = if ($Exe) { @('-Exe', $Exe) } else { @() }
    # calibration: the window's chrome around the viewport, measured once per size (cached in the output folder)
    $calibFile = Join-Path $OutDir "calibration_${physW}x${physH}.txt"
    $shot = Join-Path ([IO.Path]::GetTempPath()) "wren_cmp_$PID.png"
    if (-not (Test-Path $calibFile)) {
        $page = Join-Path $OutDir 'calibration.html'
        [IO.File]::WriteAllText($page, '<!doctype html><html style="background:#ff00ff;height:100%;overflow:hidden"><body style="margin:0"></body></html>')
        $pageUrl = 'file:///' + ($page -replace '\\', '/')
        # a first window at an estimated size, then the exact one
        $outerW = $physW + 40; $outerH = $physH + [int](220 * $scale)
        for ($pass = 0; $pass -lt 2; $pass++) {
            & powershell -NoProfile -File (Join-Path $PSScriptRoot 'screenshot.ps1') -Url $pageUrl -Out $shot -WaitMs 2500 -Width $outerW -Height $outerH @exeArgs | Out-Null
            $r = [Cmp]::FindColor($shot, 0xFF00FF, 8)
            if ($r[2] -eq 0) { throw 'calibration: the viewport was not found in the capture' }
            $outerW += $physW - $r[2]; $outerH += $physH - $r[3]
        }
        & powershell -NoProfile -File (Join-Path $PSScriptRoot 'screenshot.ps1') -Url $pageUrl -Out $shot -WaitMs 2500 -Width $outerW -Height $outerH @exeArgs | Out-Null
        $r = [Cmp]::FindColor($shot, 0xFF00FF, 8)
        [IO.File]::WriteAllText($calibFile, "$outerW $outerH $($r[0]) $($r[1]) $($r[2]) $($r[3])")
    }
    $c = (Get-Content $calibFile -Raw).Trim() -split ' ' | ForEach-Object { [int]$_ }
    & powershell -NoProfile -File (Join-Path $PSScriptRoot 'screenshot.ps1') -Url $Url -Out $shot -WaitMs $WaitMs -Width $c[0] -Height $c[1] @exeArgs | Out-Null
    [Cmp]::Crop($shot, $wrenPng, $c[2], $c[3], $c[4], $c[5])
    Remove-Item $shot -ErrorAction SilentlyContinue
}

if (-not $NoEdge) {
    $edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path $edge)) { $edge = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" }
    if (-not (Test-Path $edge)) { throw 'Microsoft Edge not found' }
    $profileDir = Join-Path ([IO.Path]::GetTempPath()) "wren_cmp_edge_$PID"
    $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--disable-extensions', "--user-data-dir=$profileDir",
        "--force-device-scale-factor=$([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $scale))",
        "--window-size=$Width,$Height")
    # (with scripts off and a forced device scale, Edge never ends a virtual time budget: the load event decides)
    if (-not $NoScript) { $edgeArgs += "--virtual-time-budget=$WaitMs" }
    if ($NoScript) {
        # scripts are turned off by the profile's content settings: --blink-settings=scriptEnabled=false would also stop
        # headless --screenshot, which drives the page through script
        New-Item -ItemType Directory -Force (Join-Path $profileDir 'Default') | Out-Null
        [IO.File]::WriteAllText((Join-Path $profileDir 'Default\Preferences'), '{"profile":{"default_content_setting_values":{"javascript":2}}}')
        $first = ($AcceptLanguage -split ',')[0].Trim()
        # no client hints either: Sec-CH-UA would still name Edge (Google then answers with its consent redirect)
        $edgeArgs += @("`"--user-agent=$UserAgent`"", "--accept-lang=$AcceptLanguage", "--lang=$first",
            '--disable-features=UserAgentClientHint,UserAgentClientHintFullVersionList')
    }
    $edgeUrl = $Url
    if ($Snapshot) {
        # the document as Wren's headers get it, saved with a <base> so that its subresources still come from the site
        $r = Invoke-WebRequest $Url -UseBasicParsing -UserAgent $UserAgent -Headers @{ 'Accept-Language' = $AcceptLanguage }
        $html = $r.Content
        $baseTag = '<base href="' + [Net.WebUtility]::HtmlEncode($Url) + '">'
        $m = [regex]::Match($html, '<head[^>]*>', 'IgnoreCase')
        $html = if ($m.Success) { $html.Insert($m.Index + $m.Length, $baseTag) } else { $baseTag + $html }
        $snap = Join-Path $OutDir "${Name}_snapshot.html"
        [IO.File]::WriteAllText($snap, $html, (New-Object Text.UTF8Encoding $false))
        $edgeUrl = 'file:///' + ($snap -replace '\\', '/')
    }
    if (Test-Path $edgePng) { Remove-Item $edgePng }
    # Edge's helper processes may outlive the first one: a new start on a profile still in use would hand the address to
    # them and exit without doing anything. Waits for them (kills them past the delay).
    $tag = [IO.Path]::GetFileName($profileDir)
    $profileProcs = { Get-CimInstance Win32_Process -Filter "name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$tag*" } }
    $waitFree = {
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and (& $profileProcs)) { Start-Sleep -Milliseconds 300 }
        & $profileProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if ($NoScript) {
        # without a virtual time budget the capture is taken at the load event, sometimes before web fonts arrive: a
        # first load fills the profile's cache, the second (the capture) gets them from there
        $warm = Join-Path $OutDir "${Name}_edge_warmup.png"
        $p = Start-Process $edge -ArgumentList ($edgeArgs + @("--screenshot=$warm", $edgeUrl)) -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(120000)) { $p.Kill() }
        Remove-Item $warm -ErrorAction SilentlyContinue
        & $waitFree
    }
    for ($attempt = 0; $attempt -lt 3 -and -not (Test-Path $edgePng); $attempt++) {
        if ($attempt -gt 0) { & $waitFree }
        $p = Start-Process $edge -ArgumentList ($edgeArgs + @("--screenshot=$edgePng", $edgeUrl)) -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'Edge did not finish' }
    }
    if (-not (Test-Path $edgePng)) { throw 'Edge wrote no capture' }
    if ($NoScript) {
        & $waitFree
        $dom = Join-Path $OutDir "${Name}_edge.html"
        $p = Start-Process $edge -ArgumentList ($edgeArgs + @('--dump-dom', $edgeUrl)) -PassThru -WindowStyle Hidden -RedirectStandardOutput $dom
        # (with scripts off, --dump-dom may never exit: the DOM is written once the page has loaded)
        if (-not $p.WaitForExit(30000)) { $p.Kill() }
        & $waitFree
    }
    try { [IO.Directory]::Delete($profileDir, $true) } catch { }
}

if ((Test-Path $wrenPng) -and (Test-Path $edgePng)) {
    $m = [Cmp]::Compare($wrenPng, $edgePng, (Join-Path $OutDir "${Name}_side.png"), (Join-Path $OutDir "${Name}_diff.png"), "Wren  $Url", $(if ($NoScript) { "Edge (no script)  $Url" } else { "Edge  $Url" }))
    $inv = [Globalization.CultureInfo]::InvariantCulture
    '{{"name":"{0}","width":{1},"height":{2},"scale":{3},"diff_pixels":{4},"mean_abs":{5}}}' -f $Name, $Width, $Height, $scale.ToString($inv), $m[0].ToString('0.0000', $inv), $m[1].ToString('0.00', $inv)
}
