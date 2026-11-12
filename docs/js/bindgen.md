# bindgen: the generated copies of the web API

`src/tools/bindgen` generates every copy of the web API from one description: the `.widl` files of `api/` (a small
dialect of Web IDL, see `docs/api/README.md`). The `.widl` files are the only source. Do not edit a generated file:
change its `.widl` file, then run `bindgen` (the build runs it).

## Outputs

From `api/*.widl` (package `src/tools/bindgen/idl`):

| file | what |
|---|---|
| `src/page/api_generated.odin` | the host side: one trampoline per browser function |
| `sdk/odin/<package>/<module>.odin` | the guest SDK |
| `native/js/odin/wj/wr_imports.odin` | the browser's imports for the JavaScript engine: `wr_*` handle, enum, flags, struct and callback types, and one `foreign` block per module with the raw ABI |
| `docs/api/*.md` | the reference of the API |
| `examples/apiconformance/main.odin`, `src/tools/apiconformance/cases_generated.odin` | the conformance tests of the binding layer |
| `src/page/ext_api_generated.odin`, `src/page/ext_api_generated_test.odin`, `docs/api/ext/*.md` | the extension namespaces (`api/ext_<namespace>.widl`) |

From the Web IDL of the specifications (`native/js/webref`, package `src/tools/bindgen/webidl`) bound to the browser
API (package `src/tools/bindgen/jsgen`):

| file | what |
|---|---|
| `native/js/odin/bindings_gen.odin` | the JavaScript glue in Odin: the trampolines (`wjg_*`), the dictionaries (`wjd_*`), the member tables and the interface table |
| `src/page/js_interfaces_generated.odin` | the interface of each node's wrapper, chosen by the browser |
| `docs/js/coverage.md` | what is implemented, how, and what is not |

`src/tools/wasmbench/bench.widl` gives the bindings of the host-call benchmark.

## Commands

- `bindgen` writes the files that changed.
- `bindgen -check` writes nothing. It fails if a generated file is missing, out of date, or left over. `test_all`
  runs it.

Run both from the root of the repository.
