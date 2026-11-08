// Package release: the release's files, from a finished build. Nothing here tags or publishes; the release workflow does.
//   wrentool package [-Version v] [-Dev] [-Extras] [-AllowUnreleased]     build\dist: the one file wren-<version>-windows-x64.exe, its SHA-256; Linux: the tar.gz
//   wrentool sign a.exe b.exe                                              Authenticode, when a signing identity is in the environment
//   wrentool winget -Version v [-Url u] [-Sha256 h] [-Out dir]             the three manifest files; submits nothing (docs/winget.md)
//   wrentool notes -Tag v [-Ref r] [-Out f] [-MaxLine n] [-Limit n]        the notes of a release
//   wrentool experimental [-Label l] [-NoBuild] [-NoUpload] [-NoVerify] [-NoEmbed] [-Notes f] [-Vault dir]
//   wrentool smoke <wren executable>                                       the packaged executable end to end (a display: xvfb-run)
//   wrentool crash-e2e                                                     Linux: every death of src/tools/crashmodes leaves its report
package release

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:tools/tooling"
import "wb:tools/wrentool/builder"
import "wb:tools/wrentool/changelog"
import "wb:tools/wrentool/deps"
import "wb:tools/wrentool/gen"
import toolbox "../../../../ext/gui_toolkit/src/toolbox"

EXIT_USAGE :: 2
DIST :: "build/dist"
REPOSITORY :: "sachahjkl/wren"
BYTES_PER_MB :: 1024 * 1024
RUNTIME_DLLS := []string{"vcruntime", "msvcp", "vcomp", "concrt", "ucrtbase", "api-ms-win-crt"}
EXTRAS_GUESTS := []string{"counter", "formstest", "mutation", "mutation_class", "workerstest_worker"}
DEMOS_INDEX_MARK :: "Made from the DEMOS table"
EXTRAS_README :: `Wren %s: demos and test material (%s)
Extract this archive into the folder of wren.exe (the files here are meant to sit beside it; name the program wren.exe).

  demos\                    the demo and test pages and their Wasm modules; demos\index.html lists them (so does about:demos)
  examples\                 the script loading and web API demos, served by testserver.exe
  testserver.exe            the demo server: http://127.0.0.1:8765/site/ (serves demos\)
  demo.bat                  starts the demo server and opens about:demos (it starts wren.exe)

The pages of demos\ open directly; those marked "test server" need testserver.exe running from this folder, as demo.bat
does (images, media, form submission, slow stylesheets, CSP, script loading, web APIs). browser.demos.path in about:config
points about:demos to another folder.
`
EXTRAS_DEMO_BAT :: "@echo off\r\n:: Serves the demo pages (demos\\) on http://127.0.0.1:8765 and opens about:demos in Wren. Close the server window to stop it.\r\ncd /D \"%~dp0\"\r\nstart \"Wren demo server\" /min testserver.exe\r\nstart \"\" wren.exe about:demos\r\n"
LINUX_README :: `Wren %s for Linux x86-64, an early preview. Start it with ./wren

It needs, from your distribution:
  to start      glibc 2.39 or later (Ubuntu 24.04, Debian 13, Fedora 40), libopus, libasound, libfontconfig
                  Debian, Ubuntu: apt install libopus0 libasound2 libfontconfig1
                  Fedora: dnf install opus alsa-lib fontconfig
                  Arch: pacman -S opus alsa-lib fontconfig
  for a window  libwayland-client and libxkbcommon, or libxcb and libxkbcommon-x11; for the theme's cursors, libwayland-cursor or libxcb-cursor (optional)
                a Vulkan or OpenGL driver (Mesa's is enough)
  for H.264     Cisco's openh264; AV1 and VP9 are built in
  for dialogs   zenity or kdialog

NixOS: start it once with steam-run (or nix-ld with the libraries above) and choose Install in Setup. The installed
copy gets its libraries from Nix and then starts by itself. Or install the Nix package: nix profile add git+https://github.com/sachahjkl/wren

https://github.com/sachahjkl/wren
`

// The version the sources say.
source_version :: builder.source_version

@(private) env :: proc(name: string) -> string { v, _ := os.lookup_env(name, context.temp_allocator); return v }

// The label of a build that is not the release (WREN_VERSION_LABEL), as a file's name may carry it.
version_label :: proc() -> string { return builder.version_label(env("WREN_VERSION_LABEL")) }

@(private) fail :: proc(args: ..any) -> int { fmt.eprintln(..args); return 1 }

////////////////////////////////
// package

run_package :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Version= -Dev -Extras -AllowUnreleased -RequireUpdateManifest")
	if !ok { return EXIT_USAGE }
	version := tooling.flag(f, "-Version", source_version())
	if version == "" { return fail("APP_VERSION not found in", builder.ABOUT_FILE) }
	when ODIN_OS == .Windows { return package_windows(f, version) } else { return package_linux(version) }
}

@(private)
package_linux :: proc(version: string) -> int {
	if !os.exists("build/wren") { return fail("build/wren is missing: run ./build.sh release first") }
	name := fmt.tprintf("wren-%s-linux-x64", version)
	stage := fmt.tprintf("%s/%s", DIST, name)
	base.remove_tree(stage)
	_ = os.make_directory_all(stage)
	defer base.remove_tree(stage)
	if os.copy_file(fmt.tprintf("%s/wren", stage), "build/wren") != nil { return fail("build/wren cannot be copied") }
	_ = tooling.run({command = {"chmod", "+x", fmt.tprintf("%s/wren", stage)}})
	_ = tooling.run({command = {"strip", "--strip-debug", fmt.tprintf("%s/wren", stage)}})
	_ = os.copy_file(fmt.tprintf("%s/LICENSE", stage), "LICENSE")
	_ = os.write_entire_file(fmt.tprintf("%s/README.txt", stage), fmt.tprintf(LINUX_README, version))
	tar_name := fmt.tprintf("%s.tar.gz", name)
	if tooling.run({command = {"tar", "-C", DIST, "-czf", fmt.tprintf("%s/%s", DIST, tar_name), name}}) != 0 { return fail("tar failed") }
	sha, _ := toolbox.sha256_file(fmt.tprintf("%s/%s", DIST, tar_name))
	_ = os.write_entire_file(fmt.tprintf("%s/SHA256SUMS-linux.txt", DIST), fmt.tprintf("%s  %s\n", sha, tar_name))
	fmt.printfln("%s/%s", DIST, tar_name)
	return 0
}

@(private)
find_file_under :: proc(dir, name, must_contain: string) -> string {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return "" }
	for e in entries {
		if e.type == .Directory { if hit := find_file_under(e.fullpath, name, must_contain); hit != "" { return hit }; continue }
		normal, _ := strings.replace_all(e.fullpath, "\\", "/", context.temp_allocator)
		if e.name == name && strings.contains(normal, must_contain) { return e.fullpath }
	}
	return ""
}

// The program needs no file beside it: no import of the Visual C++ runtime DLLs. (What the runner has of dumpbin: without it, not checked.)
@(private)
check_no_runtime_imports :: proc() -> bool {
	dumpbin := ""
	for program_files in ([]string{env("ProgramFiles"), env("ProgramFiles(x86)")}) {
		dumpbin = find_file_under(fmt.tprintf("%s/Microsoft Visual Studio", program_files), "dumpbin.exe", "Hostx64/x64")
		if dumpbin != "" { break }
	}
	if dumpbin == "" { return true }
	text, code := tooling.capture({dumpbin, "/dependents", "build/wren.exe"}, allocator = context.temp_allocator)
	if code != 0 { return true }
	for line in strings.split_lines(text, context.temp_allocator) {
		dll := strings.to_lower(strings.trim_space(line), context.temp_allocator)
		if !strings.has_suffix(dll, ".dll") { continue }
		for bad in RUNTIME_DLLS {
			if strings.has_prefix(dll, bad) { fmt.eprintfln("wren.exe imports %s: the release must carry its runtime (Wren links the C runtime in: libcmt, libucrt, libvcruntime)", dll); return false }
		}
	}
	return true
}

@(private)
package_windows :: proc(f: tooling.Flags, version: string) -> int {
	dev, extras := tooling.flag_has(f, "-Dev"), tooling.flag_has(f, "-Extras")
	if !os.exists("build/wren.exe") { return fail("build/wren.exe is missing: run build.bat release first") }
	// a package is a release: never a development build (blueprint icon, "development build" in the browser)
	channel := deps.read_stamp("build/wren.channel")
	if dev && channel != "dev" { return fail("build/wren.exe is a", channel, "build, not a development one (-Dev)") }
	if !dev && channel != "release" { return fail("build/wren.exe is a", channel, "build, not a release one: run build.bat release first") }
	if !gen.rust_crates_up_to_date() { return 1 }
	if !check_no_runtime_imports() { return 1 }
	label := version_label()
	if !dev && label == "" && !tooling.flag_has(f, "-AllowUnreleased") {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		if !changelog.check_release(cwd, version) { return fail("the CHANGELOG is not ready for", version, ": wrentool changelog -Assemble -Version", version, "(or -AllowUnreleased to try a package)") }
	}
	name := fmt.tprintf("wren-%s%s%s-windows-x64", version, label, dev ? "-dev" : "")
	_ = os.make_directory_all(fmt.tprintf("%s/symbols", DIST))
	exe := fmt.tprintf("%s/%s.exe", DIST, name)
	if os.copy_file(exe, "build/wren.exe") != nil { return fail("build/wren.exe cannot be copied") }
	// the build's symbols go beside the package, never in what is published: CI keeps them as an artifact, crash-symbolize reads them
	fp, _ := deps.fingerprint_of("build/wren.exe")
	map_file := fmt.tprintf("build/wren-%s.map", fp)
	if !os.exists(map_file) { return fail(map_file, "is missing: the symbols of build/wren.exe (wrentool build writes them; wrentool symbols -Publish build/wren.exe after a link of its own)") }
	symbols := fmt.tprintf("%s/symbols/%s-%s.map", DIST, name, fp)
	_ = os.copy_file(symbols, map_file)
	files := make([dynamic]string, context.temp_allocator)
	append(&files, exe)
	to_sign := make([dynamic]string, context.temp_allocator)
	append(&to_sign, exe)
	extras_dir := fmt.tprintf("%s/%s-extras", DIST, name)
	if extras {
		code := package_extras(extras_dir, version)
		if code != 0 { return code }
		append(&to_sign, fmt.tprintf("%s/testserver.exe", extras_dir))
	}
	if !sign_files(to_sign[:]) { return 1 }
	if extras {
		zip := fmt.tprintf("%s/%s-extras.zip", DIST, name)
		_ = os.remove(zip)
		if tooling.run({command = {"tar", "-a", "-c", "-f", fmt.tprintf("../%s-extras.zip", name), "."}, dir = extras_dir}) != 0 { return fail("the extras cannot be zipped") }
		append(&files, zip)
	}
	sums := strings.builder_make(context.temp_allocator)
	for z in files {
		sha, _ := toolbox.sha256_file(z)
		fmt.sbprintfln(&sums, "%s  %s", sha, filepath.base(z))
		fi, _ := os.stat(z, context.temp_allocator)
		fmt.printfln("packaged %s (%d MB)", z, fi.size / BYTES_PER_MB)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/SHA256SUMS.txt", DIST), strings.to_string(sums))
	// the signed manifest an installed Wren updates itself from (src/update): the release workflow requires it, a local package may go without
	if !dev && !package_update_manifest(exe, version, "windows-x64", DIST, tooling.flag_has(f, "-RequireUpdateManifest")) { return 1 }
	fmt.printfln("symbols  %s (build %s; not published)", symbols, fp)
	return 0
}

// The demo material without a checkout of the repository, at the root of the archive: the demo pages, the script loading and web API demos, the test server. The release does not publish it.
@(private)
package_extras :: proc(dir, version: string) -> int {
	base.remove_tree(dir)
	_ = os.make_directory_all(fmt.tprintf("%s/examples/jsweb", dir))
	// the Wasm modules the demo pages load, and the server for the others
	for g in EXTRAS_GUESTS {
		if tooling.run({command = {tooling.odin_program(), "build", fmt.tprintf("examples/%s", g), "-target:freestanding_wasm32", "-no-entry-point", "-default-to-nil-allocator", "-collection:wren=sdk/odin", fmt.tprintf("-out:examples/site/%s.wasm", g), "-o:size"}}) != 0 { return fail("building examples/", g, "failed") }
	}
	index, _ := os.read_entire_file("examples/site/index.html", context.temp_allocator)
	if !strings.contains(string(index), DEMOS_INDEX_MARK) { return fail("examples/site/index.html is not the demos index (src/browser/demos_index.odin)") }
	// every module a page names must be there (a page added later with a new guest fails here, not in the user's hands)
	if !guests_built("examples/site") { return 1 }
	server := "build/testserver.exe"
	full, _ := filepath.abs(server, context.temp_allocator)
	if tooling.run({command = {"go", "build", "-trimpath", "-o", full, "./cmd/testserver"}, dir = "tools/testserver"}) != 0 { return fail("go build of the test server failed") }
	_ = os.copy_file(fmt.tprintf("%s/testserver.exe", dir), server)
	if os.copy_directory_all(fmt.tprintf("%s/demos", dir), "examples/site") != nil { return fail("the demos cannot be copied") }
	// (testserver.exe serves them from examples/ under its working folder, which demo.bat makes the folder of wren.exe)
	if os.copy_directory_all(fmt.tprintf("%s/examples/jsload", dir), "examples/jsload") != nil { return fail("examples/jsload cannot be copied") }
	_ = os.copy_file(fmt.tprintf("%s/examples/jsweb/demo.html", dir), "examples/jsweb/demo.html")
	commit, _ := tooling.capture({"git", "rev-parse", "--short", "HEAD"}, allocator = context.temp_allocator)
	readme, _ := strings.replace_all(fmt.tprintf(EXTRAS_README, version, strings.trim_space(commit)), "\n", "\r\n", context.temp_allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/README-extras.txt", dir), readme)
	_ = os.write_entire_file(fmt.tprintf("%s/demo.bat", dir), EXTRAS_DEMO_BAT)
	return 0
}

@(private)
guests_built :: proc(dir: string) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return true }
	MARK :: `src="`
	for e in entries {
		if e.type == .Directory { if !guests_built(e.fullpath) { return false }; continue }
		if !strings.has_suffix(e.name, ".html") { continue }
		html, _ := os.read_entire_file(e.fullpath, context.temp_allocator)
		text := string(html)
		for {
			i := strings.index(text, MARK)
			if i < 0 { break }
			text = text[i + len(MARK):]
			end := strings.index_byte(text, '"')
			if end < 0 { break }
			name := text[:end]
			if strings.has_suffix(name, ".wasm") && !strings.contains_any(name, "/:") && !os.exists(fmt.tprintf("%s/%s", dir, name)) { fmt.eprintfln("%s loads %s, which is not built", e.name, name); return false }
		}
	}
	return true
}

////////////////////////////////
// sign

SIGN_TIMESTAMP_DEFAULT :: "http://timestamp.digicert.com"
SIGN_TIMESTAMP_AZURE :: "http://timestamp.acs.microsoft.com"
SIGN_URL :: "https://github.com/sachahjkl/wren"
WINDOWS_KITS_BIN :: "Windows Kits/10/bin"

run_sign :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprintln("wrentool sign a.exe b.exe"); return EXIT_USAGE }
	return sign_files(args) ? 0 : 1
}

// Authenticode (signtool), timestamped (RFC 3161: it stays valid after the certificate expires) and checked. Nothing happens unless the environment names an identity (the CI's secrets; nothing is stored in the repository):
//   SIGN_PFX + SIGN_PFX_PASSWORD   a .pfx file: only a test one, certificate authorities no longer hand out exportable keys for public code signing
//   SIGN_SERVICE=azure             Azure Artifact Signing: SIGN_AZURE_DLIB, SIGN_AZURE_METADATA; credentials from the Azure environment
//   SIGN_TIMESTAMP, SIGNTOOL       the timestamp server; the path of signtool.exe
//   SIGN_TEST=1                    a self-signed test certificate: the signature's content is checked, not the trust of its chain
sign_files :: proc(files: []string) -> bool {
	pfx, service := env("SIGN_PFX"), env("SIGN_SERVICE")
	if pfx == "" && service == "" { fmt.println("sign: no signing identity configured (SIGN_PFX or SIGN_SERVICE): files left unsigned"); return true }
	if pfx != "" && service != "" { fmt.eprintln("sign: SIGN_PFX and SIGN_SERVICE are both set: choose one"); return false }
	signtool := env("SIGNTOOL")
	if signtool == "" { signtool = find_signtool() }
	if signtool == "" { fmt.eprintln("sign: signtool.exe not found (install the Windows SDK, or set SIGNTOOL)"); return false }
	stamp := env("SIGN_TIMESTAMP")
	if stamp == "" { stamp = service == "azure" ? SIGN_TIMESTAMP_AZURE : SIGN_TIMESTAMP_DEFAULT }
	for file in files {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, signtool, "sign", "/fd", "SHA256")
		if pfx != "" {
			if !os.exists(pfx) { fmt.eprintfln("sign: SIGN_PFX points to nothing: %s", pfx); return false }
			append(&cmd, "/f", pfx, "/p", env("SIGN_PFX_PASSWORD"))   // (the only place that sees it)
		} else if service == "azure" {
			if env("SIGN_AZURE_DLIB") == "" || env("SIGN_AZURE_METADATA") == "" { fmt.eprintln("sign: SIGN_SERVICE=azure needs SIGN_AZURE_DLIB and SIGN_AZURE_METADATA"); return false }
			append(&cmd, "/dlib", env("SIGN_AZURE_DLIB"), "/dmdf", env("SIGN_AZURE_METADATA"))
		} else { fmt.eprintfln("sign: unknown SIGN_SERVICE '%s' (azure)", service); return false }
		append(&cmd, "/tr", stamp, "/td", "SHA256", "/d", "Wren", "/du", SIGN_URL, file)
		if tooling.run({command = cmd[:]}) != 0 { fmt.eprintfln("sign: signtool failed on %s", file); return false }
		// /pa checks the chain of trust; a test certificate has none: /pa is then left to what verify says of the content, the exit code of /all
		verify := make([dynamic]string, context.temp_allocator)
		append(&verify, signtool, "verify", "/pa", "/all", file)
		text, code := tooling.capture(verify[:], allocator = context.temp_allocator)
		if env("SIGN_TEST") == "1" {
			if strings.contains(text, "SignTool Error: No signature found") || strings.contains(text, "does not match") { fmt.eprintfln("sign: %s has no good signature: %s", file, text); return false }
			if !strings.contains(text, "Timestamp") { fmt.eprintfln("sign: the signature of %s is not timestamped: %s", file, text); return false }
			fmt.printfln("sign: %s signed with a test certificate (the chain is not trusted, as expected), timestamped", file)
		} else if code != 0 { fmt.eprintfln("sign: %s does not verify (signtool verify /pa): %s", file, text); return false }
	}
	return true
}

@(private)
find_signtool :: proc() -> string {
	dir := fmt.tprintf("%s/%s", env("ProgramFiles(x86)"), WINDOWS_KITS_BIN)
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return "" }
	newest := ""
	for e in entries {
		path := fmt.tprintf("%s/x64/signtool.exe", e.fullpath)
		if e.type == .Directory && os.exists(path) && path > newest { newest = path }
	}
	return newest
}

////////////////////////////////
// winget

WINGET_PACKAGE :: "FromentSoftware.Wren"
WINGET_MANIFEST_VERSION :: "1.6.0"
SHA256_HEX :: 64

WINGET_VERSION_YAML :: `# yaml-language-server: $schema=https://aka.ms/winget-manifest.version.1.6.0.schema.json
PackageIdentifier: %[0]s
PackageVersion: %[1]s
DefaultLocale: en-US
ManifestType: version
ManifestVersion: %[2]s
`
WINGET_INSTALLER_YAML :: `# yaml-language-server: $schema=https://aka.ms/winget-manifest.installer.1.6.0.schema.json
PackageIdentifier: %[0]s
PackageVersion: %[1]s
InstallerType: portable
Commands:
  - wren
ReleaseDate: %[3]s
Installers:
  - Architecture: x64
    InstallerUrl: %[4]s
    InstallerSha256: %[5]s
    InstallerType: portable
    NestedInstallerFiles:
      - RelativeFilePath: %[6]s
        PortableCommandAlias: wren
ManifestType: installer
ManifestVersion: %[2]s
`
WINGET_LOCALE_YAML :: `# yaml-language-server: $schema=https://aka.ms/winget-manifest.defaultLocale.1.6.0.schema.json
PackageIdentifier: %[0]s
PackageVersion: %[1]s
PackageLocale: en-US
Publisher: Froment Software
PublisherUrl: https://froment.software
PublisherSupportUrl: https://sachahjkl.github.io/wren/pricing/
PackageName: Wren
PackageUrl: https://github.com/%[3]s
License: PolyForm Strict License 1.0.0
LicenseUrl: https://polyformproject.org/licenses/strict/1.0.0/
Copyright: Copyright (c) Sacha Froment
ShortDescription: A small browser where WebAssembly runs everything, JavaScript included.
Description: |-
  Wren is a web browser written in Odin where WebAssembly is the only execution engine: there is no separate JavaScript
  virtual machine for the platform, and the web APIs are WebAssembly imports. The JavaScript interpreter runs page
  scripts only; everything else of the browser is native. The release is a single portable executable with no installer:
  it carries its own licences, version and the Visual C++ runtime it needs. Run it, or install the desktop integration
  from within the program (Setup).
Moniker: wren
Tags:
  - browser
  - web-browser
  - webassembly
  - wasm
  - odin
ManifestType: defaultLocale
ManifestVersion: %[2]s
`

@(private)
today :: proc(allocator := context.temp_allocator) -> string {
	buf: [32]u8
	return strings.clone(time.to_string_yyyy_mm_dd(time.now(), buf[:]), allocator)
}

// The three YAML files winget wants, for a published release: to put under manifests\f\FromentSoftware\Wren\<version>\ of a fork of microsoft/winget-pkgs. It does not submit anything (docs/winget.md).
run_winget :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Version= -Url= -Sha256= -Out= -Repo=")
	if !ok || !tooling.flag_has(f, "-Version") { fmt.eprintln("wrentool winget -Version v [-Url u] [-Sha256 h] [-Out dir]"); return EXIT_USAGE }
	version := strings.trim_prefix(tooling.flag(f, "-Version"), "v")
	for c in transmute([]u8)version { if !(c >= '0' && c <= '9' || c == '.') { return fail("version", version, "is not a dotted number (e.g. 0.4.0)") } }
	repo := tooling.flag(f, "-Repo", REPOSITORY)
	exe_name := fmt.tprintf("wren-%s-windows-x64.exe", version)
	tag := fmt.tprintf("v%s", version)
	url := tooling.flag(f, "-Url", fmt.tprintf("https://github.com/%s/releases/download/%s/%s", repo, tag, exe_name))
	sha := tooling.flag(f, "-Sha256")
	if sha == "" {
		// the published release's SHA256SUMS.txt
		sums_url := fmt.tprintf("https://github.com/%s/releases/download/%s/SHA256SUMS.txt", repo, tag)
		fmt.printfln("reading %s for the SHA-256 of %s", sums_url, exe_name)
		text, code := tooling.capture({"curl", "-fsSL", sums_url}, allocator = context.temp_allocator)
		if code != 0 { return fail("the release", tag, "has no SHA256SUMS.txt: pass -Sha256 explicitly") }
		for line in strings.split_lines(text, context.temp_allocator) {
			if strings.contains(line, exe_name) { sha = strings.fields(line, context.temp_allocator)[0] }
		}
		if sha == "" { return fail("SHA256SUMS.txt does not mention", exe_name) }
	}
	sha = strings.to_upper(sha, context.temp_allocator)
	if len(sha) != SHA256_HEX || !deps.is_hex(sha) { return fail("the SHA-256", sha, "is not 64 hex characters") }
	out := tooling.flag(f, "-Out", fmt.tprintf("build/winget/%s", version))
	_ = os.make_directory_all(out)
	write :: proc(out, name, text: string) {
		// winget-pkgs wants CRLF and a trailing newline in every file
		crlf, _ := strings.replace_all(text, "\n", "\r\n", context.temp_allocator)
		path := fmt.tprintf("%s/%s", out, name)
		_ = os.write_entire_file(path, crlf)
		fmt.printfln("wrote %s", path)
	}
	write(out, fmt.tprintf("%s.yaml", WINGET_PACKAGE), fmt.tprintf(WINGET_VERSION_YAML, WINGET_PACKAGE, version, WINGET_MANIFEST_VERSION))
	write(out, fmt.tprintf("%s.installer.yaml", WINGET_PACKAGE), fmt.tprintf(WINGET_INSTALLER_YAML, WINGET_PACKAGE, version, WINGET_MANIFEST_VERSION, today(), url, sha, exe_name))
	write(out, fmt.tprintf("%s.locale.en-US.yaml", WINGET_PACKAGE), fmt.tprintf(WINGET_LOCALE_YAML, WINGET_PACKAGE, version, WINGET_MANIFEST_VERSION, repo))
	fmt.printfln("\nnext: winget validate \"%s\"  then  winget install --manifest \"%s\" (docs/winget.md). Nothing was submitted.", out, out)
	return 0
}

////////////////////////////////
// notes

NOTES_MAX_LINE :: 200
// The body of a GitHub release is at most 125 000 characters (a longer one is refused with HTTP 422: it stopped the release of 0.4.0, whose notes were 185 000).
NOTES_LIMIT :: 120_000
NOTES_CUT_MARGIN :: 200
SHORTEN_FROM :: 40

// A change line is the commit's subject up to its first sentence (subjects carry their details after "(" or "; ").
shorten_subject :: proc(subject: string, max_line: int) -> string {
	s := subject
	if strings.has_prefix(s, "Merge ") {
		// a merge's subject says what the branch brings
		if i := strings.index(s, ": "); i > 0 { s = s[i + 2:] }
	}
	cut := len(s)
	for sep in ([]string{" (", "; "}) {
		i := strings.index(s, sep)
		if i >= SHORTEN_FROM && i < cut { cut = i }
	}
	s = strings.trim_right(s[:cut], " ,:")
	if len(s) > max_line {
		i := strings.last_index_byte(s[:max_line], ' ')
		s = strings.trim_right(s[:i > 0 ? i : max_line], " ,:")
		s = fmt.tprintf("%s …", s)
	}
	return s
}

// Merges of master (or main) back into a branch repeat changes already listed.
@(private)
merge_of_main :: proc(s: string) -> bool {
	if !strings.has_prefix(s, "Merge ") { return false }
	for name in ([]string{"branch 'master' into", "branch 'main' into", "branch master into", "branch main into", "remote-tracking branch 'origin/master' into", "remote-tracking branch 'origin/main' into"}) {
		if strings.contains(s, name) { return true }
	}
	return false
}

// docs/releases/<tag>.md when it exists (the highlights), the version's section of CHANGELOG.md, then the changes since the previous version tag from the first-parent history. What does not fit whole is replaced by a line that says where to read it.
run_notes :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Tag= -Ref= -Out= -MaxLine= -Limit=")
	if !ok || !tooling.flag_has(f, "-Tag") { fmt.eprintln("wrentool notes -Tag v0.2.0 [-Ref HEAD] [-Out file] [-MaxLine n] [-Limit n]"); return EXIT_USAGE }
	tag := tooling.flag(f, "-Tag")
	ref := tooling.flag(f, "-Ref", tag)
	limit := tooling.flag_int(f, "-Limit", NOTES_LIMIT)
	text := strings.builder_make(context.temp_allocator)
	if intro, err := os.read_entire_file(fmt.tprintf("docs/releases/%s.md", tag), context.temp_allocator); err == nil {
		fmt.sbprintf(&text, "%s\n\n", strings.trim_right_space(string(intro)))
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	section := ""
	if s, has := changelog.section(cwd, strings.trim_prefix(tag, "v"), context.temp_allocator); has { section = strings.trim_space(s) }
	if section != "" {
		if strings.builder_len(text) + len(section) + 2 <= limit {
			fmt.sbprintf(&text, "%s\n\n", section)
		} else {
			fmt.sbprintf(&text, "The full list of what this version changes is in [CHANGELOG.md](https://github.com/%s/blob/%s/CHANGELOG.md): too long for these notes.\n\n", REPOSITORY, tag)
		}
	}
	prev_text, code := tooling.capture({"git", "describe", "--tags", "--abbrev=0", "--match", "v*", fmt.tprintf("%s^", ref)}, allocator = context.temp_allocator)
	prev := code == 0 ? strings.trim_space(prev_text) : ""
	range_ := prev != "" ? fmt.tprintf("%s..%s", prev, ref) : ref
	subjects, log_code := tooling.capture({"git", "log", "--first-parent", "--reverse", "--format=%s", range_}, allocator = context.temp_allocator)
	if log_code != 0 { return fail("git log", range_, "failed") }
	history := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&history, "<details><summary>%s</summary>\n\n", prev != "" ? fmt.tprintf("Changes since %s", prev) : "Changes (the whole history)")
	for s in strings.split_lines(subjects, context.temp_allocator) {
		line := strings.trim_right(s, "\r")
		if line == "" || merge_of_main(line) { continue }
		fmt.sbprintf(&history, "- %s\n", shorten_subject(line, tooling.flag_int(f, "-MaxLine", NOTES_MAX_LINE)))
	}
	strings.write_string(&history, "\n</details>\n")
	if strings.builder_len(text) + strings.builder_len(history) <= limit {
		strings.write_string(&text, strings.to_string(history))
	} else {
		fmt.sbprintf(&text, "The changes since %s are in the history of the repository (`git log --first-parent %s`): too long for these notes.\n", prev, range_)
	}
	body := strings.to_string(text)
	if len(body) > limit {   // (the highlights alone are too long: cut at a line)
		cut := strings.last_index_byte(body[:limit - NOTES_CUT_MARGIN], '\n')
		body = fmt.tprintf("%s\n\n(cut here)\n", body[:cut])
	}
	if out := tooling.flag(f, "-Out"); out != "" {
		_ = os.make_directory_all(filepath.dir(out))
		return os.write_entire_file(out, body) == nil ? 0 : 1
	}
	fmt.print(body)
	return 0
}
