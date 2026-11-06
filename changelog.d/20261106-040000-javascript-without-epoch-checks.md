type: Changed

**Scripts run 15 to 25 % faster outside the JIT: the JavaScript engine no longer pays Wasmtime's epoch check at every function and loop, it runs on a Wasmtime engine of its own and looks for itself at the head of its loops whether the browser wants the thread. Chrome frames under a busy script, the slow script limit and the hard stop stay as they were, inside a native too. Objects that get their fields one by one (`new`, `this.a = 1`) no longer search the prototypes for each new key.**
