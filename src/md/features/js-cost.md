# The cost gate: instructions instead of time

`jsengine cost` counts the Wasm instructions that JavaScript costs in the engine, interpreted, with Wasmtime's fuel
(`--pref wasm.wasmtime.fuel=true`, `wasm.Instance.fuel_used`). test_all runs it in the step "test262 with the JIT", so the
CI fails when a path gets longer. It has two inputs:

- `examples/jsbench/cost.js`: micro-cases (a property read, a call, a literal), each with its limit.
- `examples/jsbench/octane_cost.txt`: whole Octane benchmarks (`-octane <dir>`), each with its run count and its limit.
  The micro-cases show one path. Octane shows what real programs do together: property access, regexp, calls, the
  collector.

## Why instructions

A time measure moves with the machine, its load and its frequency. A CI runner is shared, so a gate on time either
fails at random or has a margin so wide that it catches nothing. The count of instructions of one interpreted run is a
property of the image and the script only. It does not move between machines or between runs, so a 10 % margin is
enough. The interpreter is measured, not the JIT: the JIT's thresholds and its background threads make the count
depend on timing.

## How one run is counted

The idea comes from the Ekuma engine (`_bench/TUNING.md`): one run costs (count of N runs − count of M runs) / (N − M),
so the setup goes out. Here the tool calls the benchmark itself, so it can apply the same idea in one realm:

1. A fresh worker realm per benchmark: the prelude, `base.js`, the benchmark's files.
2. Each `Benchmark` of the realm's suites gets its `Setup`. The tool never calls `BenchmarkSuite.RunSuites`, which
   runs by time.
3. One warm-up run (`OCTANE_COST_WARM_UP`): the first run makes what later runs find (shapes, atoms, functions read).
4. A collection, then the call with 0 runs and the call with N runs. Cost = (N runs − 0 runs) / N. The difference takes
   out the call's own cost, as `cost.js` does.
5. `TearDown`. A benchmark that throws fails the gate, as one over its limit does.

## What makes the count exact

Two runs of the gate print the same numbers, to the instruction. Four sources of variance were found and removed:

- **The poll ticker.** A polled realm's word is raised by the clock, and each raise adds a poll's path. The cost mode
  runs on the engine with epoch checks (`polled = false`): Wasmtime checks the epoch outside the guest's count.
- **The realm's seed.** crypto.js fills its random pool from `Math.random` while it loads, before `base.js` reseeds it.
  The cost mode gives every realm the same seed (`OCTANE_COST_SEED`).
- **The clock.** pdfjs cuts its work into time slices with `Date.now()`. The cost mode replaces `Date` with a clock that
  advances by 1 ms at each read, from a fixed time (`OCTANE_COST_CLOCK`). `base.js` then reads the same clock, because
  the prelude deletes `performance`.
- **The heap.** A collection before the measured runs puts every run at the same heap state. Where a collection falls
  is then the same in every run.

## What is left out

A benchmark stays out of the gate when one interpreted run takes more than a few seconds. The gate takes about 12 s
on a desktop machine for 11 benchmarks. The four left out, with the instructions of one run:

| Benchmark  | One run | Why |
|------------|---------|-----|
| gbemu      | 12.9 G  | about 5 s a run; with the warm-up it doubles the gate |
| typescript | 36.8 G  | about 15 s a run |
| mandreel   | 75.8 G  | about 35 s a run |
| zlib       | 304 G   | more than 2 minutes a run |

The run counts in `octane_cost.txt` keep each benchmark near 1 to 3 s.

## The files

The Octane files are not in the repository. `src/tools/tooling/octane.odin` holds the pins (a commit, every file by its
SHA-256, the suite table) and `tooling.octane_fetch`. `wrentool bench js` and test_all's task `task_octane` both use it,
into `build/bench/octane`. A file that is there with its digest is not fetched again.

## When a limit fails

- **A slowdown.** Find the change that made the path longer, with `jsengine run -profile` on the benchmark. Fix it.
- **A change that is right and costs more** (a conformance fix, a check for safety). Run the command at the top of
  `octane_cost.txt` and set the limit about 10 % over the new count, in the same commit as the change. Its message
  says why the cost grew.
- **A change that makes a benchmark much cheaper.** Lower its limit to about 10 % over the new count, so that the gain
  is kept.
- **A new toolkit tag.** The image changes with it ([js-engine.md](js-engine.md)), so the counts can move a little.
  The limits have room for that.

## Refused

- **Time with a margin.** See "Why instructions".
- **The count of the whole process with N and M runs**, as Ekuma does. The tool calls `run` itself, so it can measure
  only the runs. Two processes per benchmark would double the gate's time.
- **The JIT's count.** It depends on when the background threads finish. The interpreter is the path that every
  script takes first.
