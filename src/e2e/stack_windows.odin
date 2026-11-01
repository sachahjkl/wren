package e2e

// Windows: the program is linked with the stack the script engine's calls need (/STACK), every thread takes it.
@(private)
ensure_stack :: proc() {}
