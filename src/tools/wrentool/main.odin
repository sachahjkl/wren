// wrentool: the project's scripts, one program. A table of subcommands; what drives a Wren does it through the typed API (src/remote/api), what needs another program calls it (cargo, magick, ffmpeg, signtool...).
//   odin build src/tools/wrentool -collection:wb=src -out:build/wrentool.exe
//   build\wrentool help
// It compiles without any of the libraries it fetches (build.bat builds it first). What needs a desktop or real input is behind an explicit flag: it never runs by default.
package wrentool

import "core:fmt"
import "core:os"
import "wb:tools/tooling"
import "wb:tools/wrentool/bench"
import "wb:tools/wrentool/capture"
import "wb:tools/wrentool/changelog"
import "wb:tools/wrentool/deps"
import "wb:tools/wrentool/gen"
import "wb:tools/wrentool/release"

EXIT_USAGE :: 2

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

COMMANDS := []Command{
	{"deps", "what a build needs, each up to date: [-Profile quick|release] [-Force]", deps.run_all},
	{"fetch", "wasmtime | wgpu | openh264 | emoji [-Force] [-Unicode] [-Dest dir]", deps.run_fetch},
	{"build", "lexbor | native [-Force] [-Profile quick|release] [-Features a,b]", deps.run_build},
	{"version-h", "build/wren_version.h from APP_VERSION", release.run_version_h},
	{"stale", "<output> <folder>...: exit code 1 when a source is newer than the output", release.run_stale},
	{"symbols", "-Publish exe [-Store] | -Fingerprint exe", deps.run_symbols},
	{"crash-symbolize", "<report> [-Symbols folder or .map] [-Exe exe]: names the frames of a crash report", deps.run_crash_symbolize},
	{"symbolize", "-Exe exe <offset>...: the function and line at an offset of a module", deps.run_symbolize},
	{"bench", "perf | shell | js | idle | webgl | blocker | sidebar | startup | cadence (bench help)", bench.run},
	{"capture", "-Url u -Out f.png [-Width n] [-Height n] [-Actions a] [-Exe path] [-Pref a=b] [-Page]: a page, headless", capture.run_capture},
	{"shots", "[-Only a,b] [-Width n] [-Height n] [-NoConvert] [-Exe path]: the README's and the site's pictures, headless", capture.run_shots},
	{"compare", "-Urls a,b | -List f [-OutDir d] [-Width n] [-Height n] [-Dark] [-Js] [-Exe path]: Wren against headless Edge", capture.run_compare},
	{"gen", "psl | unicode [-Force] | media-fixtures | video-fixtures | perf-media [-Force] | rust-crates [-Check]", gen.run_gen},
	{"docs", "[-Check] [-NoBuild] [-ChartUpdate]: the documentation site, its links checked", gen.run_docs},
	{"license", "keygen | pubkey | issue | verify ...: Wren's licences (docs/licence.md)", gen.run_license},
	{"i18n", "[-Missing] [-Json f]: the texts passed to tr, the interface's that are not", gen.run_i18n},
	{"portability", "[-Target t] [-Only a,b] [-Csv f] [-Expect f]: every package checked for another target", gen.run_portability},
	{"engine", "test262 [-Filter d] [-Stride n] [-Jobs n] [-NoBuild] | rx-diff [-Seed n] [-Fuzz n] [-NoC]", gen.run_engine},
	{"desktop", "<program> [arguments]: a command on a Windows desktop of its own", gen.run_desktop},
	{"changelog", "-New | -Check [-Release v] | -Assemble [-Version v] | -Section -Version v | -Migrate", changelog.run},
	{"package", "[-Version v] [-Dev] [-Extras] [-AllowUnreleased]: the release file from a finished build", release.run_package},
	{"sign", "a.exe b.exe: Authenticode, when the environment names an identity", release.run_sign},
	{"winget", "-Version v [-Url u] [-Sha256 h] [-Out d]: the manifest files; submits nothing", release.run_winget},
	{"notes", "-Tag v [-Ref r] [-Out f]: the notes of a release", release.run_notes},
	{"experimental", "[-Label l] [-NoBuild] [-NoUpload] [-NoVerify] [-NoEmbed] [-Notes f] [-Vault d]: a labelled build to hand out", release.run_experimental},
	{"smoke", "<wren executable>: the packaged executable end to end (needs a display)", release.run_smoke},
	{"crash-e2e", "Linux: every death of src/tools/crashmodes leaves its report", release.run_crash_e2e},
}

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" { usage(); return }
	root := tooling.repo_root()
	if os.set_working_directory(root) != nil { fmt.eprintfln("wrentool: cannot work in %s", root); os.exit(EXIT_USAGE) }
	for c in COMMANDS {
		if c.name == os.args[1] { os.exit(c.run(os.args[2:])) }
	}
	fmt.eprintfln("wrentool: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("wrentool <command> [arguments]")
	for c in COMMANDS { fmt.printfln("  %-16s %s", c.name, c.about) }
}
