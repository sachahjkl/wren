# An experimental build of Wren, ready to hand out: built as a release (the amber one) with a label, the development licence key
# accepted (so the demonstration licence shows its card with no setting), a demonstration licence, notes made from the CHANGELOG, a
# zip, and the link of its upload to buzzheavier (anonymous: the link lives a few days).
#
#   powershell -File tools\experimental.ps1                  build, check, pack, upload
#   powershell -File tools\experimental.ps1 -NoUpload        everything but the upload
#   powershell -File tools\experimental.ps1 -NoBuild         pack what build\wren.exe is (a release built with the label)
#   -Label experimental-2026-10-25   the label after the version (default: experimental-<today>)
#   -Notes file.md                   known limits to put in the notes, instead of the default ones
#   -Vault dir|none                  where a copy of the zip, the notes and the link are kept (default: the vault's folder; none: no copy)
#
# What it does, in order: build.bat release with WREN_VERSION_LABEL and WREN_ACCEPT_DEV_LICENSE_KEY (build.bat); tools\package.ps1
# (the one file wren-<version>-<label>-windows-x64.exe and its SHA-256); a demonstration licence made with the development key
# (tools\license.ps1 issue -dev); a check on the packed exe itself (it starts with a throwaway profile on about:wren with that licence
# and the card must be there: a build that does not accept the key fails here, not in the hands of whoever gets it); the notes; the zip
# (exe, notes, the licence file and its key as one line, the SHA-256); the upload. Needs the toolchain on the PATH as for build.bat.
param(
    [string]$Label = ('experimental-' + (Get-Date -Format 'yyyy-MM-dd')),
    [switch]$NoBuild,
    [switch]$NoUpload,
    [switch]$NoVerify,
    [string]$Notes = '',
    [string]$Vault = 'E:\Drive\Privaté\notes\Notes de Sacha\OpenCode\2026-10-22 - Worktrees Wren et page support\Release experimentale'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if ($Label -notmatch '^[A-Za-z0-9._-]+$') { throw "the label is letters, digits, '.', '_' and '-' only: $Label" }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Say([string]$m) { "[{0,4:N0} s] {1}" -f $sw.Elapsed.TotalSeconds, $m }

$version = ([regex]::Match((Get-Content src\browser\about.odin -Raw), 'APP_VERSION\s*::\s*"([^"]+)"')).Groups[1].Value
if (-not $version) { throw 'APP_VERSION not found in src\browser\about.odin' }
$base = "wren-$version-$Label-windows-x64"
$out = Join-Path $root 'build\experimental'
$stage = Join-Path $out $base
$commit = (git rev-parse --short HEAD).Trim()
$dirty = (git status --porcelain | Where-Object { $_ -notmatch 'mutation_class\.wasm' }).Count -gt 0

# ---- 1. build and package
if (-not $NoBuild) {
    Say "build.bat release ($version-$Label, the development licence key accepted)"
    $env:WREN_VERSION_LABEL = $Label
    $env:WREN_ACCEPT_DEV_LICENSE_KEY = '1'
    try {
        cmd /c "build.bat release 2>&1" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "build.bat release failed ($LASTEXITCODE)" }
        Say 'tools\package.ps1'
        Remove-Item build\dist -Recurse -Force -ErrorAction SilentlyContinue
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\package.ps1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "package.ps1 failed ($LASTEXITCODE)" }
    } finally {
        Remove-Item Env:WREN_VERSION_LABEL, Env:WREN_ACCEPT_DEV_LICENSE_KEY -ErrorAction SilentlyContinue
    }
}
$exeSrc = Join-Path $root "build\dist\$base.exe"
if (-not (Test-Path $exeSrc)) { throw "$exeSrc is not there (a build with another label? run without -NoBuild)" }
$pv = (Get-Item $exeSrc).VersionInfo.ProductVersion
if ($pv -notlike "*$Label*") { throw "the exe says ProductVersion '$pv', not '$Label'" }
$sha = (Get-FileHash $exeSrc -Algorithm SHA256).Hash.ToLower()
Say ("{0}  {1:N1} MB  sha256 {2}" -f (Split-Path $exeSrc -Leaf), ((Get-Item $exeSrc).Length / 1MB), $sha.Substring(0, 12))

# ---- 2. the demonstration licence, made with the development key
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$stage\demo-licence" | Out-Null
Copy-Item $exeSrc "$stage\$base.exe"
$licFile = "$stage\demo-licence\WREN-DEMO.wrenlicense"
$order = 'WREN-DEMO-' + (Get-Date -Format 'yyyyMMdd')
powershell -NoProfile -ExecutionPolicy Bypass -File tools\license.ps1 issue -dev -name 'Demo Supporter' -email 'demo@example.org' -edition supporter -order $order -out $licFile | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $licFile)) { throw 'making the demonstration licence failed' }
$key = ((Get-Content $licFile | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\s*#' }) -join '').Trim()
[IO.File]::WriteAllText("$stage\demo-licence\key.txt", $key + "`r`n", (New-Object Text.UTF8Encoding $false))
Say "demonstration licence $order"

# ---- 3. the packed exe itself must show the card
if (-not $NoVerify) {
    Say 'checking the packed exe: about:wren with the demonstration licence'
    . .\tools\wrenctl.ps1
    $env:WREN_EXE = "$stage\$base.exe"
    $prof = Join-Path $env:TEMP ('wren-exp-check-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $null = Start-Wren -Size 1000x1100 -ProfileDir $prof -Pref @("browser.license.path=$licFile") -Url about:wren
        Start-Sleep 2
        $r = Wren-Eval '(document.getElementById("lic") ? "card" : "no card") + "|" + document.title'
        if ($r -notlike '*card*' -or $r -like '*no card*') { throw "the packed exe does not show the licence card (it says: $r): it does not accept the development key" }
        Say "the card shows ($r)"
    } finally {
        try { Stop-Wren } catch { }
        Remove-Item $prof -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:WREN_EXE -ErrorAction SilentlyContinue
    }
}

# ---- 4. the notes: what is new (the CHANGELOG's Unreleased, titles only) and what to know
$titles = @{}
$section = ''
foreach ($l in Get-Content CHANGELOG.md) {
    if ($l -match '^## ') { if ($section -ne '') { break }; if ($l -match '^## Unreleased') { $section = '-' }; continue }
    if ($section -eq '') { continue }
    if ($l -match '^### (.+)$') { $section = $Matches[1].Trim(); if (-not $titles.ContainsKey($section)) { $titles[$section] = New-Object Collections.Generic.List[string] }; continue }
    if ($section -ne '-' -and $l -match '^- \*\*(.+?)\*\*') {
        $t = ($Matches[1] -replace '`', '' -replace '\s+', ' ').Trim().TrimEnd('.', ':')
        if ($t.Length -gt 150) { $t = $t.Substring(0, 147) + '...' }
        $titles[$section].Add($t)
    }
}
$known = @'
- The exe is not signed: Windows SmartScreen or an antivirus may warn on the first start ("More info", then "Run anyway"). Its SHA-256 is below.
- Windows 10 or 11, 64 bits. Nothing else to install.
- This build trusts the development key of the licences (public, worth nothing): the demonstration licence below shows the card, a real licence will not be accepted by it. A release never accepts that key.
- It shares %APPDATA%\Wren with any other Wren: start it with `--profile <folder>` to keep it apart.
- With a fresh profile the content blocker compiles its lists at the first start: the first page can wait a few seconds (up to 20) before it loads.
- Experimental means what it says: it is the current state of the work, tested by the project's checks but not used for long. Crashes leave a report in %APPDATA%\Wren\crashes.
'@
if ($Notes -ne '') { $known = Get-Content $Notes -Raw }
$nb = New-Object Text.StringBuilder
[void]$nb.AppendLine("Wren $version, $Label")
[void]$nb.AppendLine(('=' * ("Wren $version, $Label").Length))
[void]$nb.AppendLine("Built $(Get-Date -Format 'yyyy-MM-dd HH:mm') from commit $commit$(if ($dirty) { ' (with uncommitted changes)' })")
[void]$nb.AppendLine('')
[void]$nb.AppendLine('To try it')
[void]$nb.AppendLine('---------')
[void]$nb.AppendLine("1. Run $base.exe (nothing to install).")
[void]$nb.AppendLine('2. Open about:wren in the address bar. To see the licence card, paste the one line of demo-licence\key.txt in the box and press Register,')
[void]$nb.AppendLine('   or open demo-licence\WREN-DEMO.wrenlicense with Wren, or drop that file on its window. The licence is made out to "Demo Supporter".')
[void]$nb.AppendLine('3. The card follows the pointer; the sheen crosses it every few seconds.')
[void]$nb.AppendLine('')
[void]$nb.AppendLine('To know')
[void]$nb.AppendLine('-------')
[void]$nb.AppendLine($known.TrimEnd())
[void]$nb.AppendLine('')
foreach ($s in 'Added', 'Changed', 'Fixed') {
    if ($titles.ContainsKey($s) -and $titles[$s].Count -gt 0) {
        [void]$nb.AppendLine("$s since the last release ($($titles[$s].Count))")
        [void]$nb.AppendLine(('-' * ("$s since the last release ($($titles[$s].Count))").Length))
        foreach ($t in $titles[$s]) { [void]$nb.AppendLine("- $t") }
        [void]$nb.AppendLine('')
    }
}
[void]$nb.AppendLine('SHA-256')
[void]$nb.AppendLine('-------')
[void]$nb.AppendLine("$sha  $base.exe")
$notesText = $nb.ToString()
[IO.File]::WriteAllText("$stage\README.txt", $notesText, (New-Object Text.UTF8Encoding $false))
[IO.File]::WriteAllText("$stage\SHA256.txt", "$sha  $base.exe`r`n", (New-Object Text.UTF8Encoding $false))
Say ("notes: {0} lines, {1} titles from the CHANGELOG" -f ($notesText -split "`n").Count, (($titles.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum))

# ---- 5. the zip
$zip = Join-Path $out "$base.zip"
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path "$stage\*" -DestinationPath $zip -CompressionLevel Optimal
$zipSha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Say ("{0}  {1:N1} MB  sha256 {2}" -f (Split-Path $zip -Leaf), ((Get-Item $zip).Length / 1MB), $zipSha.Substring(0, 12))

# ---- 6. the upload (anonymous: PUT to w.buzzheavier.com, the link is buzzheavier.com/<id>)
$link = ''
if (-not $NoUpload) {
    Say 'uploading to buzzheavier'
    $resp = & curl.exe -sS --fail --max-time 1800 -T $zip "https://w.buzzheavier.com/$(Split-Path $zip -Leaf)" 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "the upload failed ($LASTEXITCODE): $resp" }
    $id = ''
    try { $j = $resp | ConvertFrom-Json; if ($j.data -and $j.data.id) { $id = [string]$j.data.id } elseif ($j.id) { $id = [string]$j.id } } catch { }
    if (-not $id) { throw "the upload answered something with no file id: $resp" }
    $link = "https://buzzheavier.com/$id"
    # what is there must be what was sent
    $head = & curl.exe -sSIL --max-time 60 $link 2>&1 | Out-String
    if ($head -notmatch 'HTTP/\S+ 200') { Say "WARNING: the link does not answer 200 yet ($($head.Split("`n")[0].Trim()))" } else { Say 'the link answers 200' }
}

# ---- 7. a copy where the notes of the session live
if ($Vault -ne '' -and $Vault -ne 'none' -and (Test-Path (Split-Path $Vault -Parent))) {
    $dest = Join-Path $Vault (Get-Date -Format 'yyyy-MM-dd HHmm')
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item $zip $dest
    Copy-Item "$stage\README.txt" "$dest\NOTES.txt"
    $info = "$base`r`nzip sha256: $zipSha`r`nexe sha256: $sha`r`ncommit: $commit`r`nlink: $link`r`n"
    [IO.File]::WriteAllText("$dest\LIEN.txt", $info, (New-Object Text.UTF8Encoding $false))
    Say "copy in $dest"
}

''
"zip   : $zip"
"sha256: $zipSha"
if ($link) { "link  : $link" } else { 'link  : (not uploaded)' }
