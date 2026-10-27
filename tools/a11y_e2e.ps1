# End-to-end test of accessibility: a Wren with no window shown is read and driven through UI Automation, as a screen
# reader does (the toolkit's tools\uia_probe, a UI Automation client): the chrome's tabs, buttons, address bar and menu
# have their roles, names and states, and invoking, setting a value and selecting act on them. No screen reader is
# needed and nothing takes the desktop.
#   powershell -NoProfile -File tools\a11y_e2e.ps1 [-Exe build\wren.exe]
# The probe (build\uia_probe.exe) is built from ext\gui_toolkit\tools\uia_probe when missing or older than its sources.
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"

$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { "PASS  $name" } else { "FAIL  $name  $detail"; $script:fail++ }
}

# the probe: built when stale
$probe = Join-Path $root 'build\uia_probe.exe'
$srcs = @(Get-ChildItem (Join-Path $root 'ext\gui_toolkit\tools\uia_probe'), (Join-Path $root 'ext\gui_toolkit\tools\uia') -Filter *.odin)
$stale = -not (Test-Path $probe) -or ($srcs | Where-Object { $_.LastWriteTimeUtc -gt (Get-Item $probe).LastWriteTimeUtc })
if ($stale) {
    $o = cmd /c "odin build `"$root\ext\gui_toolkit\tools\uia_probe`" -vet -out:`"$probe`" 2>&1" | Out-String
    if ($LASTEXITCODE -ne 0) { $o; 'FAIL building the probe'; exit 1 }
}

# Runs the probe; returns its stdout, exit code in $script:ProbeExit.
function Probe {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $probe
    $psi.Arguments = ($args | ForEach-Object { ConvertTo-WinArg "$_" }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch {}; $script:ProbeExit = 2; return '' }
    $p.WaitForExit()
    $script:ProbeExit = $p.ExitCode
    if ($p.ExitCode -ne 0 -and $err.Result) { Write-Host "  probe: $($err.Result.Trim())" }
    return $out.Result.TrimEnd()
}

$name = Start-Wren -Size 1100x760 -Url 'about:blank'
try {
    $wpid = (Wren-Ctl stats --json | ConvertFrom-Json).pid
    Check 'the Wren answers' ($wpid -gt 0)

    # the first question makes Wren build its tree: the dump waits for more than the placeholder
    $dump = Probe dump --pid $wpid
    Check 'the window is read through UI Automation' ($script:ProbeExit -eq 0 -and $dump -ne '') "exit $script:ProbeExit"
    $lines = $dump -split "`r?`n"
    function Has([string]$pattern) { return [bool]($lines | Where-Object { $_ -match $pattern }) }
    Check 'button Back'                     (Has '^button "Back"')                 $dump
    Check 'button Forward'                  (Has '^button "Forward"')
    Check 'button Reload'                   (Has '^button "Reload"')
    Check 'the address bar is an edit'      (Has '^edit "Address and search bar"')
    Check 'a tab list'                      (Has '^tablist "Tabs"')
    Check 'the current tab is selected'     (Has '^tab ".*" selected')
    Check 'button New tab'                  (Has '^button "New tab"')
    Check 'button Menu'                     (Has '^button "Menu"')
    Check 'no icon-font glyph as a name'    (-not (Has '^button "[A-Za-z<>^]"$'))

    # actions
    $null = Probe invoke --pid $wpid --type button --name 'New tab'
    Check 'invoke New tab' ($script:ProbeExit -eq 0)
    $null = Probe wait --pid $wpid --type tab --index 1 --timeout 5000
    Check 'a second tab is there' ($script:ProbeExit -eq 0)

    $null = Probe set-value --pid $wpid --type edit --name 'Address and search bar' --value 'wren a11y'
    Check 'set the address bar' ($script:ProbeExit -eq 0)
    $v = Probe find --pid $wpid --type edit --name 'Address and search bar'
    Check 'the address bar says it' ($v -match 'value="wren a11y"') $v

    $null = Probe select --pid $wpid --type tab --index 0
    Check 'select the first tab' ($script:ProbeExit -eq 0)
    $t0 = Probe wait --pid $wpid --type tab --index 0 --timeout 5000
    Check 'the first tab is selected' ($t0 -match 'selected') $t0

    # (a button that opens a menu is expanded, not invoked: UI Automation gives it ExpandCollapse instead of Invoke)
    $null = Probe expand --pid $wpid --type button --name 'Menu'
    Check 'expand Menu' ($script:ProbeExit -eq 0)
    $mp = Probe wait --pid $wpid --type menu --timeout 5000
    Check 'the menu opens' ($script:ProbeExit -eq 0) $mp
    $mb = Probe find --pid $wpid --type button --name 'Menu'
    Check 'the Menu button says it is expanded' ($mb -match 'expanded') $mb
    $mi = Probe wait --pid $wpid --type menuitem --name 'New tab' --prefix --timeout 5000
    Check 'the menu shows its items' ($script:ProbeExit -eq 0) $mi
    $null = Probe collapse --pid $wpid --type button --name 'Menu'
    $null = Probe find --pid $wpid --type menu
    Check 'collapse closes it' ($script:ProbeExit -ne 0)

    # a page: its tree grafted under the chrome's (examples\a11y\page.html: a form, a list, a table, a dialog, live regions)
    $page = 'file:///' + ((Join-Path $root 'examples\a11y\page.html') -replace '\\', '/')
    $null = Wren-Nav $page
    $doc = Probe wait --pid $wpid --type document --name 'Accessibility sample' --timeout 8000
    Check 'the page is a document named by its title' ($script:ProbeExit -eq 0) $doc
    $pdump = Probe dump --pid $wpid
    $plines = $pdump -split "`r?`n"
    function PHas([string]$pattern) { return [bool]($plines | Where-Object { $_ -match $pattern }) }
    Check 'a heading'                         (PHas '"Accessibility sample"')        $pdump
    Check 'a link'                            (PHas '^link "Home"')
    Check 'a field named by its label'        (PHas '^edit "Your name".*value="Ada"')
    Check 'a check box, checked'              (PHas '^checkbox "Newsletter" checked')
    Check 'a radio button, checked'           (PHas '^radio "Large"')
    Check 'a combo box'                       (PHas '^combobox "Country"')
    Check 'a disabled button'                 (PHas '^button "Save" disabled')
    Check 'a button named by its title'       (PHas '^button "Delete"')
    Check 'a table'                           (PHas '^table "Scores"')
    Check 'an image named by its alt'         (PHas '^image "A cat"')
    Check 'tabs of ARIA'                      (PHas '^tab "Grid" selected')
    Check 'a slider'                          (PHas '^slider "Volume"')
    Check 'a dialog'                          (PHas '"Confirm"')
    Check 'aria-hidden is left out'           (-not (PHas '"Hidden"'))
    Check 'hidden is left out'                (-not (PHas '"Hidden too"'))
    Check 'inert is left out'                 (-not (PHas '^button "Inert"'))
    Check 'display: none is left out'         (-not (PHas '^button "Gone"'))

    $null = Probe set-value --pid $wpid --type edit --name 'Your name' --value 'Grace'
    Check 'set the field' ($script:ProbeExit -eq 0)
    Start-Sleep -Milliseconds 300
    $val = Wren-Eval "document.getElementById('name').value"
    Check 'the page sees the value' ($val -match 'Grace') $val
    $null = Probe toggle --pid $wpid --type checkbox --name 'Newsletter'
    Start-Sleep -Milliseconds 300
    $chk = Wren-Eval "String(document.getElementById('news').checked)"
    Check 'toggle unchecks the box' ($chk -match 'false') $chk
    $null = Probe focus --pid $wpid --type edit --name 'Your name'
    Start-Sleep -Milliseconds 300
    $act = Wren-Eval "document.activeElement ? document.activeElement.id : ''"
    Check 'focus moves the page''s focus' ($act -match 'name') $act
    $null = Probe invoke --pid $wpid --type button --name 'OK'
    Check 'invoke a page button' ($script:ProbeExit -eq 0)
    $st = Wren-Ctl stats --json | ConvertFrom-Json
    Check 'no update refused' ([int]$st.a11yRefused -eq 0 -and [int]$st.a11yPageRefused -eq 0) "chrome $($st.a11yRefused), page $($st.a11yPageRefused)"
    "  page tree: $($st.a11yPageNodes) nodes, $($st.a11yPageBuilds) builds, $($st.a11yPagePatches) patches, $($st.a11yPageSends) updates"

    # a page that changes (examples\a11y\dynamic.html): its tree follows node by node, and every patch is compared with a
    # whole tree (accessibility.page.verify)
    $null = Wren-Ctl pref set accessibility.page.verify true
    $dyn = 'file:///' + ((Join-Path $root 'examples\a11y\dynamic.html') -replace '\\', '/')
    $null = Wren-Nav $dyn
    $null = Probe wait --pid $wpid --type document --name 'Accessibility updates' --timeout 8000
    Check 'the changing page is read' ($script:ProbeExit -eq 0)
    $null = Probe wait --pid $wpid --type button --name 'Inside frame' --timeout 8000
    $s0 = Wren-Ctl stats --json | ConvertFrom-Json
    $null = Wren-Eval "var b = document.createElement('button'); b.id = 'later'; b.textContent = 'Added later'; document.getElementById('host').appendChild(b); 'ok'"
    $null = Probe wait --pid $wpid --type button --name 'Added later' --timeout 5000
    Check 'a button the page inserts is read' ($script:ProbeExit -eq 0)
    $null = Wren-Eval "document.getElementById('h').textContent = 'Renamed heading'; 'ok'"
    $null = Probe wait --pid $wpid --name 'Renamed heading' --timeout 5000
    Check 'a heading the page renames is read' ($script:ProbeExit -eq 0)
    $null = Wren-Eval "var li = document.createElement('li'); li.textContent = 'Three'; document.getElementById('list').appendChild(li); 'ok'"
    $null = Probe wait --pid $wpid --type listitem --index 2 --timeout 5000
    Check 'a list item the page adds is read' ($script:ProbeExit -eq 0)
    # static text has the bounds of its own lines, not its block's
    $lb = (Probe bounds --pid $wpid --type listitem --index 0) -split ' '
    $tb = (Probe bounds --pid $wpid --type text --name 'One') -split ' '
    Check 'a text''s bounds are its own line''s' ($lb.Count -eq 4 -and $tb.Count -eq 4 -and [int]$tb[2] -gt 0 -and [int]$tb[2] -lt [int]$lb[2] / 2) "item $($lb -join ','), text $($tb -join ',')"
    $null = Wren-Eval "document.getElementById('later').remove(); 'ok'"
    $gone = $false
    for ($i = 0; $i -lt 50 -and -not $gone; $i++) { $null = Probe find --pid $wpid --type button --name 'Added later'; $gone = $script:ProbeExit -ne 0; if (-not $gone) { Start-Sleep -Milliseconds 100 } }
    Check 'a button the page removes is gone' $gone
    $s1 = Wren-Ctl stats --json | ConvertFrom-Json
    Check 'the changes went as patches, not whole trees' ([int]$s1.a11yPageBuilds -eq [int]$s0.a11yPageBuilds -and [int]$s1.a11yPagePatches -gt [int]$s0.a11yPagePatches) "builds $($s0.a11yPageBuilds) -> $($s1.a11yPageBuilds) ($($s1.a11yPageFallback)), patches $($s0.a11yPagePatches) -> $($s1.a11yPagePatches)"
    Check 'every patch equals a whole tree' ([int]$s1.a11yPageVerifyFailed -eq 0) "$($s1.a11yPageVerifyFailed) differ"

    # at rest: nothing is built or sent while nothing changes
    Start-Sleep -Milliseconds 800
    $r0 = Wren-Ctl stats --json | ConvertFrom-Json
    Start-Sleep -Milliseconds 1500
    $r1 = Wren-Ctl stats --json | ConvertFrom-Json
    Check 'nothing built or sent at rest' ([int]$r1.a11yPageSends -eq [int]$r0.a11yPageSends -and [int]$r1.a11yPageBuilds -eq [int]$r0.a11yPageBuilds -and [int]$r1.a11yPagePatches -eq [int]$r0.a11yPagePatches -and [int]$r1.a11yUpdates -eq [int]$r0.a11yUpdates) "sends $($r0.a11yPageSends) -> $($r1.a11yPageSends), chrome $($r0.a11yUpdates) -> $($r1.a11yUpdates)"

    # a frame: its document in the page's tree, its button acts in the frame
    Check 'the frame''s document is in the page''s tree' ([int]$s1.a11yPageFrames -ge 1) "frames $($s1.a11yPageFrames)"
    $null = Probe invoke --pid $wpid --type button --name 'Inside frame'
    Check 'invoke a button of the frame' ($script:ProbeExit -eq 0)
    $msg = ''
    for ($i = 0; $i -lt 30 -and $msg -notmatch 'inner-click'; $i++) { Start-Sleep -Milliseconds 100; $msg = Wren-Eval "window.__msgs.join(',')" }
    Check 'the frame''s button ran in the frame' ($msg -match 'inner-click') $msg

    # the caret and the selection of a text field (the text pattern), and a selection made by the reader
    $null = Wren-Eval "var f = document.getElementById('field'); f.focus(); f.setSelectionRange(0, 5); 'ok'"
    Start-Sleep -Milliseconds 300
    $tx = Probe text --pid $wpid --type edit --name 'Field'
    Check 'the field''s text is read by characters' ($tx -match 'text="Grace Hopper"') $tx
    Check 'the field''s selection is read' ($tx -match 'selection="Grace"') $tx
    $null = Probe select-text --pid $wpid --type edit --name 'Field' --start 6 --end 12
    Check 'select text in the field' ($script:ProbeExit -eq 0)
    Start-Sleep -Milliseconds 300
    $sel = Wren-Eval "var f = document.getElementById('field'); f.selectionStart + ',' + f.selectionEnd"
    Check 'the page sees the selection' ($sel -match '6,12') $sel

    # a second window: each window shows its own page to the screen readers
    $null = Wren-Ctl cmd window.new
    $null = Wren-Ctl wait frames 4
    $wins = @((Wren-Ctl windows --json | ConvertFrom-Json).windows)
    Check 'a second window' ($wins.Count -eq 2) "$($wins.Count) windows"
    if ($wins.Count -eq 2) {
        $w1 = $wins | Where-Object { $_.windowId -eq ($wins | Measure-Object windowId -Minimum).Minimum }
        $w2 = $wins | Where-Object { $_.windowId -ne $w1.windowId }
        $null = Wren-Ctl nav $page --win-id $w2.windowId --wait load
        $null = Probe wait --hwnd $w2.hwnd --type document --name 'Accessibility sample' --timeout 8000
        Check 'the second window reads its page' ($script:ProbeExit -eq 0)
        $null = Probe wait --hwnd $w1.hwnd --type document --name 'Accessibility updates' --timeout 8000
        Check 'the first window still reads its own' ($script:ProbeExit -eq 0)
        $null = Probe wait --hwnd $w2.hwnd --type button --name 'Inside frame' --timeout 500
        Check 'the second window does not show the first one''s page' ($script:ProbeExit -ne 0)
        $sw1 = Wren-Ctl stats --json --win-id $w1.windowId | ConvertFrom-Json
        $sw2 = Wren-Ctl stats --json --win-id $w2.windowId | ConvertFrom-Json
        Check 'no update refused in either window' ([int]$sw1.a11yPageRefused + [int]$sw2.a11yPageRefused + [int]$sw1.a11yRefused + [int]$sw2.a11yRefused -eq 0) "page $($sw1.a11yPageRefused)/$($sw2.a11yPageRefused), chrome $($sw1.a11yRefused)/$($sw2.a11yRefused)"
        Check 'no patch differs in either window' ([int]$sw1.a11yPageVerifyFailed + [int]$sw2.a11yPageVerifyFailed -eq 0)
    }
} finally {
    Stop-Wren $name
}
if ($script:fail -gt 0) { "FAIL a11y_e2e ($script:fail)"; exit 1 }
'PASS a11y_e2e'
