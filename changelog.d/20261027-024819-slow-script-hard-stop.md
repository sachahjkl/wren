type: Fixed

**A slow script that is slow to see its stop flag is no longer killed for good** (src/page/js_realm.odin): the hard stop after javascript.slow_script_ms comes after four slices instead of two, because the engine looks at the flag every few thousand calls, which on a slow or loaded machine can take as long as the slice (an endless microtask chain left the page's scripts stopped for good on the CI).
