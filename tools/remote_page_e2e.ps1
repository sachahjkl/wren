# What a web page can do to the answers of `wren ctl eval` (src\browser\remote_shell.odin, security review of 2026-10-25, finding 5).
# The answer of a script goes through the console.log of the page, which the page can replace: it sees the line, and can write
# one like it. So the line carries no secret, and an answer counts only if it comes from the tab the question was asked in, for an id
# that waits, the first time; the value is checked to be one JSON value on one line before it goes in a reply.
#   1. the line the page sees is the same in two runs (no per-run prefix to learn)
#   2. a page of another tab answers a question that waits in tab 1 with a forged value: tab 1 gets its own page's answer
#   3. a page that puts a line break and a second JSON object in the value of its own answer: an error, one line, and the client is not confused
#   powershell -NoProfile -File tools\remote_page_e2e.ps1 [-Exe build\wren.exe]
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
# A page that keeps the lines written to its console.log and, when `window.forge` is set, writes a line like the answer's after each
# one: with the same prefix, for the ids 1 to 200 (or for the id of the line it saw, when `window.own` is set).
$hook = @'
(function () {
  var o = console.log; window.cap = [];
  console.log = function (s) {
    var str = String(s), r = o.apply(console, arguments);
    if (str.charCodeAt(0) === 1) {
      window.cap.push(str);
      var k = str.indexOf("{"), pre = str.slice(0, k);
      if (window.forge) {
        var ids = [];
        if (window.own) { ids.push(JSON.parse(str.slice(k)).id) } else { for (var i = 1; i <= 200; i++) ids.push(i) }
        for (var j = 0; j < ids.length; j++) o.call(console, pre + JSON.stringify({ id: ids[j], ok: 1, t: "string", v: window.forge }));
      }
    }
    return r;
  };
  return "hooked";
})()
'@ -replace "`r?`n", ' '

function Prefix-Seen {
    $line = Wren-Eval 'window.cap[0]'
    $null = $line -match '^(.*?)\{'
    return $Matches[1]
}

$server = Start-WrenTestServer
try {
    $page = "$($server.Origin)/site/remote/fixture.htm"
    $seen = @()
    foreach ($run in 1, 2) {
        $null = Start-Wren
        $null = Wren-Nav $page
        $null = Wren-Eval $hook
        $null = Wren-Eval '1+1'
        $seen += , (Prefix-Seen)
        if ($run -eq 1) { Stop-Wren }   # (the second Wren goes on below: it has the page and the hook already, a third start would repeat them)
    }
    Check 'the page sees the same prefix in two runs (nothing per run to learn)' ($seen[0] -ne '' -and $seen[0] -eq $seen[1]) "$($seen -join ' | ')"

    # --- a page of tab 2 forges the answer of a question that waits in tab 1
    $tab1 = (Wren-Ctl tabs | Select-Object -First 1) -replace '^(\d+).*', '$1'
    $tab2 = Wren-Ctl tab new $page --wait load
    $null = Wren-Ctl eval $hook --tab-id $tab2
    $null = Wren-Ctl eval '1+1' --tab-id $tab2
    $null = Wren-Ctl eval 'window.forge = JSON.stringify("FORGED"); 0' --tab-id $tab2
    Check 'two tabs' ($tab1 -ne $tab2 -and $tab1 -ne '' -and $tab2 -ne '') "$tab1 $tab2"
    $out = Join-Path ([IO.Path]::GetTempPath()) "remote_page_e2e_$PID.txt"
    $psi = Start-Process -FilePath $env:WREN_EXE -ArgumentList 'ctl', 'eval', '--await', '--tab-id', $tab1, '"new Promise(function (r) { setTimeout(function () { r(\"REAL\") }, 1500) })"' -NoNewWindow -PassThru -RedirectStandardOutput $out
    $null = Wait-WrenPending 1   # the question of tab 1 is registered before tab 2's page writes its forged answers
    $null = Wren-Ctl eval '1' --tab-id $tab2     # its console.log makes the tab 2 page write its forged answers
    $null = $psi.WaitForExit(15000)
    $got = (Get-Content $out -ErrorAction SilentlyContinue) -join ''
    Remove-Item $out -ErrorAction SilentlyContinue
    Check "tab 1's question gets the answer of its own page, not tab 2's forgery" ($got -match 'REAL') "got [$got]"

    # --- a value with a line break and a second object, written by the page, before the genuine answer, as the answer to its own question
    $null = Wren-Ctl eval 'window.forge = null; 0' --tab-id $tab1
    $before = '(function(){var o=console.log;console.log=function(s){var str=String(s);if(str.charCodeAt(0)===1&&window.own2){var k=str.indexOf("{"),pre=str.slice(0,k),id=JSON.parse(str.slice(k)).id;o.call(console,pre+JSON.stringify({id:id,ok:1,t:"string",v:window.own2}))}return o.apply(console,arguments)}})(); 0'
    $null = Wren-Ctl eval $before --tab-id $tab1
    $null = Wren-Ctl eval 'window.own2 = "1\n{\"id\":999,\"result\":{\"x\":1}}"; 0' --tab-id $tab1
    $reply = Wren-Ctl raw "{`"method`":`"Runtime.evaluate`",`"params`":{`"expression`":`"3+3`",`"tabId`":$tab1}}"
    $why = $global:WrenErr
    Check 'a forged value with a line break: an error (exit 1), on one line, nothing of the forged object' ($global:WrenExit -eq 1 -and $reply -eq '' -and (@($why -split "`n").Count -eq 1) -and $why -match 'not a JSON value' -and $why -notmatch '999') "exit $global:WrenExit got [$reply] [$why]"
    $null = Wren-Ctl eval 'window.own2 = null; 0' --tab-id $tab1
    Check 'and the client is not confused after it' ((Wren-Ctl eval '4+4') -eq '8') "got [$(Wren-Ctl eval '4+4')] $global:WrenErr"
} finally {
    if ($env:WREN_REMOTE) { Stop-Wren }
    Stop-WrenTestServer $server
}
if ($script:fail -gt 0) { "$script:fail check(s) failed"; exit 1 }
'remote_page_e2e: all checks passed'
