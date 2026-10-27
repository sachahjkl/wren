# Checks every Odin package of Wren (src\) and of the toolkit (ext\gui_toolkit) for another target than Windows
# (odin check -no-entry-point -target:<t>) and counts, per package, the errors that are in its own files (an error
# in a dependency is counted once, in the dependency). Prints a table; -Csv writes it; -Fail exits 1 when a package
# listed in -Expect does not pass (the CI's Linux job).
param(
    [string]$Target = 'linux_amd64',
    [string]$Odin = 'odin',
    [string]$Csv = '',
    [string[]]$Only = @(),
    [string]$Expect = '',
    [switch]$Verbose_
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tk = Join-Path $root 'ext\gui_toolkit'

function Get-Packages([string]$base, [string]$prefix) {
    Get-ChildItem $base -Recurse -Filter *.odin -File |
        Where-Object { $_.FullName -notmatch '\\(\.git|build|target|node_modules)\\' } |
        ForEach-Object { $_.DirectoryName } | Sort-Object -Unique |
        ForEach-Object { [pscustomobject]@{ Name = $prefix + $_.Substring($base.Length).TrimStart('\').Replace('\', '/'); Dir = $_ } }
}

$pkgs = @(Get-Packages (Join-Path $root 'src') 'src/') + @(Get-Packages $tk 'toolkit/')
if ($Expect -ne '') { $Only = @(Get-Content $Expect | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() }) }
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Only.Count -gt 0) { $pkgs = $pkgs | Where-Object { $Only -contains $_.Name } }

$errorsByDir = @{}
$results = foreach ($p in $pkgs) {
    $args_ = @('check', $p.Dir, "-target:$Target", '-no-entry-point', "-collection:wb=$root\src",
        "-collection:toolkit=$tk", '-max-error-count:2000', '-define:FONT_NATIVE_LINK=false', '-define:A11Y_NATIVE_LINK=false')
    $out = & cmd /c "`"$Odin`" $($args_ -join ' ') 2>&1"
    $code = $LASTEXITCODE
    $errs = @($out | Where-Object { $_ -match '^(.+?)\((\d+):(\d+)\) (Error|Syntax Error):' })
    $own = 0; $deps = @{}
    foreach ($e in $errs) {
        $null = $e -match '^(.+?)\((\d+):(\d+)\)'
        $file = $Matches[1].Replace('/', '\')
        $dir = Split-Path -Parent $file
        if (-not $errorsByDir.ContainsKey($dir)) { $errorsByDir[$dir] = New-Object System.Collections.Generic.HashSet[string] }
        $null = $errorsByDir[$dir].Add($e)
        if ($dir -eq $p.Dir) { $own++ } else { $deps[$dir] = 1 }
    }
    $depNames = @($deps.Keys | ForEach-Object {
            $d = $_
            if ($d.StartsWith("$root\src")) { 'src/' + $d.Substring("$root\src".Length).TrimStart('\').Replace('\', '/') }
            elseif ($d.StartsWith($tk)) { 'toolkit/' + $d.Substring($tk.Length).TrimStart('\').Replace('\', '/') }
            else { $d }
        } | Sort-Object)
    $status = if ($code -eq 0) { 'ok' } elseif ($own -gt 0) { 'own' } elseif ($errs.Count -gt 0) { 'deps' } else { 'fail' }
    if ($Verbose_ -and $own -gt 0) { $errs | Where-Object { $_.Replace('/', '\').StartsWith($p.Dir + '\') } | Select-Object -First 15 | ForEach-Object { "    $_" } | Write-Host }
    [pscustomobject]@{ Package = $p.Name; Status = $status; Own = $own; Total = $errs.Count; BlockedBy = ($depNames -join ' ') }
}
$results | Format-Table -AutoSize | Out-String -Width 400 | Write-Host
$ok = @($results | Where-Object Status -eq 'ok').Count
Write-Host "$ok / $(@($results).Count) packages pass odin check for $Target"
if ($Csv -ne '') { $results | Export-Csv -NoTypeInformation -Encoding UTF8 $Csv }
if ($Expect -ne '') {
    $bad = @($results | Where-Object Status -ne 'ok')
    if ($bad.Count -gt 0) { Write-Host "FAILED: $($bad.Package -join ', ')"; exit 1 }
}
