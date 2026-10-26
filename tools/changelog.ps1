# The CHANGELOG is made of fragments: one file per change in changelog.d\, assembled into CHANGELOG.md when a version is
# published. Branches never touch CHANGELOG.md nor the version, so two merges never conflict on them.
#
# A fragment is changelog.d\<yyyyMMdd-HHmmss>-<subject>.md (subject: lowercase letters, digits and '-'):
#     type: Added                       (Added | Changed | Fixed | Removed)
#                                       (a blank line, optional)
#     **What changed**: the one entry, as it will read in the list (no leading "- "); indented "  - " lines are sub-items.
#
#   powershell -File tools\changelog.ps1 -New -Type Added -Subject storage-partitioning -Text "**...**: ..."   writes one
#   powershell -File tools\changelog.ps1 -Check                      every fragment well formed, none already in CHANGELOG.md (CI)
#   powershell -File tools\changelog.ps1 -Check -Release 0.4.0       ready to tag 0.4.0: no fragment left, its section there, the version said
#   powershell -File tools\changelog.ps1 -Assemble [-Out f.md]       what the next version brings (fragments + "## Unreleased"), printed
#   powershell -File tools\changelog.ps1 -Assemble -Version 0.4.0    the release: a "## 0.4.0 - <date>" section in CHANGELOG.md, the
#                                                                    version written in the sources, the fragments deleted
#   powershell -File tools\changelog.ps1 -Section -Version 0.4.0     the body of that version's section (release notes)
#   powershell -File tools\changelog.ps1 -Migrate [-DefaultType Added] [-Types '42=Fixed,57=Changed']
#                                    the entries a branch still wrote under "## Unreleased" become fragments (an entry under a
#                                    "### Type" heading keeps it; another one takes -Types[its line] or -DefaultType)
# -Root dir works on another checkout (tests). Exit code 0 when all is well, 1 otherwise.
param(
    [switch]$New, [switch]$Check, [switch]$Assemble, [switch]$Section, [switch]$Migrate,
    [string]$Version = '', [string]$Release = '', [string]$Date = '',
    [string]$Type = '', [string]$Subject = '', [string]$Text = '',
    [string]$Types = '', [string]$DefaultType = '',
    [string]$Out = '', [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$Root = (Resolve-Path $Root).Path
if ($Out -and -not [IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }   # .NET resolves against the process's folder
# an error the user can act on: one line, a failing exit code, nothing on stderr (PowerShell 5.1 dresses that up as an exception)
function Die([string]$m) { Write-Output "error: $m"; exit 1 }

# ---- what differs between the repositories that carry this script (Wren, gui_toolkit)
$Repo = @{
    Name          = 'Wren'
    Heading       = '## {0} - {1}'                      # a released version's heading: version, date
    HeadingMatch  = '^## (\d+\.\d+\.\d+[^\s]*)'         # finds a released version's heading
    Unreleased    = '## Unreleased'                     # kept, empty, above the released versions ('' when there is none)
    CheckVersion  = $false                              # -Check: the sources' version must be the last released one
}
function Read-SourceVersion {
    $m = [regex]::Match((Read-Text (Join-Path $Root 'src\browser\about.odin')), 'APP_VERSION\s*::\s*"([^"]+)"')
    if (-not $m.Success) { Die 'APP_VERSION not found in src\browser\about.odin' }
    return $m.Groups[1].Value
}
function Write-SourceVersion([string]$v) {
    $p = Join-Path $Root 'src\browser\about.odin'
    $s = Read-Text $p
    $n = [regex]::Replace($s, '(APP_VERSION\s*::\s*")[^"]+(")', ('${1}' + $v + '${2}'))
    if ($n -ne $s) { Write-Text $p $n; "  src\browser\about.odin: APP_VERSION $v" }
}
# ---- end of the repository's part

$TypeNames = 'Added', 'Changed', 'Removed', 'Fixed'   # the order of the subsections of a version
$Dir = Join-Path $Root 'changelog.d'
$ChangelogPath = Join-Path $Root 'CHANGELOG.md'
$NamePattern = '^\d{8}-\d{6}-[a-z0-9]+(-[a-z0-9]+)*\.md$'
$Utf8 = New-Object Text.UTF8Encoding $false

function Read-Text([string]$p) { return [IO.File]::ReadAllText($p, $Utf8) }
function Write-Text([string]$p, [string]$s) { [IO.File]::WriteAllText($p, $s, $Utf8) }
function Split-Lines([string]$s) { return ,($s -split "`r?`n") }
function Canonical-Type([string]$t) {
    foreach ($n in $TypeNames) { if ($n -ieq $t.Trim()) { return $n } }
    return ''
}
$script:Errors = New-Object Collections.Generic.List[string]
$script:Warnings = New-Object Collections.Generic.List[string]
function Fail([string]$m) { $script:Errors.Add($m) }

# A fragment: its type and the text of its entry, or the reasons it is not one.
function Read-Fragment([IO.FileInfo]$f) {
    $r = [pscustomobject]@{ Name = $f.Name; Path = $f.FullName; Type = ''; Lines = @(); Problems = New-Object Collections.Generic.List[string] }
    if ($f.Name -notmatch $NamePattern) { $r.Problems.Add('its name is not <yyyyMMdd-HHmmss>-<subject>.md (subject: a-z, 0-9 and -)') }
    $lines = Split-Lines (Read-Text $f.FullName)
    $i = 0
    while ($i -lt $lines.Count -and $lines[$i].Trim() -eq '') { $i++ }
    if ($i -ge $lines.Count) { $r.Problems.Add('it is empty'); return $r }
    $m = [regex]::Match($lines[$i], '^\s*type\s*:\s*(\S*)\s*$', 'IgnoreCase')
    if (-not $m.Success) { $r.Problems.Add("its first line is not 'type: Added|Changed|Fixed|Removed'"); return $r }
    $r.Type = Canonical-Type $m.Groups[1].Value
    if (-not $r.Type) { $r.Problems.Add("unknown type '$($m.Groups[1].Value)' (Added, Changed, Fixed or Removed)") }
    $body = @($lines[($i + 1)..($lines.Count - 1)] | ForEach-Object { $_.TrimEnd() })
    if ($i + 1 -ge $lines.Count) { $body = @() }
    while ($body.Count -gt 0 -and $body[0] -eq '') { $body = @($body | Select-Object -Skip 1) }
    while ($body.Count -gt 0 -and $body[-1] -eq '') { $body = @($body | Select-Object -SkipLast 1) }
    if ($body.Count -eq 0) { $r.Problems.Add('it has a type but no text'); return $r }
    $body[0] = $body[0] -replace '^- ', ''
    if ($body[0].Trim() -eq '') { $r.Problems.Add('its text is empty') }
    foreach ($l in $body) {
        if ($l -eq '') { $r.Problems.Add('a blank line inside its text (one entry: sub-items are indented "  - " lines)'); break }
        if ($l -match '^#') { $r.Problems.Add('a heading inside its text (the type gives the section)'); break }
        if ($l -match '^- ') { $r.Problems.Add('several entries in one fragment (one change per fragment; sub-items are indented "  - ")'); break }
    }
    $r.Lines = $body
    return $r
}
function Get-Fragments {
    if (-not (Test-Path $Dir)) { return @() }
    # newest first: a version lists its latest changes at the top
    return @(Get-ChildItem $Dir -File | Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name -Descending | ForEach-Object { Read-Fragment $_ })
}

# The CHANGELOG: its lines, the span of "## Unreleased" and the entries written there.
function Read-Changelog {
    $text = Read-Text $ChangelogPath
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = Split-Lines $text
    $c = [pscustomobject]@{ NL = $nl; Lines = $lines; UStart = -1; UEnd = -1; Entries = New-Object Collections.Generic.List[object]; FirstRelease = -1 }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($c.FirstRelease -lt 0 -and $lines[$i] -match $Repo.HeadingMatch) { $c.FirstRelease = $i }
    }
    if ($Repo.Unreleased) {
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].TrimEnd() -eq $Repo.Unreleased) { $c.UStart = $i; break } }
        if ($c.UStart -ge 0) {
            $c.UEnd = $lines.Count
            for ($i = $c.UStart + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^## ') { $c.UEnd = $i; break } }
            $type = ''; $cur = $null
            for ($i = $c.UStart + 1; $i -lt $c.UEnd; $i++) {
                $l = $lines[$i].TrimEnd()
                if ($l -match '^### (.+)$') {
                    $cur = $null; $type = Canonical-Type $Matches[1]
                    if (-not $type) { Fail ("CHANGELOG.md line {0}: unknown subsection '{1}' under {2}" -f ($i + 1), $l, $Repo.Unreleased) }
                    continue
                }
                if ($l -match '^- ') { $cur = [pscustomobject]@{ Line = $i + 1; Type = $type; Lines = New-Object Collections.Generic.List[string] }; $cur.Lines.Add($l.Substring(2)); $c.Entries.Add($cur); continue }
                if ($l -eq '') { $cur = $null; continue }
                if ($cur) { $cur.Lines.Add($l) } else { Fail ("CHANGELOG.md line {0}: text under {1} that is not an entry ('- ...')" -f ($i + 1), $Repo.Unreleased) }
            }
        }
    }
    return $c
}

function Render-Body($items) {
    $out = New-Object Collections.Generic.List[string]
    foreach ($t in $TypeNames) {
        $of = @($items | Where-Object { $_.Type -eq $t })
        if ($of.Count -eq 0) { continue }
        if ($out.Count -gt 0) { $out.Add('') }
        $out.Add("### $t")
        foreach ($e in $of) {
            $first = $true
            foreach ($l in $e.Lines) { if ($first) { $out.Add("- $l"); $first = $false } else { $out.Add($l) } }
        }
    }
    return ,$out
}

function Slug([string]$s) {
    $m = [regex]::Match($s, '\*\*(.+?)\*\*')
    if ($m.Success) { $s = $m.Groups[1].Value }
    $s = $s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $s = ($s -replace '[^a-z0-9]+', '-').Trim('-')
    if ($s.Length -gt 48) { $cut = $s.LastIndexOf('-', 48); $s = $s.Substring(0, $(if ($cut -gt 16) { $cut } else { 48 })).Trim('-') }
    if (-not $s) { $s = 'change' }
    return $s
}
function New-FragmentFile([string]$type, [string[]]$lines, [datetime]$when, [string]$subject, [string]$nl) {
    New-Item -ItemType Directory -Force $Dir | Out-Null
    $stem = '{0}-{1}' -f $when.ToString('yyyyMMdd-HHmmss'), (Slug $subject)
    $name = "$stem.md"; $k = 2
    while (Test-Path (Join-Path $Dir $name)) { $name = "$stem-$k.md"; $k++ }
    $p = Join-Path $Dir $name
    Write-Text $p (((@("type: $type", '') + $lines) -join $nl) + $nl)
    return $p
}

function Entry-Key([string]$first) { return ($first -replace '\s+', ' ').Trim() }

# ---------------------------------------------------------------------------------------------------------------- -New
if ($New) {
    $t = Canonical-Type $Type
    if (-not $t) { Die "-Type is Added, Changed, Fixed or Removed (got '$Type')" }
    if (-not $Text.Trim()) { Die '-Text is the entry' }
    if (-not $Subject) { $Subject = $Text }
    $nl = if ((Test-Path $ChangelogPath) -and (Read-Text $ChangelogPath).Contains("`r`n")) { "`r`n" } else { "`n" }
    $p = New-FragmentFile $t (Split-Lines ($Text.Trim() -replace '^- ', '')) (Get-Date) $Subject $nl
    $f = Read-Fragment (Get-Item $p)
    if ($f.Problems.Count) { Remove-Item $p; Die ("not a fragment: " + ($f.Problems -join '; ')) }
    $p
    exit 0
}

# ---------------------------------------------------------------------------------------------------------------- -Section
if ($Section) {
    if (-not $Version) { Die '-Section needs -Version' }
    $c = Read-Changelog
    $start = -1
    for ($i = 0; $i -lt $c.Lines.Count; $i++) { if ($c.Lines[$i] -match $Repo.HeadingMatch -and $Matches[1] -eq $Version) { $start = $i; break } }
    if ($start -lt 0) { Die "CHANGELOG.md has no section $Version" }
    $end = $c.Lines.Count
    for ($i = $start + 1; $i -lt $c.Lines.Count; $i++) { if ($c.Lines[$i] -match '^## ') { $end = $i; break } }
    $body = (($c.Lines[($start + 1)..($end - 1)]) -join "`n").Trim() + "`n"
    if ($Out) { Write-Text $Out $body } else { $body }
    exit 0
}

# ---------------------------------------------------------------------------------------------------------------- -Migrate
if ($Migrate) {
    $c = Read-Changelog
    if ($script:Errors.Count) { $script:Errors | ForEach-Object { "error: $_" }; exit 1 }
    if ($c.UStart -lt 0 -or $c.Entries.Count -eq 0) { 'nothing under "' + $Repo.Unreleased + '"'; exit 0 }
    $def = if ($DefaultType) { Canonical-Type $DefaultType } else { '' }
    if ($DefaultType -and -not $def) { Die "-DefaultType is Added, Changed, Fixed or Removed (got '$DefaultType')" }
    $byLine = @{}
    foreach ($pair in ($Types -split ',' | Where-Object { $_.Trim() })) {
        $kv = $pair -split '=', 2
        $t = if ($kv.Count -eq 2) { Canonical-Type $kv[1] } else { '' }
        if ($kv.Count -ne 2 -or $kv[0].Trim() -notmatch '^\d+$' -or -not $t) { Die "-Types is 'line=Type,line=Type' (got '$pair')" }
        $byLine[[int]$kv[0].Trim()] = $t
    }
    foreach ($e in $c.Entries) {
        if ($byLine.ContainsKey($e.Line)) { $e.Type = $byLine[$e.Line] }
        elseif (-not $e.Type) { $e.Type = $def }
    }
    $untyped = @($c.Entries | Where-Object { -not $_.Type })
    if ($untyped.Count) {
        "These entries are under no '### Type' heading: give -DefaultType, or -Types '<line>=Fixed,<line>=Changed' for some of them:"
        foreach ($e in $untyped) { '  line {0}: {1}' -f $e.Line, $(if ($e.Lines[0].Length -gt 90) { $e.Lines[0].Substring(0, 90) + '...' } else { $e.Lines[0] }) }
        exit 1
    }
    # the first entry is the newest: it gets the latest time, one second apart, so that -Assemble lists them in the same order
    $now = Get-Date
    $k = 0
    foreach ($e in $c.Entries) { $null = New-FragmentFile $e.Type @($e.Lines) $now.AddSeconds(-$k) $e.Lines[0] $c.NL; $k++ }
    $kept = @($c.Lines[0..$c.UStart]) + @('') + @($c.Lines[$c.UEnd..($c.Lines.Count - 1)])
    if ($c.UEnd -ge $c.Lines.Count) { $kept = @($c.Lines[0..$c.UStart]) + @('') }
    Write-Text $ChangelogPath ($kept -join $c.NL)
    "{0} entries of {1} are fragments in changelog.d\ now" -f $c.Entries.Count, $Repo.Unreleased
    foreach ($t in $TypeNames) { $n = @($c.Entries | Where-Object { $_.Type -eq $t }).Count; if ($n) { "  $t $n" } }
    exit 0
}

# ---------------------------------------------------------------------------------------------------------------- -Check
if ($Check) {
    $c = Read-Changelog
    $frags = @(Get-Fragments)
    if (Test-Path $Dir) {
        foreach ($f in Get-ChildItem $Dir -Force | Where-Object { $_.PSIsContainer }) { Fail "changelog.d\$($f.Name): a folder (fragments are files)" }
    }
    $released = New-Object 'Collections.Generic.HashSet[string]'
    $from = if ($c.UEnd -ge 0) { $c.UEnd } else { 0 }
    for ($i = $from; $i -lt $c.Lines.Count; $i++) { if ($c.Lines[$i] -match '^- (.+)$') { [void]$released.Add((Entry-Key $Matches[1])) } }
    $seen = @{}
    foreach ($f in $frags) {
        foreach ($p in $f.Problems) { Fail "changelog.d\$($f.Name): $p" }
        if ($f.Lines.Count -eq 0) { continue }
        $key = Entry-Key $f.Lines[0]
        if ($released.Contains($key)) { Fail "changelog.d\$($f.Name): already in a released section of CHANGELOG.md (assembled but not deleted)" }
        if ($seen.ContainsKey($key)) { Fail "changelog.d\$($f.Name): the same text as changelog.d\$($seen[$key])" } else { $seen[$key] = $f.Name }
    }
    if ($c.Entries.Count) { $script:Warnings.Add(("{0} entries under '{1}' in CHANGELOG.md: write fragments instead (tools\changelog.ps1 -Migrate turns them into fragments)" -f $c.Entries.Count, $Repo.Unreleased)) }
    $last = if ($c.FirstRelease -ge 0) { [regex]::Match($c.Lines[$c.FirstRelease], $Repo.HeadingMatch).Groups[1].Value } else { '' }
    if ($Repo.CheckVersion) {
        $sv = Read-SourceVersion
        if ($last -and $sv -ne $last) { Fail "the sources say version $sv, the last released one is ${last}: the version is written when a version is published (tools\changelog.ps1 -Assemble -Version), never by a branch" }
    }
    if ($Release) {
        if ($frags.Count) { Fail "$($frags.Count) fragments are not assembled: tools\changelog.ps1 -Assemble -Version $Release" }
        if ($c.Entries.Count) { Fail "entries are left under '$($Repo.Unreleased)'" }
        if ($last -ne $Release) { Fail "the latest section of CHANGELOG.md is '$last', not $Release" }
        $sv = Read-SourceVersion
        if ($sv -ne $Release) { Fail "the sources say version $sv, not $Release" }
    }
    foreach ($w in $script:Warnings) { "warning: $w" }
    foreach ($e in $script:Errors) { "error: $e" }
    if ($script:Errors.Count) { exit 1 }
    "changelog: {0} fragments, well formed{1}" -f $frags.Count, $(if ($Release) { "; ready to publish $Release" } else { '' })
    exit 0
}

# ---------------------------------------------------------------------------------------------------------------- -Assemble
if ($Assemble) {
    $c = Read-Changelog
    $frags = @(Get-Fragments)
    foreach ($f in $frags) { foreach ($p in $f.Problems) { Fail "changelog.d\$($f.Name): $p" } }
    $def = if ($DefaultType) { Canonical-Type $DefaultType } else { '' }
    $items = New-Object Collections.Generic.List[object]
    foreach ($f in $frags) { if ($f.Type -and $f.Lines.Count) { $items.Add($f) } }
    foreach ($e in $c.Entries) {
        if (-not $e.Type) {
            if ($def) { $e.Type = $def }
            elseif ($Version) { Fail ("CHANGELOG.md line {0}: an entry under '{1}' with no '### Type' (tools\changelog.ps1 -Migrate, or -DefaultType)" -f $e.Line, $Repo.Unreleased); continue }
            else { $e.Type = 'Added' }   # a preview: listed with the additions
        }
        $items.Add($e)
    }
    if ($script:Errors.Count) { $script:Errors | ForEach-Object { "error: $_" }; exit 1 }
    $body = Render-Body $items

    if (-not $Version) {
        $text = ($body -join "`n") + $(if ($body.Count) { "`n" } else { '' })
        if ($Out) { Write-Text $Out $text } else { $text }
        exit 0
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$') { Die "-Version is x.y.z (got '$Version')" }
    foreach ($l in $c.Lines) { if ($l -match $Repo.HeadingMatch -and $Matches[1] -eq $Version) { Die "CHANGELOG.md already has a section $Version" } }
    if ($items.Count -eq 0) { Die "nothing to publish: no fragment in changelog.d\ and nothing under '$($Repo.Unreleased)'" }
    if (-not $Date) { $Date = Get-Date -Format 'yyyy-MM-dd' }
    $released = @(($Repo.Heading -f $Version, $Date), '') + @($body) + @('')
    if ($c.UStart -ge 0) {
        $before = @($c.Lines[0..$c.UStart]) + @('')
        $after = if ($c.UEnd -lt $c.Lines.Count) { @($c.Lines[$c.UEnd..($c.Lines.Count - 1)]) } else { @() }
    } elseif ($c.FirstRelease -ge 0) {
        $before = if ($c.FirstRelease -gt 0) { @($c.Lines[0..($c.FirstRelease - 1)]) } else { @() }
        $after = @($c.Lines[$c.FirstRelease..($c.Lines.Count - 1)])
    } else {
        $before = @($c.Lines | Select-Object -SkipLast 0); while ($before.Count -and $before[-1] -eq '') { $before = @($before | Select-Object -SkipLast 1) }; $before += ''
        $after = @('')
    }
    Write-Text $ChangelogPath ((@($before) + $released + @($after)) -join $c.NL)
    "CHANGELOG.md: section $Version ($($items.Count) entries)"
    Write-SourceVersion $Version
    foreach ($f in $frags) { Remove-Item -LiteralPath $f.Path }
    if ($frags.Count) { "changelog.d\: $($frags.Count) fragments deleted (commit the deletion with CHANGELOG.md)" }
    exit 0
}

'tools\changelog.ps1: -New, -Check, -Assemble, -Section or -Migrate (see the head of the script)'
exit 1
