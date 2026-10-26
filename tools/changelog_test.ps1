# Tests of tools\changelog.ps1 on a throwaway checkout (a CHANGELOG.md, the file that holds the version, fragments):
# well formed and malformed fragments, -New, -Check (orphans, duplicates, -Release), -Assemble with and without fragments,
# -Migrate, -Section. A few seconds; the CI runs it beside `changelog.ps1 -Check`.
#   powershell -NoProfile -File tools\changelog_test.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $PSScriptRoot 'changelog.ps1'
$utf8 = New-Object Text.UTF8Encoding $false
$failed = 0
function Run([string[]]$a) {
    $ErrorActionPreference = 'Continue'   # a failing run is a case under test, not an error of this script
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $script @a -Root $script:dir 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o }
}
function Expect([bool]$ok, [string]$what, $r = $null) {
    if ($ok) { "PASS $what" } else { $script:failed++; "FAIL $what"; if ($r) { $r.Out } }
}
function Frag([string]$name, [string]$text) { [IO.File]::WriteAllText((Join-Path $script:dir "changelog.d\$name"), $text, $utf8) }
function Fresh {
    $script:dir = Join-Path ([IO.Path]::GetTempPath()) ('changelog-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force (Join-Path $script:dir 'changelog.d') | Out-Null
    # the repository's own file that holds the version, so that -Assemble -Version writes into a copy of it
    $vsrc = Get-Content -Raw (Join-Path $root 'tools\changelog.ps1')
    $m = [regex]::Match($vsrc, "Join-Path \`$Root '([^']+)'")
    $vf = $m.Groups[1].Value
    New-Item -ItemType Directory -Force (Split-Path (Join-Path $script:dir $vf)) | Out-Null
    Copy-Item (Join-Path $root $vf) (Join-Path $script:dir $vf)
    $script:vfile = Join-Path $script:dir $vf
    # the last released version is the one the sources say, as on master
    $script:base = [regex]::Match([IO.File]::ReadAllText($script:vfile), 'VERSION\s*::\s*"([^"]+)"').Groups[1].Value
    $head = if ($vsrc -match "Unreleased\s+=\s+'## Unreleased'") { "## Unreleased`r`n`r`n" } else { '' }
    $hd = if ($vsrc -match "Heading\s+=\s+'## \[") { "## [$base] - 2026-01-01" } else { "## $base - 2026-01-01" }
    [IO.File]::WriteAllText((Join-Path $script:dir 'CHANGELOG.md'), "# Changelog`r`n`r`nIntro.`r`n`r`n$head$hd`r`n`r`n### Added`r`n- **Old thing**: shipped.`r`n", $utf8)
}
$dirs = @()
try {
    # ---- no fragment at all
    Fresh; $dirs += $dir
    $r = Run '-Check'; Expect ($r.Code -eq 0 -and $r.Out -match '0 fragments') 'no fragment: -Check passes' $r
    $r = Run '-Assemble'; Expect ($r.Code -eq 0 -and $r.Out.Trim() -eq '') 'no fragment: the preview is empty' $r
    $r = Run '-Assemble', '-Version', '0.2.0'; Expect ($r.Code -ne 0 -and $r.Out -match 'nothing to publish') 'no fragment: -Assemble -Version refuses' $r
    if ((Get-Content -Raw $script) -match 'CheckVersion\s+=\s+\$true') {
        # a branch that writes the version itself
        $keep = [IO.File]::ReadAllText($vfile)
        [IO.File]::WriteAllText($vfile, ($keep -replace ('"' + [regex]::Escape($base) + '"'), '"99.0.0"'), $utf8)
        $r = Run '-Check'; Expect ($r.Code -ne 0 -and $r.Out -match 'the version is written when a version is published') 'a version written by a branch fails -Check' $r
        [IO.File]::WriteAllText($vfile, $keep, $utf8)
    }

    # ---- well formed fragments, two of the same subject, LF and CRLF, sub-items
    Frag '20261026-100000-tabs.md' "type: Added`n`n**Tabs in a sidebar**: one.`n"
    $r = Run '-Check'; Expect ($r.Code -eq 0 -and $r.Out -match ': 1 fragments') 'one fragment: -Check counts it' $r
    Frag '20261026-100001-tabs.md' "type: Fixed`r`n**Tabs** no longer flicker.`r`n"
    Frag '20261026-100002-workers.md' "type: changed`n- **Workers**:`n  - one;`n  - two.`n"
    $r = Run '-Check'; Expect ($r.Code -eq 0 -and $r.Out -match '3 fragments') 'three fragments, two of one subject: -Check passes' $r
    $r = Run '-Assemble'
    $want = "### Added`n- **Tabs in a sidebar**: one.`n`n### Changed`n- **Workers**:`n  - one;`n  - two.`n`n### Fixed`n- **Tabs** no longer flicker."
    Expect ($r.Code -eq 0 -and $r.Out.Trim().Replace("`r`n", "`n") -eq $want) 'the preview lists them by type, sub-items kept' $r

    # ---- malformed ones
    Frag '20261026-100003-x.md' "type: Improved`n`nSomething.`n"
    $r = Run '-Check'; Expect ($r.Code -ne 0 -and $r.Out -match "unknown type 'Improved'") 'an unknown type fails -Check' $r
    $r = Run '-Assemble', '-Version', '0.2.0'; Expect ($r.Code -ne 0 -and $r.Out -match 'unknown type') 'and -Assemble -Version' $r
    Remove-Item (Join-Path $dir 'changelog.d\20261026-100003-x.md')
    Frag 'my change.md' "type: Added`n`nA thing.`n"
    $r = Run '-Check'; Expect ($r.Code -ne 0 -and $r.Out -match 'its name is not') 'a badly named fragment fails -Check' $r
    Remove-Item (Join-Path $dir 'changelog.d\my change.md')
    Frag '20261026-100004-two.md' "type: Added`n`n- One.`n- Two.`n"
    $r = Run '-Check'; Expect ($r.Code -ne 0 -and $r.Out -match 'several entries') 'two entries in one fragment fail -Check' $r
    Remove-Item (Join-Path $dir 'changelog.d\20261026-100004-two.md')
    Frag '20261026-100005-notype.md' "Just text.`n"
    $r = Run '-Check'; Expect ($r.Code -ne 0 -and $r.Out -match 'first line is not') 'a fragment without its type fails -Check' $r
    Remove-Item (Join-Path $dir 'changelog.d\20261026-100005-notype.md')
    Frag '20261026-100006-dup.md' "type: Fixed`n`n**Tabs**   no longer flicker.`n"
    $r = Run '-Check'; Expect ($r.Code -ne 0 -and $r.Out -match 'the same text as') 'two fragments with the same text fail -Check' $r
    Remove-Item (Join-Path $dir 'changelog.d\20261026-100006-dup.md')
    Frag '20261026-100007-orphan.md' "type: Added`n`n**Old thing**: shipped.`n"
    $r = Run '-Check'; Expect ($r.Code -ne 0 -and $r.Out -match 'already in a released section') 'a fragment already released (an orphan) fails -Check' $r
    Remove-Item (Join-Path $dir 'changelog.d\20261026-100007-orphan.md')

    # ---- -New
    $r = Run '-New', '-Type', 'Removed', '-Subject', 'Old Pref!', '-Text', 'The `x.y` preference.'
    $made = Get-ChildItem (Join-Path $dir 'changelog.d') -Filter '*-old-pref.md'
    Expect ($r.Code -eq 0 -and $made.Count -eq 1 -and (Get-Content -Raw $made[0].FullName) -match '^type: Removed') '-New writes a well formed fragment' $r
    $r = Run '-New', '-Type', 'Nope', '-Text', 'x'; Expect ($r.Code -ne 0) '-New refuses an unknown type' $r

    # ---- the release: a section, the version written, the fragments gone; -Check -Release; -Section
    $r = Run '-Check', '-Release', '9.9.9'; Expect ($r.Code -ne 0 -and $r.Out -match 'not assembled') '-Check -Release refuses while fragments are left' $r
    $r = Run '-Assemble', '-Version', '9.9.9', '-Date', '2026-10-27'
    $cl = [IO.File]::ReadAllText((Join-Path $dir 'CHANGELOG.md'))
    $left = @(Get-ChildItem (Join-Path $dir 'changelog.d')).Count
    Expect ($r.Code -eq 0 -and $cl -match '(?m)^## \[?9\.9\.9\]? - 2026-10-27\r$' -and $cl.IndexOf('9.9.9') -lt $cl.IndexOf('2026-01-01') -and $left -eq 0) '-Assemble -Version: the section above the last one, the fragments deleted' $r
    $vs = [IO.File]::ReadAllText($vfile)
    Expect ($vs -match '"9\.9\.9"' -and ($vs -notmatch 'VERSION_MINOR' -or $vs -match '(?m)^VERSION_MINOR\s*::\s*9\r?$')) '-Assemble -Version writes the version in the sources'
    Expect (-not ($cl -replace "`r`n", '').Contains("`n")) 'the CHANGELOG keeps its CRLF'
    $r = Run '-Check', '-Release', '9.9.9'; Expect ($r.Code -eq 0) '-Check -Release passes after it' $r
    $r = Run '-Check'; Expect ($r.Code -eq 0) '-Check passes after it' $r
    $r = Run '-Section', '-Version', '9.9.9'; Expect ($r.Code -eq 0 -and $r.Out -match '### Removed' -and $r.Out -notmatch [regex]::Escape($base)) '-Section gives that section only' $r
    $r = Run '-Assemble', '-Version', '9.9.9'; Expect ($r.Code -ne 0) 'a version is not assembled twice' $r

    # ---- -Migrate: what a branch still wrote under "## Unreleased"
    if ((Get-Content -Raw $script) -match "Unreleased\s+=\s+'## Unreleased'") {
        $cl = [IO.File]::ReadAllText((Join-Path $dir 'CHANGELOG.md'))
        $cl = $cl.Replace("## Unreleased`r`n", "## Unreleased`r`n`r`n- Untyped one.`r`n- Untyped two.`r`n`r`n### Fixed`r`n- A fix.`r`n  - its detail.`r`n")
        [IO.File]::WriteAllText((Join-Path $dir 'CHANGELOG.md'), $cl, $utf8)
        $r = Run '-Check'; Expect ($r.Code -eq 0 -and $r.Out -match 'warning: 3 entries') 'entries under Unreleased: a warning' $r
        $r = Run '-Assemble', '-Version', '9.9.10'; Expect ($r.Code -ne 0 -and $r.Out -match "no '### Type'") 'untyped Unreleased entries stop a release' $r
        $r = Run '-Migrate'; Expect ($r.Code -ne 0 -and $r.Out -match 'line 7:') '-Migrate asks the type of untyped entries' $r
        $r = Run '-Migrate', '-DefaultType', 'Added', '-Types', '8=Changed'
        $r2 = Run '-Assemble'
        Expect ($r.Code -eq 0 -and $r2.Out.Trim().Replace("`r`n", "`n") -eq "### Added`n- Untyped one.`n`n### Changed`n- Untyped two.`n`n### Fixed`n- A fix.`n  - its detail.") '-Migrate makes fragments that assemble the same' $r2
        $r = Run '-Check'; Expect ($r.Code -eq 0 -and $r.Out -notmatch 'warning') 'Unreleased is empty after -Migrate' $r
    }
} finally {
    foreach ($d in $dirs + @($dir)) { if ($d -and (Test-Path $d)) { Remove-Item -LiteralPath $d -Recurse -Force } }
}
if ($failed) { "$failed failed"; exit 1 }
'All changelog tests passed'
