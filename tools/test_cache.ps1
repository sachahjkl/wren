# What tools\test_all.ps1 knows about a step's inputs (dot-source it): the files a step depends on, a key made of their contents, and the results of the
# steps that passed, by key (build\test_cache\<key>.txt, as Bazel's action cache does). A step whose key has a result does not run again: the same
# inputs have passed. Nothing here looks at a time stamp to decide (the time stamp only says whether a file need be read again within a run).
#
# The key: Odin's version, the run's flags, the step's name and text with the values of its variables, the scripts every step shares, and the path and SHA-256 of every input:
#   - a step that only compiles and runs Odin packages (`odin test src/x`, build\x.exe of src\tools\x): the files of those packages, of every package they import
#     (wb:, toolkit:, web:, relative: parsed from the sources; every build tag), what they #load, the libraries they link, the paths written in their strings
#     ("examples/site/...", "tools/build_js.ps1": what a test reads while it runs), and examples\ and assets\;
#   - a step that runs a script or the browser: the whole tree a build and a script can read (Get-WrenTreeFiles), tests of packages aside;
#   - a step about the documentation or the changelog, what generates files (odin run), the licence Worker: the whole tree, docs\, site\, changelog.d\ and licence\ too.
# What cannot be resolved (a package path with a variable left in it, an unknown collection, an import that names no folder) falls back on the whole tree: an
# input too many reruns a step, one too few could hide a failure.
# Only a pass is kept, and a key is computed again when the step has ended: a source edited during the step leaves no result. A result lasts $CacheMaxAgeDays days (a certificate, a date in
# a test: what no file says). test_all.ps1 -NoCache runs everything; tools\test_cache_test.ps1 tests this file.

$script:CacheMaxAgeDays = 7
$script:CacheFormat = 'wren-test-cache 1'

if (-not ('WrenInputs' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
public static class WrenInputs {
    class Memo { public long Ticks, Size; public string Hash; }
    static readonly ConcurrentDictionary<string, Memo> memo = new ConcurrentDictionary<string, Memo>(StringComparer.OrdinalIgnoreCase);
    static readonly Regex Import = new Regex("^\\s*(?:@\\([^)]*\\)\\s*)?import\\s+(?:[A-Za-z_][A-Za-z0-9_]*\\s+)?\"([^\"]+)\"", RegexOptions.Compiled | RegexOptions.Multiline);
    static readonly Regex Load = new Regex("#load(?:_directory|_hash)?\\(\\s*\"([^\"]+)\"", RegexOptions.Compiled);
    static readonly Regex Library = new Regex("\"([^\"\\s]+\\.(?:lib|a|obj|res|o))\"", RegexOptions.Compiled);
    // what a test reads while it runs, written in a string; up to the first format verb (fmt.tprintf("examples/site/images/%s", name))
    static readonly Regex DataPath = new Regex("\"((?:ext|examples|assets|tools|wpt|docs|site|licence|native|api|sdk|src)[/\\\\][^\"%\\s*:|<>?]*)", RegexOptions.Compiled);
    public static readonly string[] TreeDirs = { "src", "ext/gui_toolkit", "tools", "wpt", "native", "api", "sdk", "examples", "assets" };
    public static readonly string[] TreeFiles = { "build.bat", "build.sh", "odin.version", "build/js/wren_js.wasm", "build/lexbor/lexbor.lib", "build/native/wren_native.lib", "build/native/STAMP" };
    public static readonly string[] AllDirs = { "docs", "site", "changelog.d", "licence" };
    public static readonly string[] AllFiles = { "CHANGELOG.md", "README.md", "CONTRIBUTING.md", "THIRD_PARTY.md", "LICENSE" };
    static string Norm(string p) { return p.Replace('\\', '/'); }
    static string Full(string root, string rel) { return Path.Combine(root, rel.Replace('/', Path.DirectorySeparatorChar)); }
    // what a build writes among the sources: an output, made from the sources that are inputs (a guest's .wasm, in examples\site for the pages of the test server)
    static bool Output(string rel) { return rel.EndsWith(".wasm", StringComparison.OrdinalIgnoreCase) && rel.StartsWith("examples/", StringComparison.OrdinalIgnoreCase); }
    static bool Skipped(string rel) { return rel.Contains("/.git/") || rel.EndsWith("/.git", StringComparison.Ordinal) || Output(rel); }
    static IEnumerable<string> Files(string root, string dir) {
        string full = Full(root, dir);
        if (!Directory.Exists(full)) return new string[0];
        return Directory.EnumerateFiles(full, "*", SearchOption.AllDirectories).Select(f => Norm(f.Substring(root.Length).TrimStart('\\', '/'))).Where(r => !Skipped(r));
    }
    public static string HashFile(string root, string rel) {
        string full = Full(root, rel);
        FileInfo fi = new FileInfo(full);
        if (!fi.Exists) return "missing";
        Memo m;
        if (memo.TryGetValue(full, out m) && m.Ticks == fi.LastWriteTimeUtc.Ticks && m.Size == fi.Length) return m.Hash;
        using (SHA256 sha = SHA256.Create())
        using (FileStream s = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
            m = new Memo { Ticks = fi.LastWriteTimeUtc.Ticks, Size = fi.Length, Hash = BitConverter.ToString(sha.ComputeHash(s)).Replace("-", "") };
        }
        memo[full] = m;
        return m.Hash;
    }
    // every file a build or a script can read; `everything`: the documentation and the changelog too; `tests`: *_test.odin as well
    public static string[] Tree(string root, bool everything, bool tests) {
        string id = "tree " + everything + " " + tests;
        string[] known;
        if (lists.TryGetValue(id, out known)) return known;
        return lists[id] = TreeNow(root, everything, tests);
    }
    // the lists of files are kept until Forget (a batch of steps), the contents are looked at every time
    static readonly Dictionary<string, string[]> lists = new Dictionary<string, string[]>();
    public static void Forget() { lists.Clear(); nodes.Clear(); }
    // what the test server and the tests read while they run, and how a step is run
    public static string[] Data(string root) {
        string[] known;
        if (lists.TryGetValue("data", out known)) return known;
        return lists["data"] = Tree(root, false, true).Where(f => f.StartsWith("examples/") || f.StartsWith("assets/") || f.StartsWith("tools/testserver/") || f.StartsWith("sdk/") || f.StartsWith("api/") || f == "tools/test_env.ps1" || f == "odin.version" || f.StartsWith("build/native/") || f.StartsWith("build/lexbor/")).ToArray();
    }
    public static string[] WithData(string root, string[] packages) {
        string id = "closure " + string.Join(" ", packages);
        string[] known;
        if (lists.TryGetValue(id, out known)) return known;
        string[] closure = Closure(root, packages);
        if (closure == null) return null;
        return lists[id] = closure.Concat(Data(root)).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(f => f, StringComparer.Ordinal).ToArray();
    }
    static string[] TreeNow(string root, bool everything, bool tests) {
        List<string> dirs = new List<string>(TreeDirs); List<string> files = new List<string>(TreeFiles);
        if (everything) { dirs.AddRange(AllDirs); files.AddRange(AllFiles); }
        IEnumerable<string> all = dirs.SelectMany(d => Files(root, d)).Concat(files);
        if (!tests) all = all.Where(f => !f.EndsWith("_test.odin", StringComparison.OrdinalIgnoreCase) && !f.Contains("/tests/"));
        return all.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(f => f, StringComparer.Ordinal).ToArray();
    }
    // what a source says it uses (read once in a run, unless it changes: a key is computed for every step, twice)
    class Parsed { public long Ticks, Size; public string[] Imports, Loads, Data; }
    static readonly ConcurrentDictionary<string, Parsed> parsed = new ConcurrentDictionary<string, Parsed>(StringComparer.OrdinalIgnoreCase);
    static Parsed Parse(string full) {
        FileInfo fi = new FileInfo(full);
        Parsed p;
        if (parsed.TryGetValue(full, out p) && p.Ticks == fi.LastWriteTimeUtc.Ticks && p.Size == fi.Length) return p;
        string text = File.ReadAllText(full);
        p = new Parsed { Ticks = fi.LastWriteTimeUtc.Ticks, Size = fi.Length };
        p.Imports = Import.Matches(text).Cast<Match>().Select(m => m.Groups[1].Value).ToArray();
        // (system:Kernel32.lib: the machine's)
        p.Loads = Load.Matches(text).Cast<Match>().Concat(Library.Matches(text).Cast<Match>()).Select(m => m.Groups[1].Value).Where(v => !v.Contains(":")).ToArray();
        p.Data = DataPath.Matches(text).Cast<Match>().Select(m => m.Groups[1].Value).ToArray();
        parsed[full] = p;
        return p;
    }
    // a package's folder from an import, "" for what comes with the compiler, null when it cannot be resolved
    static string Resolve(string root, string dir, string path) {
        int colon = path.IndexOf(':');
        string resolved;
        if (colon >= 0) {
            string coll = path.Substring(0, colon), rest = path.Substring(colon + 1);
            if (coll == "core" || coll == "base" || coll == "vendor") return "";
            if (coll == "wb") resolved = "src/" + rest;
            else if (coll == "toolkit") resolved = "ext/gui_toolkit/" + rest;
            else if (coll == "web") resolved = "sdk/odin/" + rest;
            else return null;
        } else {
            resolved = dir + "/" + path;
        }
        return Directory.Exists(Full(root, resolved)) ? Canon(root, resolved) : null;
    }
    static string Canon(string root, string rel) {
        string f = Path.GetFullPath(Full(root, rel));
        return Norm(f.Substring(Path.GetFullPath(root).TrimEnd('\\', '/').Length).TrimStart('\\', '/'));
    }
    // What one package says, kept until Forget: its files, what it uses by name, the packages it imports.
    class Node { public List<string> Files = new List<string>(); public List<string> Imports = new List<string>(); public bool Unresolved; }
    static readonly Dictionary<string, Node> nodes = new Dictionary<string, Node>(StringComparer.OrdinalIgnoreCase);
    static Node NodeOf(string root, string dir) {
        Node n;
        if (nodes.TryGetValue(dir, out n)) return n;
        n = new Node();
        string full = Full(root, dir);
        foreach (string f in Directory.EnumerateFiles(full)) {
            string rel = dir + "/" + Path.GetFileName(f);
            if (Skipped(rel)) continue;
            n.Files.Add(rel);
            if (!f.EndsWith(".odin", StringComparison.OrdinalIgnoreCase)) continue;
            Parsed pf = Parse(f);
            foreach (string imp in pf.Imports) {
                string pkg = Resolve(root, dir, imp);
                if (pkg == null) { n.Unresolved = true; continue; }
                if (pkg != "") n.Imports.Add(pkg);
            }
            foreach (string load in pf.Loads) {
                string target = Canon(root, dir + "/" + load);
                string targetFull = Full(root, target);
                if (File.Exists(targetFull)) n.Files.Add(target);
                else if (Directory.Exists(targetFull)) n.Files.AddRange(Files(root, target));
            }
            foreach (string dp in pf.Data) {
                string target = Norm(dp).TrimEnd('/');
                string targetFull = Full(root, target);
                if (File.Exists(targetFull)) n.Files.Add(Canon(root, target));
                else if (Directory.Exists(targetFull)) n.Files.AddRange(Files(root, target));
            }
        }
        // a folder of data beside a package's sources (not a package: no .odin file in it)
        foreach (string sub in Directory.EnumerateDirectories(full)) {
            if (Directory.EnumerateFiles(sub, "*.odin", SearchOption.AllDirectories).Any()) continue;
            n.Files.AddRange(Files(root, dir + "/" + Path.GetFileName(sub)));
        }
        nodes[dir] = n;
        return n;
    }
    // The files of `packages` and of everything they import. Null when something cannot be resolved: the caller takes the whole tree.
    public static string[] Closure(string root, string[] packages) {
        HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        HashSet<string> files = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        Stack<string> todo = new Stack<string>();
        foreach (string p in packages) {
            if (!Directory.Exists(Full(root, p))) return null;
            string c = Canon(root, p);
            if (seen.Add(c)) todo.Push(c);
        }
        while (todo.Count > 0) {
            Node n = NodeOf(root, todo.Pop());
            if (n.Unresolved) return null;
            foreach (string f in n.Files) files.Add(f);
            foreach (string pkg in n.Imports) if (seen.Add(pkg)) todo.Push(pkg);
        }
        return files.OrderBy(f => f, StringComparer.Ordinal).ToArray();
    }
    // The packages a Closure went through, sorted: tools\test_cache_test.ps1 compares them with the compiler's own import graph.
    public static string[] ClosurePackages(string root, string[] packages) {
        string[] files = Closure(root, packages);
        if (files == null) return null;
        return files.Where(f => f.EndsWith(".odin", StringComparison.OrdinalIgnoreCase)).Select(f => f.Substring(0, f.LastIndexOf('/'))).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(f => f, StringComparer.Ordinal).ToArray();
    }
    // SHA-256 of `prefix` and of every file's path and contents
    public static string Key(string root, string prefix, string[] files) {
        string[] hashes = new string[files.Length];
        Parallel.For(0, files.Length, i => { hashes[i] = HashFile(root, files[i]); });
        StringBuilder b = new StringBuilder(prefix);
        for (int i = 0; i < files.Length; i++) b.Append('\n').Append(files[i]).Append(' ').Append(hashes[i]);
        using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(b.ToString()))).Replace("-", "").ToLowerInvariant();
    }
}
'@
}

# The odin packages a step's text compiles, its variables replaced; $null when one is not known (a variable left in the path)
function Get-WrenStepPackages([string]$Body, $Vars) {
    $text = $Body
    foreach ($k in $Vars.Keys) { $v = $Vars[$k]; if ($v -isnot [array]) { $text = $text.Replace('$' + $k, [string]$v).Replace('${' + $k + '}', [string]$v) } }
    # (the groups of toolkit suites: one body for the suites of $group)
    $bodies = @($text)
    if ($text -match '\$suites = \$group' -or $Vars.ContainsKey('group')) {
        if ($Vars.ContainsKey('group') -and $Body.Contains('$t')) { $bodies = @(($Vars['group'] -split ',') | ForEach-Object { $text.Replace('$t', $_) }) }
    }
    $pkgs = New-Object Collections.Generic.List[string]
    $outs = @{}
    foreach ($b in $bodies) {
        foreach ($m in [regex]::Matches($b, '\bodin\s+(?:test|build|run|check)\s+"?([^\s"]+)"?')) {
            $p = $m.Groups[1].Value.Replace('\', '/').TrimEnd('/')
            if ($p.Contains('$')) { return $null }
            $pkgs.Add($p)
        }
        foreach ($m in [regex]::Matches($b, '-out:"?([^\s"]+)"?')) { $outs[($m.Groups[1].Value.Replace('\', '/'))] = $true }
    }
    # a tool an earlier step built (build\policytest.exe from src\tools\policytest) and a guest (build\e2e.wasm from examples\e2e)
    foreach ($b in $bodies) {
        foreach ($m in [regex]::Matches($b, 'build[\\/]([A-Za-z0-9_]+)\.exe')) {
            if ($outs.ContainsKey("build/$($m.Groups[1].Value).exe")) { continue }
            $d = "src/tools/$($m.Groups[1].Value)"
            if (Test-Path -LiteralPath (Join-Path $script:CacheRoot $d)) { $pkgs.Add($d) } else { return $null }
        }
    }
    return @($pkgs | Select-Object -Unique)
}

# The files a step depends on (repository-relative, sorted).
function Get-WrenStepInputs([string]$Name, [string]$Body, $Vars) {
    $root = $script:CacheRoot
    if ($Body -match 'docs_site|changelog|odin run|licence\\worker') { return , [WrenInputs]::Tree($root, $true, $true) }
    if ($Body -match 'Ensure-WrenBuild|tools\\[A-Za-z0-9_]+\.ps1|Get-ChildItem src') { return , [WrenInputs]::Tree($root, $false, $false) }
    $pkgs = @(Get-WrenStepPackages $Body $Vars)
    if ($null -eq $pkgs -or $pkgs.Count -eq 0 -or $pkgs[0] -eq $null) { return , [WrenInputs]::Tree($root, $false, $false) }
    $closure = [WrenInputs]::WithData($root, [string[]]$pkgs)
    if ($null -eq $closure) { return , [WrenInputs]::Tree($root, $false, $false) }
    return , $closure
}

# Starts the cache of this run: $Flags say what changes a result besides the files (-Quick, -CI, ...).
function Initialize-WrenCache([string]$Root, [string]$Flags) {
    $script:CacheRoot = $Root
    $script:CacheDir = Join-Path $Root 'build\test_cache'
    New-Item -ItemType Directory -Force $script:CacheDir | Out-Null
    $ver = (& odin version 2>&1 | Out-String).Trim()
    $script:CachePrefix = "$script:CacheFormat`n$ver`n$Flags"
    # the old results go, they will not be read again
    $limit = (Get-Date).AddDays(-$script:CacheMaxAgeDays)
    foreach ($f in [IO.Directory]::EnumerateFiles($script:CacheDir, '*.txt')) { if ([IO.File]::GetLastWriteTime($f) -lt $limit) { try { [IO.File]::Delete($f) } catch { } } }
}

function Get-WrenStepKey([string]$Name, [string]$Body, $Vars) {
    $vt = (@($Vars.Keys | Sort-Object) | ForEach-Object { "$_=$($Vars[$_] -join ',')" }) -join "`n"
    $files = Get-WrenStepInputs $Name $Body $Vars
    return [WrenInputs]::Key($script:CacheRoot, "$script:CachePrefix`n$Name`n$Body`n$vt", [string[]]$files)
}

# What a step wrote that a later step uses (odin build -out:, go build -o): "path|size|time". A result stands only while they are what the step left (going back to
# sources of two changes ago finds the result, but the program on the disk is another's).
function Get-WrenStepOutputs([string]$Body) {
    $o = New-Object Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Body, '\bodin\s+build\s[^;|\r\n]*?-out:"?([^\s";]+)"?')) { $o.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($Body, '\bgo build -o ([^\s;}]+)')) { $o.Add(($m.Groups[1].Value -replace '^(\.\.[\\/])+', '')) }
    return @($o | Where-Object { $_ -notmatch '\$' } | Select-Object -Unique)
}
function Get-WrenFileId([string]$Rel) {
    $f = New-Object IO.FileInfo (Join-Path $script:CacheRoot $Rel)
    if (-not $f.Exists) { return "$Rel|missing" }
    return "$Rel|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
}

# A step's result for this key: { Secs; Checks; When }, or $null.
function Get-WrenCachedResult([string]$Key, [string]$Body) {
    $p = Join-Path $script:CacheDir "$Key.txt"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $lines = [IO.File]::ReadAllLines($p)
    if ($lines.Count -lt 3 -or $lines[0] -ne 'PASS') { return $null }
    foreach ($l in ($lines | Select-Object -Skip 4)) {
        $rel = ($l -split '\|')[0]
        if ((Get-WrenFileId $rel) -ne $l) { return $null }
    }
    return [pscustomobject]@{ Secs = [int]$lines[1]; Checks = [int]$lines[2]; When = $lines[3] }
}
function Save-WrenCachedResult([string]$Key, [int]$Secs, [int]$Checks, [string]$Body) {
    $lines = @('PASS', "$Secs", "$Checks", (Get-Date -Format 'yyyy-MM-dd HH:mm')) + @(Get-WrenStepOutputs $Body | ForEach-Object { Get-WrenFileId $_ })
    $p = Join-Path $script:CacheDir "$Key.txt"
    $tmp = "$p.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($lines -join "`n") + "`n")
    [IO.File]::Copy($tmp, $p, $true); [IO.File]::Delete($tmp)
}
