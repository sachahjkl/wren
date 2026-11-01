# Tests of tools\test_cache.ps1: the inputs of a step (against the compiler's own import graph), and that a change of an input, and of nothing else, changes a key.
#   powershell -NoProfile -File tools\test_cache_test.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test_cache.ps1')
$failed = 0
function Expect([bool]$ok, [string]$what, [string]$detail = '') { if ($ok) { "PASS $what" } else { $script:failed++; "FAIL $what $detail" } }

# ---- a small tree of its own: a package that imports another, a file it #loads, a data path in a string
$tmp = Join-Path $repo "build\tmp\test_cache_test_$PID"
New-Item -ItemType Directory -Force "$tmp\src\app", "$tmp\src\lib", "$tmp\src\other", "$tmp\examples\site", "$tmp\tools", "$tmp\docs" | Out-Null
function Put([string]$rel, [string]$text) { [IO.File]::WriteAllText((Join-Path $tmp $rel), $text) }
Put 'src\app\main.odin' "package app`nimport `"core:fmt`"`nimport `"wb:lib`"`nD :: #load(`"data.txt`")`nmain :: proc() { fmt.println(lib.x, `"tools/fixture.ps1`") }`n"
Put 'src\app\data.txt' 'one'
Put 'src\app\app_test.odin' "package app`n"
Put 'src\lib\lib.odin' "package lib`nx := 1`n"
Put 'src\other\other.odin' "package other`n"
Put 'tools\fixture.ps1' '# fixture'
Put 'tools\unrelated.ps1' '# unrelated'
Put 'docs\page.md' 'doc'
Put 'examples\site\page.html' 'page'
Put 'examples\site\guest.wasm' 'output of a build'
Put 'odin.version' 'x'
Initialize-WrenCache $tmp 'flags'
$body = 'odin test src/app -vet -out:build/app_test.exe'
$noVars = @{}
$inputs = Get-WrenStepInputs 'app' $body $noVars
foreach ($f in 'src/app/main.odin', 'src/app/data.txt', 'src/app/app_test.odin', 'src/lib/lib.odin', 'tools/fixture.ps1', 'examples/site/page.html') { Expect ($inputs -contains $f) "an input of the package: $f" }
foreach ($f in 'src/other/other.odin', 'tools/unrelated.ps1', 'docs/page.md', 'examples/site/guest.wasm') { Expect ($inputs -notcontains $f) "not an input of the package: $f" }
$k0 = Get-WrenStepKey 'app' $body $noVars
Expect ($k0 -eq (Get-WrenStepKey 'app' $body $noVars)) 'the same inputs: the same key'
function Changes([string]$rel, [string]$text, [bool]$should) {
    $old = [IO.File]::ReadAllText((Join-Path $tmp $rel))
    Put $rel $text
    $k = Get-WrenStepKey 'app' $body $noVars
    Expect (($k -ne $k0) -eq $should) "$(if ($should) { 'changes the key' } else { 'leaves the key' }): $rel"
    Put $rel $old
    [IO.File]::SetLastWriteTime((Join-Path $tmp $rel), (Get-Date).AddSeconds(-5))
}
Changes 'src\app\main.odin' "package app`nimport `"wb:lib`"`nD :: #load(`"data.txt`")`nmain :: proc() { _ = lib.x; _ = `"tools/fixture.ps1`" }`n" $true
Changes 'src\lib\lib.odin' "package lib`nx := 2`n" $true
Changes 'src\app\data.txt' 'two' $true
Changes 'tools\fixture.ps1' '# changed' $true
Changes 'examples\site\page.html' 'changed' $true
Changes 'odin.version' 'y' $true
Changes 'src\other\other.odin' "package other`nz := 1`n" $false
Changes 'docs\page.md' 'changed' $false
Changes 'examples\site\guest.wasm' 'another output' $false
Expect ($k0 -ne (Get-WrenStepKey 'app' "$body -define:X=1" $noVars)) 'another flag: another key'
Expect ($k0 -ne (Get-WrenStepKey 'app 2' $body $noVars)) 'another step: another key'
$script:CachePrefix = 'another odin version'
Expect ($k0 -ne (Get-WrenStepKey 'app' $body $noVars)) 'another version of Odin or other flags of the run: another key'
Initialize-WrenCache $tmp 'flags'
# an import that cannot be resolved, a variable left in a path: the whole tree
Put 'src\lib\lib.odin' "package lib`nimport `"shared:nowhere`"`n"
[WrenInputs]::Forget()
$wide = Get-WrenStepInputs 'app' $body $noVars
Expect ($wide -contains 'src/other/other.odin') 'an unknown collection: the whole tree'
Put 'src\lib\lib.odin' "package lib`nx := 1`n"
Expect ((Get-WrenStepInputs 'v' 'odin build "src/$unknown" -out:build/x.exe' $noVars) -contains 'src/other/other.odin') 'a variable left in the path: the whole tree'
Expect ((Get-WrenStepInputs 's' 'powershell -File tools\unrelated.ps1' $noVars) -contains 'src/other/other.odin') 'a script: the whole tree'
Expect ((Get-WrenStepInputs 's' 'powershell -File tools\unrelated.ps1' $noVars) -notcontains 'docs/page.md') 'a script: not the documentation'
Expect ((Get-WrenStepInputs 'd' 'tools\docs_site.ps1 -Check' $noVars) -contains 'docs/page.md') 'the documentation step: the documentation'

# ---- results: only what was saved, and only while the program it built is the one on the disk
Expect ($null -eq (Get-WrenCachedResult 'nokey' $body)) 'no result for an unknown key'
New-Item -ItemType Directory -Force "$tmp\build" | Out-Null
Put 'build\tool.exe' 'program'
$buildBody = 'odin build src/app -out:build/tool.exe'
Save-WrenCachedResult 'k1' 3 7 $buildBody
$r = Get-WrenCachedResult 'k1' $buildBody
Expect ($r -and $r.Secs -eq 3 -and $r.Checks -eq 7) 'a saved result comes back'
Put 'build\tool.exe' 'another program!'
Expect ($null -eq (Get-WrenCachedResult 'k1' $buildBody)) 'another program on the disk: no result'
[IO.File]::Delete((Join-Path $tmp 'build\tool.exe'))
Expect ($null -eq (Get-WrenCachedResult 'k1' $buildBody)) 'no program on the disk: no result'

# ---- the repository: the packages found are those the compiler imports (at least), for packages of each kind
$script:CacheRoot = $repo
foreach ($pkg in 'src/url', 'src/page', 'src/tools/wpt', 'ext/gui_toolkit/tests/keyboard') {
    $mine = @([WrenInputs]::ClosurePackages($repo, [string[]]@($pkg)))
    $ErrorActionPreference = 'Continue'   # (what the compiler writes on stderr is not an error of this script)
    $graph = & odin check $pkg -collection:toolkit=ext/gui_toolkit -collection:wb=src -define:ODIN_TEST_THREADS=1 -show-import-graph -no-entry-point 2>&1 | Out-String
    $ErrorActionPreference = 'Stop'
    $missing = New-Object Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($graph, '"([^"]+)"')) {
        $p = $m.Groups[1].Value.Replace('\', '/')
        $i = $p.IndexOf($repo.Replace('\', '/'), [StringComparison]::OrdinalIgnoreCase)
        if ($i -lt 0) { continue }
        $rel = $p.Substring($i + $repo.Length).TrimStart('/').TrimEnd('/')
        if ($rel -and ($mine -notcontains $rel) -and -not ($rel -like '*.odin')) { $missing.Add($rel) }
    }
    Expect ($mine.Count -gt 0 -and $missing.Count -eq 0) "${pkg}: every package of the compiler's import graph ($($mine.Count) found)" ($missing -join ' ')
}
try { [IO.Directory]::Delete($tmp, $true) } catch { }
"$failed failed"
if ($failed) { exit 1 }
exit 0
