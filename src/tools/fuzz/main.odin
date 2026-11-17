// fuzz: the worker of `wrentool fuzz` (src/md/features/fuzzing.md). It runs one target on mutated inputs and checks
// memory after each. wrentool builds it, runs one per target and turns its abnormal ends into files that replay.
//   build/fuzz_worker -Target <name> [-Seed n] [-Iterations n] [-Seconds n] [-HangSeconds n]
//   build/fuzz_worker -Target <name> -Repro <file>
//   build/fuzz_worker -List
// Built with -define:WREN_TRACK_MEMORY=true and -define:WREN_POISON_MEMORY=true (or -sanitize:address): without the
// tracker it cannot see a leak.
package fuzz

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"
import "wb:base"
import "wb:tools/tooling"

// The exit codes wrentool reads (fuzztool.odin keeps the same numbers): any other code, or a signal, is a crash.
EXIT_PASS :: 0
EXIT_SETUP :: 2
EXIT_LEAK :: 3
EXIT_HANG :: 4

DEFAULT_SEED :: 1
DEFAULT_SECONDS :: 60
DEFAULT_HANG_SECONDS :: 10
// How often the progress line is printed: a run of minutes says that it lives, a run of seconds says it once.
PROGRESS_EVERY :: 10 * time.Second
FUZZ_DIR :: "build/fuzz"

// The start of the iteration in progress (nanoseconds of the tick clock), 0 between iterations: what the watchdog reads.
@(private) iteration_began: i64
@(private) hang_limit: time.Duration
@(private) current_target: string

main :: proc() {
	context.allocator = base.process_allocator()
	f, ok := tooling.parse_flags(os.args[1:], "-Target= -Seed= -Iterations= -Seconds= -HangSeconds= -Repro= -List")
	if !ok { usage() }
	root := tooling.repo_root()
	if os.set_working_directory(root) != nil { fmt.eprintfln("fuzz: cannot work in %s", root); os.exit(EXIT_SETUP) }
	if tooling.flag_has(f, "-List") {
		for t in TARGETS { fmt.printfln("%s\t%s", t.name, t.about) }
		os.exit(EXIT_PASS)
	}
	name := tooling.flag(f, "-Target")
	target := find_target(name)
	if target == nil { fmt.eprintfln("fuzz: no target %q (-List names them)", name); os.exit(EXIT_SETUP) }
	current_target = target.name
	hang_limit = time.Duration(max(tooling.flag_int(f, "-HangSeconds", DEFAULT_HANG_SECONDS), 1)) * time.Second

	corpus := load_corpus(target)
	if len(corpus) == 0 { fmt.eprintfln("fuzz %s: an empty corpus", target.name); os.exit(EXIT_SETUP) }

	// The temporary allocator of a target is this arena, emptied after each input: what a target keeps from it across
	// two inputs is freed memory, which the poison makes loud.
	arena: base.Arena
	if base.arena_init_growing(&arena) != .None { fmt.eprintln("fuzz: no arena"); os.exit(EXIT_SETUP) }
	context.temp_allocator = base.arena_allocator(&arena)

	dir := fmt.aprintf("%s/%s", FUZZ_DIR, target.name)
	_ = os.make_directory_all(dir)
	current_path := fmt.aprintf("%s/current", dir)
	current, err := os.open(current_path, {.Write, .Create, .Trunc})
	if err != nil { fmt.eprintfln("fuzz: cannot write %s", current_path); os.exit(EXIT_SETUP) }

	_ = thread.create_and_start(watchdog, base.process_context())

	// Each seed once, as it is: a seed that fails is a finding like any other. What the target builds on its first call
	// (tables, interned names) is then forgotten, so that only what an input leaves counts.
	for seed in corpus { run_one(target, seed, &arena, current) }
	base.mem_forget_live()
	for seed in corpus { run_one(target, seed, &arena, current) }

	if repro := tooling.flag(f, "-Repro"); repro != "" {
		data, rerr := os.read_entire_file(repro, context.allocator)
		if rerr != nil { fmt.eprintfln("fuzz: cannot read %s", repro); os.exit(EXIT_SETUP) }
		run_one(target, data, &arena, current)
		fmt.printfln("fuzz %s: %s passes", target.name, repro)
		os.exit(EXIT_PASS)
	}

	seed := u64(tooling.flag_int(f, "-Seed", DEFAULT_SEED))
	iterations := tooling.flag_int(f, "-Iterations", 0)   // 0: as many as the seconds allow
	seconds := tooling.flag_int(f, "-Seconds", DEFAULT_SECONDS)
	budget := time.Duration(seconds) * time.Second
	began := time.tick_now()
	last_said := began
	done := 0
	for iterations == 0 || done < iterations {
		if time.tick_since(began) > budget { break }
		input := mutated(target, corpus, seed, done)
		run_one(target, input, &arena, current)
		done += 1
		if time.tick_since(last_said) > PROGRESS_EVERY {
			last_said = time.tick_now()
			fmt.printfln("fuzz %s: %d inputs, %.0f/s", target.name, done, f64(done) / time.duration_seconds(time.tick_since(began)))
		}
	}
	elapsed := time.duration_seconds(time.tick_since(began))
	short := iterations > 0 && done < iterations
	fmt.printfln("fuzz %s: %d inputs (seed %d, %d seeds), %.1f s, no failure%s", target.name, done, seed, len(corpus), elapsed,
		short ? fmt.tprintf("; stopped at %d s before %d inputs", seconds, iterations) : "")
	os.exit(EXIT_PASS)
}

usage :: proc() -> ! {
	fmt.eprintln("usage: fuzz_worker -Target <name> [-Seed n] [-Iterations n] [-Seconds n] [-HangSeconds n] | -Target <name> -Repro <file> | -List")
	os.exit(EXIT_SETUP)
}

find_target :: proc(name: string) -> ^Target {
	for &t in TARGETS { if t.name == name { return &t } }
	return nil
}

// One input through the target. The input is on disk before the target sees it: a crash leaves it behind.
run_one :: proc(t: ^Target, data: []u8, arena: ^base.Arena, current: ^os.File) {
	_, _ = os.write_at(current, data, 0)
	_ = os.truncate(current, i64(len(data)))
	before := base.mem_stats()
	sync.atomic_store(&iteration_began, time.tick_now()._nsec)
	t.run(data)
	sync.atomic_store(&iteration_began, 0)
	base.arena_free_all(arena)
	after := base.mem_stats()
	if after.live_blocks > before.live_blocks || after.bad_frees > before.bad_frees {
		// (the report lists every block still live: the warm-up forgot the others, so these are the input's)
		base.mem_report(fmt.tprintf("fuzz %s", t.name))
		fmt.printfln("fuzz %s: the input left %d block(s) allocated, %d bad free(s)", t.name, after.live_blocks - before.live_blocks, after.bad_frees - before.bad_frees)
		os.exit(EXIT_LEAK)
	}
}

// Ends the process when one input runs longer than the hang limit: the input is in `current`.
watchdog :: proc() {
	for {
		time.sleep(100 * time.Millisecond)
		began := sync.atomic_load(&iteration_began)
		if began == 0 { continue }
		if time.tick_since(time.Tick{began}) > hang_limit {
			fmt.eprintfln("fuzz %s: one input ran longer than %v", current_target, hang_limit)
			os.exit(EXIT_HANG)
		}
	}
}
