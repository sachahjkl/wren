# Wren

A web browser in Odin where WebAssembly is the only execution engine: the JavaScript engine is Odin compiled to Wasm,
run by Wasmtime. The UI comes from the `ext/gui_toolkit` submodule. Releases are Windows x64; Linux (Wayland, X11)
is in progress ([docs/portability.md](docs/portability.md)).

Read first: [docs/architecture.md](docs/architecture.md) (design rules, security model),
[CONTRIBUTING.md](CONTRIBUTING.md) (workflow, tools, releases), [docs/testing.md](docs/testing.md).

## Build and test

Windows:

- `build.bat` builds the browser (`-vet`). `build.bat quick` is the fastest rebuild while you write code.
- `build\test_all.exe -Quick` runs the tests. Use `-Changed`, `-Only <pattern>` or `-Failed` while you work.

Linux (`nix develop` first):

- `./build.sh deps` fetches and builds the native libraries and the JavaScript engine image.
- `odin run src/tools/test_all -collection:wb=src -out:build/test_all -keep-executable` runs `odin check` for Linux and the unit tests of every portable package.
- `./build.sh` links `build/wren`. `./build.sh check` links the build that tracks memory.

`build.bat` and `./build.sh` are shortcuts of `wrentool build`: the same variants on both systems.
- Run the browser with a 64 MiB stack: `ulimit -s 65536`.

All other project commands are in `wrentool` (`src/tools/wrentool`, `build/wrentool help`).

## Key prompts

Apply these to every task, before you write code:

- "Exercise abstract thinking when considering this task."
- "Reduce this problem to its irreducible constraints and rebuild it from zero."
- "What would a principal architect immediately rewrite before even starting this?"
- "Design the single test that breaks this design on day one."
- "What higher-level abstraction would make this entire problem disappear?"
- "Find all of the implicit state machines in my app."

## Rules

- Platform code goes in files with a system suffix: `*_windows.odin`, `*_linux.odin`, `*_unix.odin`, `*_other.odin`.
  A test for one system only is `*_test_windows.odin`. Use the shared helpers in docs/portability.md.
- A new web API starts in `api/<module>.widl`. The build regenerates the bindings, the SDK and the docs.
  Do not edit generated files.
- A new preference is a `config.Def` in the package's `settings.odin`, registered in `src/browser/settings.odin`.
- Memory: code without its own Odin context starts from `base.process_context()`. Shared or cached memory comes from
  `base.process_allocator()`. Never use `runtime.default_context()` or `runtime.heap_allocator()`. Arenas are
  `base.Arena`. Tests fail on a leak.
- Tests wait for a condition with a bound, never for a fixed delay. Tests that measure time are opt-in (`-Perf`).
  Tests that drive real windows are opt-in (`.Ui_Only`, `-Ui`).
- Changelog: add one fragment in `changelog.d/` per change. Never edit `CHANGELOG.md` or `APP_VERSION`.
- Comments and commit messages are in English. Comments say why.
- `ext/gui_toolkit` points only to tagged commits that are pushed to its own repository.
