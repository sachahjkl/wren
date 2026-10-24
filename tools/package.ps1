# Makes the release file of Wren from a finished build (build.bat release) in build\dist, and its SHA-256 in SHA256SUMS.txt:
#   wren-<version>-windows-x64.exe          the program, one file, which is what the release publishes: nothing to unzip and
#                                           nothing beside it. It carries its own licenses (about:licenses), its version and
#                                           publisher (the file's Details), and the Visual C++ runtime it needs; Windows 10 and
#                                           11 bring the rest. Run it, or install it with wren.exe --setup. The other platforms
#                                           will be one such file each (wren-<version>-<os>-<arch>).
#   powershell -NoProfile -File tools\package.ps1 [-Version 0.2.0] [-Extras]
# The version defaults to APP_VERSION of src\browser\about.odin; a release tag vX.Y.Z must match it (release.yml checks).
# The JavaScript engine is not a file of its own: its pre-initialized image is embedded in wren.exe (src\js\image).
# -Dev packages a development build (CI's smoke test) as wren-<version>-dev-windows-x64.exe; without it, the build must be
# a release one (build.bat release, written in build\wren.channel).
# -Extras also makes wren-<version>-windows-x64-extras.zip, for someone who wants the demo material without a checkout of the
# repository: the demo pages (demos\), the script loading and web API demos (examples\), the test server (testserver.exe, a
# Go program: tools\testserver) and demo.bat, at the root of the archive, to extract into the folder of the program (named
# wren.exe there). The release does not publish it: those files belong to the repository (examples\site, tools\testserver).
# Signing: when SIGN_PFX or SIGN_SERVICE is set (see tools\sign.ps1), every executable is signed before it is published;
# otherwise the files are left as they are.
param([string]$Version = '', [switch]$Dev, [switch]$Extras)
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

# the list of Rust crates wren.exe embeds (about:licenses) is the one Cargo.lock says
& (Join-Path $PSScriptRoot 'rust_crates.ps1') -Check
if ($LASTEXITCODE) { throw 'rust-crates.txt is out of date' }
# the program needs no file beside it: no import of the Visual C++ runtime DLLs
$dumpbin = Get-ChildItem "${env:ProgramFiles}\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Microsoft Visual Studio" -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'Hostx64\\x64' } | Select-Object -First 1 -ExpandProperty FullName
if ($dumpbin) {
    $deps = & $dumpbin /dependents build\wren.exe | Select-String -Pattern '^\s+(\S+\.dll)\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
    $bad = $deps | Where-Object { $_ -match '^(vcruntime|msvcp|vcomp|concrt|ucrtbase)' }
    if ($bad) { throw "wren.exe imports $($bad -join ', '): the release must carry its runtime (build.bat links libvcruntime)" }
}

$label = if ($env:WREN_VERSION_LABEL) { "-" + ($env:WREN_VERSION_LABEL -replace '[^A-Za-z0-9._-]', '-') } else { "" }   # build.bat: WREN_VERSION_LABEL
$name = if ($Dev) { "wren-$Version$label-dev-windows-x64" } else { "wren-$Version$label-windows-x64" }
$dist = Join-Path $root 'build\dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$exe = Join-Path $dist "$name.exe"
Copy-Item build\wren.exe $exe -Force
$files = @($exe)
$toSign = @($exe)

if ($Extras) {
    $extrasDir = Join-Path $dist "$name-extras"
    if (Test-Path $extrasDir) { [IO.Directory]::Delete($extrasDir, $true) }   # build\dist holds only what this script makes (no junction)
    New-Item -ItemType Directory -Force $extrasDir | Out-Null

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
    Copy-Item build\testserver.exe "$extrasDir\testserver.exe"
    $toSign += "$extrasDir\testserver.exe"

    Copy-Item -Recurse examples\site "$extrasDir\demos"
    # the script loading and web API demos of about:demos: testserver.exe serves them from examples\ under its working
    # directory (tools\testserver\jsload.go, jsweb.go), which demo.bat makes the folder of wren.exe
    New-Item -ItemType Directory -Force "$extrasDir\examples\jsweb" | Out-Null
    Copy-Item -Recurse examples\jsload "$extrasDir\examples\jsload"
    Copy-Item examples\jsweb\demo.html "$extrasDir\examples\jsweb\demo.html"
    $commit = (& git rev-parse --short HEAD 2>$null)
    $readme = @"
Wren ${Version}: demos and test material ($commit)
Extract this archive into the folder of wren.exe (the files here are meant to sit beside it; name the program wren.exe).

  demos\                    the demo and test pages and their Wasm modules; demos\index.html lists them (so does about:demos)
  examples\                 the script loading and web API demos, served by testserver.exe
  testserver.exe            the demo server: http://127.0.0.1:8765/site/ (serves demos\)
  demo.bat                  starts the demo server and opens about:demos (it starts wren.exe)

The pages of demos\ open directly; those marked "test server" need testserver.exe running from this folder, as demo.bat
does (images, media, form submission, slow stylesheets, CSP, script loading, web APIs). browser.demos.path in about:config
points about:demos to another folder.
"@
    [IO.File]::WriteAllText("$extrasDir\README-extras.txt", ($readme -replace "`r?`n", "`r`n"))
    $demo = @"
@echo off
:: Serves the demo pages (demos\) on http://127.0.0.1:8765 and opens about:demos in Wren. Close the server window to stop it.
cd /D "%~dp0"
start "Wren demo server" /min testserver.exe
start "" wren.exe about:demos
"@
    [IO.File]::WriteAllText("$extrasDir\demo.bat", ($demo -replace "`r?`n", "`r`n"))
}

# signed before they are published (nothing happens unless a signing identity is configured: tools\sign.ps1)
& (Join-Path $PSScriptRoot 'sign.ps1') -Files $toSign
if ($LASTEXITCODE) { throw 'signing failed' }

if ($Extras) {
    $zipExtras = Join-Path $dist "$name-extras.zip"
    if (Test-Path $zipExtras) { Remove-Item $zipExtras -Force }
    Compress-Archive -Path "$extrasDir\*" -DestinationPath $zipExtras -CompressionLevel Optimal   # at the root of the archive
    $files += $zipExtras
}
$sums = foreach ($z in $files) { "$((Get-FileHash $z -Algorithm SHA256).Hash.ToLower())  $(Split-Path $z -Leaf)" }
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"))
foreach ($z in $files) { "packaged $z ($([math]::Round((Get-Item $z).Length / 1MB, 1)) MB)" }
