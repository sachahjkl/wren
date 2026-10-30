type: Added

**WebAssembly modules built with the old form of exceptions run** (`try`, `catch`, `rethrow`, `delegate`: older Emscripten and .NET builds, DuckDB): they are translated at compilation. `new WebAssembly.Memory({shared: true})` works for one agent, so Pyodide (Python) starts.
