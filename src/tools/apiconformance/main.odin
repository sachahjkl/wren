// Conformance of the binding layer: runs every case of cases_generated.odin (generated from api/*.widl with the guest
// examples/apiconformance) in a page, and checks that the browser refuses bad arguments the way the
// description says: an address outside the memory traps, invalid UTF-8 / a dead handle / an enum out of range is an
// Error for a function that raises and a trap for one that does not, and a string result reports its full length into a
// buffer too small without writing past it. Needs no network. Run from the repository root:
//   apiconformance.exe build\apiconformance.wasm
package apiconformance

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:net"
import "wb:page"
import "wb:wasm"

console :: proc(user: rawptr, level: page.Log_Level, message: string) {}

main :: proc() {
	if len(os.args) < 2 { fmt.eprintln("usage: apiconformance apiconformance.wasm"); os.exit(2) }
	image, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil { fmt.eprintln("cannot read the module"); os.exit(2) }

	loop: host.Loop
	client: net.Client
	blocking: host.Blocking_Pool
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 1)
	profile := fetch.profile_make()
	loader: fetch.Loader
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)
	settings := page.settings_default()
	wasm.configure_from_args(os.args[1:])
	if !page.register_imports() { fmt.eprintln("register failed"); os.exit(2) }
	process := base.scope_make("process")

	p := page.page_create(&loop, &loader, &settings, process, "http://127.0.0.1:8765/conformance.html", console)
	inst, ok, lerr := page.load_module(p, image, "apiconformance")
	if !ok { fmt.eprintln("cannot load the guest:", lerr); os.exit(2) }

	failures := 0
	counts: [Expect]int
	capacity_skipped := 0
	fns := make(map[string]bool)
	for c in CASES {
		argv: [2]u32
		res := page.call_export(p, inst, c.export, argv[:])
		result := i64(u64(argv[0]) | u64(argv[1]) << 32)
		pass := false
		switch c.expect {
		case .Trap_Bounds:  pass = res == .Trapped && strings.contains(inst.last_error, "out of bounds")
		case .Trap_Message: pass = res == .Trapped && strings.contains(inst.last_error, c.function)
		case .Error_Code:   pass = res == .Ok && result == c.code
		case .Error_Any:    pass = res == .Ok && result < 0
		case .Capacity:
			pass = res == .Ok && result >= 0
			if result > 0 { capacity_skipped += 1 }
		}
		counts[c.expect] += 1
		fns[c.function] = true
		if !pass {
			failures += 1
			fmt.printf("FAIL %s (%s): expected %v %d, got %v %d %q\n", c.function, c.what, c.expect, c.code, res, result, inst.last_error)
		}
	}
	fmt.printf("%d cases over %d of %d functions: %d out-of-bounds traps, %d other traps, %d exact errors, %d errors, %d capacity checks (%d without a result to measure)\n",
		len(CASES), len(fns), FUNCTIONS, counts[.Trap_Bounds], counts[.Trap_Message], counts[.Error_Code], counts[.Error_Any], counts[.Capacity], capacity_skipped)
	r, res := wasm.call_i32(inst, "case_count")
	if res != .Ok || int(r) != len(CASES) { fmt.println("FAIL the guest and the table disagree"); failures += 1 }
	fmt.printf("%d failure(s)\n", failures)
	page.page_close(p)
	os.exit(failures == 0 ? 0 : 1)
}
