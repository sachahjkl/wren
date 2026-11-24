#+build !windows
package builder

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "wb:tools/tooling"
import "wb:tools/wrentool/deps"

@(private)
has_lld :: proc() -> bool {
	_, code := tooling.capture({"ld.lld", "--version"}, allocator = context.temp_allocator)
	return code == 0
}

// Save split debug info under build/symbols and strip release binaries unless a packager (Nix separateDebugInfo) keeps symbols to split them itself.
@(private)
finalize_release_symbols :: proc(program, log: string) -> bool {
	if id, ok := deps.build_id_of(program); ok {
		_ = os.make_directory_all(deps.SYMBOL_STORE)
		debug_file := fmt.tprintf("%s/%s-%s.debug", deps.SYMBOL_STORE, filepath.base(program), id)
		if tooling.run({command = {"objcopy", "--only-keep-debug", program, debug_file}, log = log}) == 0 {
			tooling.say(log, fmt.tprintfln("symbols: %s", debug_file))
		}
	}
	// .note.gnu.build-id is SHF_ALLOC and stays intact after stripping
	if env("WREN_KEEP_SYMBOLS") == "" {
		if tooling.run({command = {"strip", "--strip-all", program}, log = log}) != 0 {
			return false
		}
	}
	return true
}
