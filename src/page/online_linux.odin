package page

import "core:os"
import "core:strings"

// navigator.onLine: is an interface other than loopback up (/sys/class/net/<if>/operstate "up", or "unknown" as
// point-to-point links and some virtual adapters say)? True when the system does not say: offline must be certain.
network_alive :: proc() -> bool {
	infos, err := os.read_all_directory_by_path("/sys/class/net", context.temp_allocator)
	if err != nil || len(infos) == 0 { return true }
	for fi in infos {
		if fi.name == "lo" { continue }
		state, rerr := os.read_entire_file(strings.concatenate({fi.fullpath, "/operstate"}, context.temp_allocator), context.temp_allocator)
		if rerr != nil { continue }
		s := strings.trim_space(string(state))
		if s == "up" || s == "unknown" { return true }
	}
	return false
}
