# Makes the release packages of Wren from a finished build (build.bat release) in build\dist: two archives and the
# SHA-256 of both in SHA256SUMS.txt.
#   wren-<version>-windows-x64.zip          the program: wren.exe, vcruntime140.dll, the licenses and a README. Nothing else:
#                                           this is what to download, run, and what Setup installs.
#   wren-<version>-windows-x64-extras.zip   the demo and test material, for whoever wants it: the demo pages (demos\), the
#                                           script loading and web API demos (examples\), the test server (testserver.exe, a
#                                           Go program) and demo.bat. Its files sit at the root of the archive: extract it
#                                           into the folder of wren.exe, where about:demos looks for demos\ first
#                                           (src\browser\demos.odin) and where testserver.exe serves /site/ from
#                                           (tools\testserver\site.go).
#   powershell -NoProfile -File tools\package.ps1 [-Version 0.2.0]
# The version defaults to APP_VERSION of src\browser\about.odin; a release tag vX.Y.Z must match it (release.yml checks).
# The JavaScript engine is not a file of its own: its pre-initialized image is embedded in wren.exe (src\js\image).
# -Dev packages a development build (CI's smoke test) as wren-<version>-dev-windows-x64[-extras].zip; without it, the build
# must be a release one (build.bat release, written in build\wren.channel).
# Signing: when SIGN_PFX or SIGN_SERVICE is set (see tools\sign.ps1), every executable (wren.exe, testserver.exe) is signed
# before it is archived; otherwise the files are left as they are.
param([string]$Version = '', [switch]$Dev)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

if (-not $Version) {
    $m = Select-String -Path src\browser\about.odin -Pattern 'APP_VERSION\s*::\s*"([^"]+)"'
    if (-not $m) { throw 'APP_VERSION not found in src\browser\about.odin' }
    $Version = $m.Matches[0].Groups[1].Value
}
if (-not (Test-Path build\wren.exe)) { throw 'build\wren.exe is missing: run build.bat release first' }
# a package is a release: never a development build (blueprint icon, "development build" in the browser)
$channel = if (Test-Path build\wren.channel) { [IO.File]::ReadAllText("$root\build\wren.channel").Trim() } else { '' }
if ($Dev) {
    if ($channel -ne 'dev') { throw "build\wren.exe is a '$channel' build, not a development one (-Dev)" }
} elseif ($channel -ne 'release') { throw "build\wren.exe is a '$channel' build, not a release one: run build.bat release first" }

$name = if ($Dev) { "wren-$Version-dev-windows-x64" } else { "wren-$Version-windows-x64" }
$dist = Join-Path $root 'build\dist'
$out = Join-Path $dist $name
$extras = Join-Path $dist "$name-extras"
foreach ($d in $out, $extras) { if (Test-Path $d) { [IO.Directory]::Delete($d, $true) } }   # build\dist holds only what this script makes (no junction)
New-Item -ItemType Directory -Force $out, "$out\licenses", $extras | Out-Null

# the Wasm modules the demo pages load (<script type="application/wasm">, workers), and the server for the others
$guests = 'counter', 'formstest', 'mutation', 'mutation_class', 'workerstest_worker'
foreach ($g in $guests) {
    odin build "examples/$g" -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator -collection:web=sdk/odin -out:"examples/site/$g.wasm" -o:size
    if ($LASTEXITCODE -ne 0) { throw "building examples/$g failed" }
}
if (-not (Select-String -Path examples\site\index.html -Pattern 'Made from the DEMOS table' -Quiet)) { throw 'examples\site\index.html is not the demos index (src\browser\demos_index.odin)' }
# every module a page names must be there (a page added later with a new guest fails here, not in the user's hands)
foreach ($page in Get-ChildItem examples\site -Recurse -Filter *.html) {
    $html = [IO.File]::ReadAllText($page.FullName)
    foreach ($m in [regex]::Matches($html, 'src="([^"/:]+\.wasm)"')) {
        $wasm = Join-Path $page.DirectoryName $m.Groups[1].Value
        if (-not (Test-Path $wasm)) { throw "$($page.Name) loads $($m.Groups[1].Value), which is not built" }
    }
}
Push-Location tools\testserver
try { go build -trimpath -o ..\..\build\testserver.exe .; if ($LASTEXITCODE -ne 0) { throw 'go build of the test server failed' } } finally { Pop-Location }

Copy-Item build\wren.exe "$out\wren.exe"
Copy-Item build\testserver.exe "$extras\testserver.exe"
# signed before they are archived (nothing happens unless a signing identity is configured: tools\sign.ps1)
& (Join-Path $PSScriptRoot 'sign.ps1') -Files "$out\wren.exe", "$extras\testserver.exe"
if ($LASTEXITCODE) { throw 'signing failed' }

# the extras: demo pages, and the demos that need the test server
Copy-Item -Recurse examples\site "$extras\demos"
# the script loading and web API demos of about:demos: testserver.exe serves them from examples\ under its working
# directory (tools\testserver\jsload.go, jsweb.go), which demo.bat makes the folder of wren.exe
New-Item -ItemType Directory -Force "$extras\examples\jsweb" | Out-Null
Copy-Item -Recurse examples\jsload "$extras\examples\jsload"
Copy-Item examples\jsweb\demo.html "$extras\examples\jsweb\demo.html"

# vcruntime140.dll from the Visual C++ redistributable of the installed toolset
$redist = $env:VCToolsRedistDir   # set in a developer prompt: the redistributable of the toolset that linked the exe
if (-not $redist) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $redist = Join-Path (& $vswhere -latest -products * -property installationPath) 'VC\Redist\MSVC'
}
$crt = Get-ChildItem $redist -Recurse -Filter vcruntime140.dll |
    Where-Object { $_.FullName -match '\\[\d.]+\\x64\\Microsoft\.VC\d+\.CRT\\' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $crt) { throw 'vcruntime140.dll (x64) not found in the Visual Studio redistributable' }
Copy-Item $crt.FullName "$out\vcruntime140.dll"

Copy-Item LICENSE "$out\LICENSE.txt"
Copy-Item THIRD_PARTY.md "$out\THIRD_PARTY.md"
Copy-Item build\wasmtime\LICENSE "$out\licenses\wasmtime-LICENSE.txt"
Copy-Item ext\lexbor\LICENSE "$out\licenses\lexbor-LICENSE.txt"
Copy-Item ext\lexbor\NOTICE "$out\licenses\lexbor-NOTICE.txt"
Copy-Item ext\gui_toolkit\LICENSE "$out\licenses\gui_toolkit-LICENSE.txt"
Copy-Item ext\gui_toolkit\NOTICE.md "$out\licenses\gui_toolkit-NOTICE.md"
Copy-Item ext\gui_toolkit\font\slug_ref\LICENSE-MIT "$out\licenses\Slug-LICENSE-MIT.txt"
Copy-Item ext\gui_toolkit\font\data\Roboto-LICENSE.txt "$out\licenses\Roboto-LICENSE.txt"
Copy-Item ext\gui_toolkit\font\data\Inconsolata-OFL.txt "$out\licenses\Inconsolata-OFL.txt"
Copy-Item ext\gui_toolkit\font\data\NotoColorEmoji-OFL.txt "$out\licenses\NotoColorEmoji-OFL.txt"
# the JavaScript engine embedded in wren.exe (QuickJS-ng and the wasi-libc Zig links into it) and webref's Web IDL
Copy-Item native\js\licenses\* "$out\licenses\"

# every Rust crate linked into wren_media.lib, with its license and source (cargo metadata of the locked graph)
$ErrorActionPreference = 'Continue'   # cargo reports progress on stderr ("Updating crates.io index")
$json = & cargo metadata --manifest-path native\media\Cargo.toml --format-version 1 --locked 2>$null
$ok = $LASTEXITCODE -eq 0
$ErrorActionPreference = 'Stop'
if (-not $ok -or -not $json) { throw 'cargo metadata failed' }
$meta = $json | ConvertFrom-Json
$lines = @('Rust crates of native/media (wren_media.lib, linked into wren.exe), from Cargo.lock: the whole graph, with the',
           'build-time and test-only crates (they are not in wren.exe).',
           'Each crate''s license text is in its source package (crates.io) or repository.', '')
foreach ($p in ($meta.packages | Where-Object { $_.name -ne 'wren_media' } | Sort-Object name, version)) {
    $lines += ('{0} {1}  [{2}]  {3}' -f $p.name, $p.version, $p.license, $(if ($p.repository) { $p.repository } else { "https://crates.io/crates/$($p.name)" }))
}
[IO.File]::WriteAllLines("$out\licenses\rust-crates.txt", $lines)

$commit = (& git rev-parse --short HEAD 2>$null)
$readme = @"
Wren $Version for Windows x64 ($commit)
A small web browser where WebAssembly runs everything, JavaScript included.
https://github.com/sachahjkl/wren

  wren.exe [URL]            the browser (needs Windows 10 or 11 x64 and a Direct3D 11 GPU)

Run wren.exe from here, or open the Setup dialog to install it (wren.exe --setup: Start menu, desktop shortcut, PATH,
the entry in Settings > Apps > Default apps, daily check for updates; "Use standalone" keeps it as it is). A file
wren.portable beside wren.exe makes a portable copy: its profile is the folder data beside it.

The demo and test pages, the examples and the test server are a separate download, wren-$Version-windows-x64-extras.zip
(https://github.com/sachahjkl/wren/releases): extract it into this folder, then about:demos opens the pages and demo.bat
starts the server for those that need it.

Options: --profile DIR (default %APPDATA%\Wren), --pref name=value (any setting of about:config), --policy FILE,
--desktop-integration=install|remove|status (the Start menu shortcut and the entry in Settings > Apps > Default apps:
the same as the box in about:config; run it with `start /wait` or Start-Process -Wait to get the exit code: 0 done or
installed, 1 failed or absent, 2 to repair), --setup, --new-window (a window of its own: by default a second start with
the same profile opens a tab in the running Wren).
The address bar takes paths (C:\..., \\server\share) as well as URLs; a folder opens its index.html, else the list of its
files; files and folders dropped on the window open.
Keys: Ctrl+T / Ctrl+W tabs, Ctrl+L address, Ctrl+F find, Ctrl+U view source, Ctrl+B status bar,
Ctrl+Shift+B frame statistics, Ctrl+Plus / Minus / 0 zoom, F11 full screen, F12 developer tools.

JavaScript runs in QuickJS-ng compiled to WebAssembly, inside wren.exe (no separate file): javascript.enabled in
about:config turns it off, javascript.sites.disabled / .enabled per site. Pages can also be WebAssembly modules.

Wren is a prototype: part of the web platform is missing. MIT license (LICENSE.txt); the components it is built from are
listed in THIRD_PARTY.md, their licenses are in licenses\. vcruntime140.dll is the Microsoft Visual C++ runtime.
"@
[IO.File]::WriteAllText("$out\README.txt", ($readme -replace "`r?`n", "`r`n"))

$extrasReadme = @"
Wren ${Version}: demos and test material ($commit)
Extract this archive into the folder of wren.exe (the files here are meant to sit beside it).

  demos\                    the demo and test pages and their Wasm modules; demos\index.html lists them (so does
                            about:demos, linked from the start page)
  examples\                 the script loading and web API demos, served by testserver.exe
  testserver.exe            the demo server: http://127.0.0.1:8765/site/ (serves demos\)
  demo.bat                  starts the demo server and opens about:demos

The pages of demos\ open directly; those marked "test server" need testserver.exe running from this folder, as demo.bat
does (images, media, form submission, slow stylesheets, CSP, script loading, web APIs). browser.demos.path in about:config
points about:demos to another folder.
"@
[IO.File]::WriteAllText("$extras\README-extras.txt", ($extrasReadme -replace "`r?`n", "`r`n"))
$demo = @"
@echo off
:: Serves the demo pages (demos\) on http://127.0.0.1:8765 and opens about:demos in Wren. Close the server window to stop it.
cd /D "%~dp0"
start "Wren demo server" /min testserver.exe
start "" wren.exe about:demos
"@
[IO.File]::WriteAllText("$extras\demo.bat", ($demo -replace "`r?`n", "`r`n"))

# the program in a folder of its own name; the extras at the root of their archive (to extract beside wren.exe)
$zip = Join-Path $dist "$name.zip"
$zipExtras = Join-Path $dist "$name-extras.zip"
foreach ($z in $zip, $zipExtras) { if (Test-Path $z) { Remove-Item $z -Force } }
Compress-Archive -Path $out -DestinationPath $zip -CompressionLevel Optimal
Compress-Archive -Path "$extras\*" -DestinationPath $zipExtras -CompressionLevel Optimal
$sums = foreach ($z in $zip, $zipExtras) { "$((Get-FileHash $z -Algorithm SHA256).Hash.ToLower())  $(Split-Path $z -Leaf)" }
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"))
foreach ($z in $zip, $zipExtras) { "packaged $z ($([math]::Round((Get-Item $z).Length / 1MB, 1)) MB)" }