// wrentool: the project's scripts, one program. A table of subcommands; what drives a Wren does it through the typed API (src/remote/api), what needs another program calls it (cargo, magick, ffmpeg, signtool...).
//   odin build src/tools/wrentool -collection:wb=src -out:build/wrentool.exe
//   build\wrentool help
// It compiles without any of the libraries it fetches: `wrentool build` (build.bat runs it) fetches and builds them, then the browser. What needs a desktop or real input is behind an explicit flag: it never runs by default.
package wrentool

import "core:fmt"
import "core:os"
import "wb:tools/tooling"
import "wb:tools/wrentool/bench"
import "wb:tools/wrentool/builder"
import "wb:tools/wrentool/capture"
import "wb:tools/wrentool/changelog"
import "wb:tools/wrentool/deps"
import "wb:tools/wrentool/gen"
import "wb:tools/wrentool/release"

EXIT_USAGE :: 2

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
	test:        bool,   // a test, not a tool: what it starts keeps its connections on this machine (network.loopback_only)
}

COMMANDS := []Command{
	{name = "deps", about = "what a build needs, each up to date: [-Profile quick|release] [-Force]", run = deps.run_all},
	{name = "fetch", about = "wasmtime | wgpu | openh264 | emoji | tracy (the viewer) [-Force] [-Unicode] [-Dest dir]", run = deps.run_fetch},
	{name = "build", about = "[dev|debug|profile|check|release]: the browser (build help) | lexbor | native | tracy [-Force] [-Profile quick|release] [-Features a,b]", run = builder.run},
	{name = "symbols", about = "-Publish exe [-Store] | -Fingerprint exe", run = deps.run_symbols},
	{name = "crash-symbolize", about = "<report> [-Symbols folder or .map] [-Exe exe]: names the frames of a crash report", run = deps.run_crash_symbolize},
	{name = "symbolize", about = "-Exe exe <offset>...: the function and line at an offset of a module", run = deps.run_symbolize},
	{name = "bench", about = "perf | shell | js | idle | webgl | blocker | sidebar | startup | cadence (bench help)", run = bench.run},
	{name = "capture", about = "-Url u -Out f.png [-Width n] [-Height n] [-Actions a] [-Exe path] [-Pref a=b] [-Page]: a page, headless", run = capture.run_capture},
	{name = "shots", about = "[-Only a,b] [-Width n] [-Height n] [-NoConvert] [-Exe path]: the README's and the site's pictures, headless", run = capture.run_shots},
	{name = "compare", about = "-Urls a,b | -List f [-OutDir d] [-Width n] [-Height n] [-Dark] [-Js] [-Exe path]: Wren against headless Edge", run = capture.run_compare},
	{name = "sweep", about = "-Urls a,b | -List f[,g] [-OutDir d] [-Exe path] [-Shard i -Shards n] [-Pref a=b] [-OneProcess]: real pages visited headless (scroll, devtools, a link, back, reload, a tab, close); crashes, hangs, times", run = capture.run_sweep},
	{name = "gen", about = "psl | unicode [-Force] | idna | media-fixtures | video-fixtures | perf-media [-Force] | rust-crates [-Check]", run = gen.run_gen},
	{name = "docs", about = "[-Check] [-NoBuild] [-ChartUpdate]: the documentation site, its links checked", run = gen.run_docs},
	{name = "license", about = "keygen | pubkey | issue | verify ...: Wren's licences (docs/licence.md)", run = gen.run_license},
	{name = "i18n", about = "[-Missing] [-Json f]: the texts passed to tr, the interface's that are not", run = gen.run_i18n},
	{name = "portability", about = "[-Target t] [-Only a,b] [-Csv f] [-Expect f]: every package checked for another target", run = gen.run_portability},
	{name = "engine", about = "test262 [-Filter d] [-Stride n] [-Jobs n] [-NoBuild] | rx-diff [-Seed n] [-Fuzz n] [-NoC]", run = gen.run_engine},
	{name = "trace", about = "start | stop [-Out file.etl] | cancel: a WPR recording with tools\\wren.wprp (an elevated prompt)", run = gen.run_trace},
	{name = "desktop", about = "<program> [arguments]: a command on a Windows desktop of its own", run = gen.run_desktop},
	{name = "changelog", about = "-New | -Check [-Release v] | -Assemble [-Version v] | -Section -Version v | -Migrate", run = changelog.run},
	{name = "package", about = "[-Version v] [-Dev] [-Extras] [-AllowUnreleased]: the release file from a finished build", run = release.run_package},
	{name = "sign", about = "a.exe b.exe: Authenticode, when the environment names an identity", run = release.run_sign},
	{name = "update", about = "keygen | pubkey | manifest | sign | verify ...: the signed manifest an installed Wren updates itself from (docs/updates.md)", run = release.run_update},
	{name = "winget", about = "-Version v [-Url u] [-Sha256 h] [-Out d]: the manifest files; submits nothing", run = release.run_winget},
	{name = "notes", about = "-Tag v [-Ref r] [-Out f]: the notes of a release", run = release.run_notes},
	{name = "experimental", about = "[-Label l] [-NoBuild] [-NoUpload] [-NoVerify] [-NoEmbed] [-Notes f] [-Vault d]: a labelled build to hand out", run = release.run_experimental},
	{name = "smoke", about = "<wren executable>: the packaged executable end to end (needs a display)", run = release.run_smoke, test = true},
	{name = "crash-e2e", about = "Linux: every death of src/tools/crashmodes leaves its report", run = release.run_crash_e2e, test = true},
}

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" { usage(); return }
	root := tooling.repo_root()
	if os.set_working_directory(root) != nil { fmt.eprintfln("wrentool: cannot work in %s", root); os.exit(EXIT_USAGE) }
	for c in COMMANDS {
		if c.name != os.args[1] { continue }
		if c.test { os.set_env(tooling.LOOPBACK_ONLY_ENV, "1") }
		os.exit(c.run(os.args[2:]))
	}
	fmt.eprintfln("wrentool: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("wrentool <command> [arguments]")
	for c in COMMANDS { fmt.printfln("  %-16s %s", c.name, c.about) }
}
