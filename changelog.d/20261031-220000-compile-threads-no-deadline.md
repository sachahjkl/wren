type: Fixed

Large scripts compile on their background threads whatever `wasm.max_call_ms` says: past that limit (1 s) the thread's engine died and the interface thread compiled that bundle and all later ones itself, inside the time `javascript.slow_script_ms` allows a task (vscode.dev stayed blank).
