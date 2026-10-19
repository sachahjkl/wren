# Makes the release package of Wren from a finished build (build.bat): build\dist\wren-<version>-windows-x64.zip and
# its SHA-256 in build\dist\SHA256SUMS.txt.
#   powershell -NoProfile -File tools\package.ps1 [-Version 0.1.0]
# The demo pages go in demos\ next to wren.exe: that is where about:demos looks for them first (src\browser\demos.odin),
# and where testserver.exe serves /site/ from when it runs outside the repository (tools\testserver\site.go).
# The version defaults to APP_VERSION of src\browser\about.odin; a release tag vX.Y.Z must match it (release.yml checks).
# Contents: wren.exe (build\browser.exe), vcruntime140.dll, demos\ (examples\site with every Wasm module its pages
# load, built here), testserver.exe and demo.bat (starts the server and opens about:demos), README.txt, LICENSE,
# THIRD_PARTY.md and licenses\.
param([string]$Version = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

if (-not $Version) {
    $m = Select-String -Path src\browser\about.odin -Pattern 'APP_VERSION\s*::\s*"([^"]+)"'
    if (-not $m) { throw 'APP_VERSION not found in src\browser\about.odin' }
    $Version = $m.Matches[0].Groups[1].Value
}
if (-not (Test-Path build\browser.exe)) { throw 'build\browser.exe is missing: run build.bat first' }

$name = "wren-$Version-windows-x64"
$dist = Join-Path $root 'build\dist'
$out = Join-Path $dist $name
if (Test-Path $out) { [IO.Directory]::Delete($out, $true) }   # build\dist holds only what this script makes (no junction)
New-Item -ItemType Directory -Force $out, "$out\licenses" | Out-Null

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

Copy-Item build\browser.exe "$out\wren.exe"
Copy-Item build\testserver.exe "$out\testserver.exe"
Copy-Item -Recurse examples\site "$out\demos"

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
Copy-Item ext\gui_toolkit\font\data\Roboto-LICENSE.txt "$out\licenses\Roboto-LICENSE.txt"
Copy-Item ext\gui_toolkit\font\data\Inconsolata-OFL.txt "$out\licenses\Inconsolata-OFL.txt"

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
A small web browser that runs WebAssembly, and nothing else.
https://github.com/sachahjkl/wren

  wren.exe [URL]            the browser (needs Windows 10 or 11 x64 and a Direct3D 11 GPU)
  demo.bat                  starts the demo server and opens about:demos
  testserver.exe            the demo server: http://127.0.0.1:8765/site/ (serves demos\)
  demos\                    the demo and test pages and their Wasm modules; demos\index.html lists them (so does
                            about:demos, linked from the start page)

about:demos and demos\index.html open the pages of demos\ directly; those marked "test server" need testserver.exe
running (images, media, form submission, slow stylesheets, CSP). browser.demos.path in about:config points about:demos
to another folder. The address bar takes paths (C:\..., \\server\share) as well as URLs; a folder opens its
index.html, else the list of its files; files and folders dropped on the window open.

Options: --profile DIR (default %APPDATA%\Wren), --pref name=value (any setting of about:config), --policy FILE.
Keys: Ctrl+T / Ctrl+W tabs, Ctrl+L address, Ctrl+F find, Ctrl+U view source, Ctrl+B status bar,
Ctrl+Shift+B frame statistics, Ctrl+Plus / Minus / 0 zoom, F11 full screen.

Wren is a prototype: pages' JavaScript never runs. MIT license (LICENSE.txt); the components it is built from are
listed in THIRD_PARTY.md, their licenses are in licenses\. vcruntime140.dll is the Microsoft Visual C++ runtime.
"@
[IO.File]::WriteAllText("$out\README.txt", ($readme -replace "`r?`n", "`r`n"))
$demo = @"
@echo off
:: Serves the demo pages (demos\) on http://127.0.0.1:8765 and opens about:demos in Wren. Close the server window to stop it.
cd /D "%~dp0"
start "Wren demo server" /min testserver.exe
start "" wren.exe about:demos
"@
[IO.File]::WriteAllText("$out\demo.bat", ($demo -replace "`r?`n", "`r`n"))

$zip = Join-Path $dist "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $out -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), "$hash  $name.zip`n")
"packaged $zip ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB), sha256 $hash"
