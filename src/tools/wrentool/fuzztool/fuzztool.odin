// wrentool fuzz: the driver of the fuzzer of the parsers (src/md/features/fuzzing.md). It builds the worker
// (src/tools/fuzz), runs one per target with a time limit, and keeps the input of each abnormal end with the command
// that replays it. wrentool links no native library: the targets live in the worker.
package fuzztool

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:time"
import "wb:tools/tooling"

EXIT_USAGE :: 2

// The worker's exit codes (src/tools/fuzz/main.odin): any other code, a signal or the driver's limit is a crash.
WORKER_PASS :: 0
WORKER_SETUP :: 2
WORKER_LEAK :: 3
WORKER_HANG :: 4

WORKER :: "build/fuzz_worker"
WORKER_ASAN :: "build/fuzz_worker_asan"
FUZZ_DIR :: "build/fuzz"
DEFAULT_SECONDS :: 60
DEFAULT_HANG_SECONDS :: 10
// What a worker gets past its -Seconds before the driver ends it: the reading of its corpus, the warm-up of every seed,
// and one input that runs up to the hang limit. Past it the worker hangs where its watchdog cannot see (a native call
// that holds the clock thread too, a deadlock at exit).
GRACE :: 120 * time.Second
// A shrink runs the worker once per try: a bound on its minutes.
MINIMIZE_RUNS :: 2000
// LeakSanitizer would report at exit what the worker keeps on purpose (its corpus): the tracker checks leaks per input.
// (In the driver's environment, so that every child has it, the -List of `capture` too.)
ASAN_OPTIONS :: "detect_leaks=0:abort_on_error=1"

Outcome :: enum { Pass, Setup, Leak, Hang, Crash }
OUTCOME_NAME := [Outcome]string{.Pass = "pass", .Setup = "setup", .Leak = "leak", .Hang = "hang", .Crash = "crash"}

usage :: proc() {
	fmt.eprintln("wrentool fuzz [-Target name|a,b|all] [-Seconds n] [-Iterations n] [-Seed n] [-HangSeconds n] [-Asan] [-Speed]")
	fmt.eprintln("wrentool fuzz -Target name -Repro file | -Target name -Minimize file | -List")
	fmt.eprintln("  -Seconds: per target (default 60). -Iterations: a fixed count, the same inputs at each run. -Asan: AddressSanitizer in place of the poison (Linux).")
	fmt.eprintln("  Findings: build/fuzz/<target>/<crash|leak|hang>-<hash>. The JavaScript engine: ext/gui_toolkit/tools/js_judge (fuzz, fuzzsrc).")
}

run :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Target= -Seconds= -Iterations= -Seed= -HangSeconds= -Repro= -Minimize= -Asan -Speed -List")
	if !ok || len(f.rest) > 0 { usage(); return EXIT_USAGE }
	asan := tooling.flag_has(f, "-Asan")
	when ODIN_OS != .Linux {
		// (Windows: -sanitize:address needs the link of src/tools/test_all/asan.odin, which the worker does not have)
		if asan { fmt.eprintln("wrentool fuzz: -Asan is for Linux; on Windows the worker poisons freed memory"); return EXIT_USAGE }
	}
	if asan { os.set_env("ASAN_OPTIONS", ASAN_OPTIONS) }
	worker, built := build_worker(asan, tooling.flag_has(f, "-Speed"))
	if !built { return 1 }
	// (Linux: the soft limit of the stack is what a child's main thread gets; Windows: the worker carries /STACK)
	tooling.raise_stack()

	if tooling.flag_has(f, "-List") {
		code := tooling.run({command = {worker, "-List"}})
		fmt.println("js\tthe JavaScript engine: from ext/gui_toolkit, tools/js_judge fuzz | fuzzsrc <dir> [iterations] [seed] (src/md/features/fuzzing.md)")
		return code
	}
	target := tooling.flag(f, "-Target", "all")
	hang := max(tooling.flag_int(f, "-HangSeconds", DEFAULT_HANG_SECONDS), 1)
	if file := tooling.flag(f, "-Repro"); file != "" { return repro(worker, target, file, hang) }
	if file := tooling.flag(f, "-Minimize"); file != "" { return minimize(worker, target, file, hang) }

	names := target_names(worker, target)
	if len(names) == 0 { fmt.eprintfln("wrentool fuzz: no target %s (-List names them)", target); return EXIT_USAGE }
	seconds := max(tooling.flag_int(f, "-Seconds", DEFAULT_SECONDS), 1)
	failed := make([dynamic]string, context.temp_allocator)
	for name in names {
		command := []string{worker, "-Target", name, "-Seed", tooling.flag(f, "-Seed", "1"), "-Seconds", fmt.tprint(seconds), "-HangSeconds", fmt.tprint(hang),
			"-Iterations", tooling.flag(f, "-Iterations", "0")}
		outcome := run_worker(command, time.Duration(seconds + hang) * time.Second + GRACE)
		if outcome == .Pass { continue }
		append(&failed, name)
		report(name, outcome)
	}
	if len(failed) > 0 {
		fmt.printfln("wrentool fuzz: %d target(s) of %d failed: %s", len(failed), len(names), strings.join(failed[:], ", ", context.temp_allocator))
		return 1
	}
	fmt.printfln("wrentool fuzz: %d target(s), no failure", len(names))
	return 0
}

// Built unless newer than its sources (tooling.build_if_stale): the tracker with the poison, or the tracker with ASan.
build_worker :: proc(asan, speed: bool) -> (worker: string, ok: bool) {
	worker = strings.concatenate({asan ? WORKER_ASAN : WORKER, tooling.EXE_SUFFIX})
	command := make([dynamic]string, context.temp_allocator)
	append(&command, tooling.odin_program(), "build", "src/tools/fuzz", "-collection:wb=src", "-collection:toolkit=ext/gui_toolkit/src",
		fmt.tprintf("-out:%s", worker), "-use-separate-modules", "-vet", "-debug", "-define:WREN_TRACK_MEMORY=true")
	// (both take over free: one or the other)
	append(&command, asan ? "-sanitize:address" : "-define:WREN_POISON_MEMORY=true")
	if speed { append(&command, "-o:speed") }
	append(&command, ..tooling.STACK_FLAGS)
	flags := strings.join(command[2:], " ", context.temp_allocator)
	if !tooling.build_if_stale(worker, flags, command[:]) { fmt.eprintln("wrentool fuzz: the worker did not build"); return "", false }
	return worker, true
}

// `all`: every target the worker has, in its order. Else the list given.
target_names :: proc(worker, target: string) -> []string {
	if target != "all" { return strings.split(target, ",") }
	text, code := tooling.capture({worker, "-List"})
	if code != 0 { fmt.eprint(text); return nil }
	names := make([dynamic]string)
	for line in strings.split(text, "\n") {
		if tab := strings.index_byte(line, '\t'); tab > 0 { append(&names, line[:tab]) }
	}
	return names[:]
}

run_worker :: proc(command: []string, limit: time.Duration) -> Outcome {
	p, why := tooling.spawn({command = command})
	if why != "" { fmt.eprintfln("wrentool fuzz: the worker cannot start: %s", why); return .Setup }
	code, timed_out := tooling.wait(&p, limit)
	tooling.release(&p)
	switch {
	case timed_out:             return .Hang
	case code == WORKER_PASS:   return .Pass
	case code == WORKER_SETUP:  return .Setup
	case code == WORKER_LEAK:   return .Leak
	case code == WORKER_HANG:   return .Hang
	}
	return .Crash
}

// One input through the worker, after its seeds.
replay :: proc(worker, target, path: string, hang: int) -> Outcome {
	return run_worker({worker, "-Target", target, "-Repro", path, "-HangSeconds", fmt.tprint(hang)}, time.Duration(hang) * time.Second + GRACE)
}

// The input the worker was running when it ended, kept under a name its bytes give, and the commands that use it.
report :: proc(name: string, outcome: Outcome) {
	if outcome == .Setup { fmt.printfln("fuzz %s: the worker could not run (its message is above)", name); return }
	kind := OUTCOME_NAME[outcome]
	current := fmt.tprintf("%s/%s/current", FUZZ_DIR, name)
	data, err := os.read_entire_file(current, context.temp_allocator)
	if err != nil { fmt.printfln("fuzz %s: %s, and %s cannot be read", name, kind, current); return }
	kept := fmt.tprintf("%s/%s/%s-%016x", FUZZ_DIR, name, kind, hash.fnv64a(data))
	if os.write_entire_file(kept, data) != nil { fmt.printfln("fuzz %s: %s, and %s cannot be written", name, kind, kept); return }
	fmt.printfln("fuzz %s: %s on an input of %d bytes, kept in %s", name, kind, len(data), kept)
	fmt.printfln("  replay: wrentool fuzz -Target %s -Repro %s", name, kept)
	fmt.printfln("  shrink: wrentool fuzz -Target %s -Minimize %s", name, kept)
}

repro :: proc(worker, target, file: string, hang: int) -> int {
	if target == "all" || strings.contains(target, ",") { fmt.eprintln("wrentool fuzz: -Repro takes one -Target"); return EXIT_USAGE }
	outcome := replay(worker, target, file, hang)
	switch outcome {
	case .Pass:  fmt.printfln("fuzz %s: %s passes", target, file); return 0
	case .Setup: return EXIT_USAGE
	case .Leak, .Hang, .Crash: fmt.printfln("fuzz %s: %s: %s", target, file, OUTCOME_NAME[outcome])
	}
	return 1
}

// Delta debugging, the simple form: chunks of half the input, then a quarter, down to one byte, each removed when the
// worker still ends the same way without it. Writes <file>.min.
minimize :: proc(worker, target, file: string, hang: int) -> int {
	if target == "all" || strings.contains(target, ",") { fmt.eprintln("wrentool fuzz: -Minimize takes one -Target"); return EXIT_USAGE }
	original, err := os.read_entire_file(file, context.allocator)
	if err != nil { fmt.eprintfln("wrentool fuzz: cannot read %s", file); return EXIT_USAGE }
	want := replay(worker, target, file, hang)
	if want == .Setup { return EXIT_USAGE }
	if want == .Pass { fmt.printfln("fuzz %s: %s passes: nothing to shrink", target, file); return 0 }

	try_file := fmt.tprintf("%s/%s/minimize", FUZZ_DIR, target)
	data := original
	runs := 0
	chunk := max(len(data) / 2, 1)
	for len(data) > 0 && runs < MINIMIZE_RUNS {
		removed := false
		for at := 0; at < len(data) && runs < MINIMIZE_RUNS; {
			candidate := make([dynamic]u8, 0, len(data))
			append(&candidate, ..data[:at])
			append(&candidate, ..data[min(at + chunk, len(data)):])
			if os.write_entire_file(try_file, candidate[:]) != nil { fmt.eprintfln("wrentool fuzz: cannot write %s", try_file); return 1 }
			runs += 1
			if replay(worker, target, try_file, hang) == want {
				data = candidate[:]
				removed = true
			} else {
				delete(candidate)
				at += chunk
			}
		}
		// (a pass that removed something is tried again at the same size: a removal can make another possible)
		if !removed {
			if chunk == 1 { break }
			chunk = max(chunk / 2, 1)
		}
	}
	out := fmt.tprintf("%s.min", file)
	if os.write_entire_file(out, data) != nil { fmt.eprintfln("wrentool fuzz: cannot write %s", out); return 1 }
	fmt.printfln("fuzz %s: %d of %d bytes still end in %s (%d runs), in %s", target, len(data), len(original), OUTCOME_NAME[want], runs, out)
	return 0
}
