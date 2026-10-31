#+build !linux
package host

// The main thread's stack is set when the executable is linked (build.bat: /STACK).
main_stack_ensure :: proc() {}
