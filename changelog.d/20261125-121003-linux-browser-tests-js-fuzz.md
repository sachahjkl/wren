type: Changed

**Linux browser unit tests and JavaScript engine fuzzing**: `test_all` on Linux now runs every portable `src/browser` unit test automatically instead of a fixed allowlist (moving the D3D11-only GPU canvas suite to `canvas_gpu_test_windows.odin`), and `wrentool fuzz` and `test_all -Fuzz` now fuzz the JavaScript engine's front end, interpreter, and serialized bytecode reader (`js_src` and `js_bytecode`).
