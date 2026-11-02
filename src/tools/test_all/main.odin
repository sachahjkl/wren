// test_all: every test of the project, step by step (docs/testing.md). On Windows it all happens on a desktop of its own (desktop_windows.odin).
//   odin run src/tools/test_all -collection:wb=src -keep-executable -out:build/test_all.exe -- -Quick
//   build/test_all -Quick [-CI] [-Ui] [-Perf] [-NoCache] [-Cache] [-NoAsan] [-Jobs n] [-LightJobs n] [-StepTimeoutSec n]
//                  [-Only regex] [-Except regex] [-Failed] [-Changed] [-Base commit] [-List] [-Profile] [-Odin path]
//   build/test_all -ProfileReport base | -ProfileCompare a b    the tables of runs that were profiled (build/prof)
//   build/test_all -Globals | -GlobalsWrite                     the globals of the browser's packages with their class; the list rewritten from the code
//   build/test_all -AsanBrowser [-AsanConsole] | -AsanProgram dir | -AsanPackages a,b [-AsanNames names]    ASan builds by hand (asan.odin)
// The step table is steps.odin, what a run does with it scheduler.odin, the result cache cache.odin, the end of a run report.odin.
package test_all

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:tools/tooling"

// Steps at a time: three per four processors on a machine of ours, at most this; two on the CI. Measured on the CI runner (4 vCPU) with the same steps: two at a time 514 s; three
// 539 s and three checks failed under the load; four 765 s (the steps compile and test, they do not wait). On 16 threads most steps wait: 12 at a time pays.
JOBS_PER_PROCESSOR :: 0.75
JOBS_MOST :: 12
JOBS_CI :: 2
LIGHT_JOBS :: 4
LIGHT_JOBS_CI :: 2
STEP_TIMEOUT_SECONDS :: 900
// On a shared CI runner the limits of what waits are this many times longer.
CI_SLOW_FACTOR :: 3
EXIT_USAGE :: 2

REPORT_FILE :: "build/test_report.txt"
STEPS_FILE :: "build/test_steps.tsv"
FAILED_FILE :: "build/test_failed.txt"
TIMES_FILE :: "build/test_all_times.txt"
LOG_DIR :: "build/test_logs"
TEMP_DIR :: "build/tmp"

Config :: struct {
	quick, ci, ui, perf, no_asan, no_cache, cache, failed, changed, list, profile: bool,
	jobs, light_jobs, step_timeout: int,
	only, except, base: string,
	slow:      int,    // what the limits of what waits are multiplied by
	use_cache: bool,   // results are read and kept in this run
	on_ci:     bool,   // -CI, or the CI variable
	again:     string, // the flags that make a run like this one, for the `again` line
	asan:      Asan_By_Hand,
}

usage :: proc() -> ! {
	fmt.eprintln("usage: test_all [-Quick] [-CI] [-Ui] [-Perf] [-NoCache] [-Cache] [-NoAsan] [-Jobs n] [-LightJobs n] [-StepTimeoutSec n] [-Only regex] [-Except regex] [-Failed] [-Changed] [-Base commit] [-List] [-Profile] [-Odin path] | -ProfileReport base | -ProfileCompare a b | -Globals | -GlobalsWrite | -AsanBrowser [-AsanConsole] | -AsanProgram dir | -AsanPackages a,b [-AsanNames names]")
	os.exit(EXIT_USAGE)
}

env_true :: proc(name: string) -> bool {
	v, _ := os.lookup_env(name, context.temp_allocator)
	return v == "1" || v == "true"
}

env_set :: proc(name: string) -> bool {
	v, _ := os.lookup_env(name, context.temp_allocator)
	return v != ""
}

main :: proc() {
	cfg := Config{step_timeout = STEP_TIMEOUT_SECONDS}
	args := os.args[1:]
	report_of, compare_a, compare_b: string
	globals_list, globals_write: bool
	for i := 0; i < len(args); i += 1 {
		need :: proc(args: []string, i: ^int) -> string { i^ += 1; if i^ >= len(args) { usage() }; return args[i^] }
		number :: proc(s: string) -> int { v, ok := strconv.parse_int(s); if !ok { usage() }; return v }
		// (as PowerShell read them: the case does not matter)
		switch strings.to_lower(args[i], context.temp_allocator) {
		case "-quick": cfg.quick = true
		case "-ci": cfg.ci = true
		case "-ui": cfg.ui = true
		case "-perf": cfg.perf = true
		case "-noasan": cfg.no_asan = true
		case "-nocache": cfg.no_cache = true
		case "-cache": cfg.cache = true
		case "-failed", "-rerunfailed": cfg.failed = true
		case "-changed": cfg.changed = true
		case "-list": cfg.list = true
		case "-profile": cfg.profile = true
		case "-jobs": cfg.jobs = number(need(args, &i))
		case "-lightjobs": cfg.light_jobs = number(need(args, &i))
		case "-steptimeoutsec": cfg.step_timeout = number(need(args, &i))
		case "-only": cfg.only = need(args, &i)
		case "-except": cfg.except = need(args, &i)
		case "-base": cfg.base = need(args, &i)
		case "-odin": tooling.odin_override = need(args, &i)
		case "-profilereport": report_of = need(args, &i)
		case "-profilecompare": compare_a = need(args, &i); compare_b = need(args, &i)
		case "-globals": globals_list = true
		case "-globalswrite": globals_write = true
		case "-asanbrowser": cfg.asan.browser = true
		case "-asanconsole": cfg.asan.console = true
		case "-asanprogram": cfg.asan.program = need(args, &i)
		case "-asanpackages": cfg.asan.packages = need(args, &i)
		case "-asannames": cfg.asan.names = need(args, &i)
		case: fmt.eprintfln("unknown flag %s", args[i]); usage()
		}
	}

	root := tooling.repo_root()
	if os.set_working_directory(root) != nil { fmt.eprintfln("test_all: cannot work in %s", root); os.exit(EXIT_USAGE) }
	_ = os.make_directory_all(TEMP_DIR)
	_ = os.make_directory_all(LOG_DIR)

	if report_of != "" { profile_report(report_of); return }
	if compare_a != "" { profile_compare(compare_a, compare_b); return }
	if globals_list || globals_write { os.exit(lint_globals(list = globals_list, write = globals_write) ? 0 : 1) }

	// On a desktop of its own: no step takes the focus, the mouse or the keyboard of the person at the machine, and their clicks reach no step. -Ui stays where it is, its steps need the
	// real input; a CI runner has nobody to disturb.
	on_ci_variable := env_set("CI")
	if !cfg.ui && !on_ci_variable && !cfg.list {
		code := 0
		if on_own_desktop(&code) { os.exit(code) }
	}

	configure(&cfg)
	if asan_by_hand(&cfg) { return }

	table := build_table(&cfg)
	os.exit(run_all(&cfg, table))
}

// What the flags and the environment add up to: the variables the steps inherit are set here.
configure :: proc(cfg: ^Config) {
	cache_off, _ := os.lookup_env("WREN_TEST_CACHE", context.temp_allocator)
	if cfg.no_cache || cache_off == "0" {
		cfg.no_cache = true
		os.set_env("WREN_NO_TEST_CACHE", "1")
	}
	if cfg.ci {
		cfg.quick = true
		if !env_set("CI") { os.set_env("CI", "true") }   // (the tools that skip a check on the CI read the variable)
	}
	cfg.on_ci = cfg.ci || env_set("CI")
	// -Ui (or WREN_UI_TESTS=1): the steps marked .Ui_Only (real windows and processes, heavy images under a limit: a desktop and a machine of known speed). Never on a CI machine.
	cfg.ui = cfg.ui || env_true("WREN_UI_TESTS")
	if cfg.ui && cfg.on_ci { fmt.println("ui: -Ui / WREN_UI_TESTS ignored on the CI (the UI steps never run there)"); cfg.ui = false }
	// -Perf (or WREN_PERF=1): the tests that measure time run and print their measures, one step at a time. Never on a CI machine: its specs are unknown.
	cfg.perf = cfg.perf || env_true("WREN_PERF")
	if cfg.perf && cfg.on_ci { fmt.println("perf: -Perf / WREN_PERF ignored on the CI (the performance tests never run there)"); cfg.perf = false }
	if cfg.perf {
		os.set_env("WREN_PERF", "1")
		if cfg.jobs <= 0 { cfg.jobs = 1 }
	} else {
		os.unset_env("WREN_PERF")
	}
	cfg.slow = cfg.ci ? CI_SLOW_FACTOR : 1
	if cfg.jobs <= 0 { cfg.jobs = cfg.ci ? JOBS_CI : clamp(int(JOBS_PER_PROCESSOR * f64(os.get_processor_core_count())), 1, JOBS_MOST) }
	if cfg.light_jobs <= 0 { cfg.light_jobs = cfg.ci ? LIGHT_JOBS_CI : LIGHT_JOBS }
	cfg.use_cache = !cfg.no_cache && !cfg.perf && (cfg.cache || (cfg.quick && !cfg.ci))
	cfg.again = cfg.quick ? "-Quick " : ""
	set_test_environment(cfg)
}

here :: proc(path: string) -> string {
	full, _ := filepath.abs(path, context.allocator)
	return full
}

now_stamp :: proc(allocator := context.temp_allocator) -> string {
	buf: [time.MIN_YYYY_DATE_LEN]u8
	clock: [time.MIN_HMS_LEN]u8
	t := time.now()
	return fmt.aprintf("%s %s", time.to_string_yyyy_mm_dd(t, buf[:]), time.to_string_hms(t, clock[:]), allocator = allocator)
}
