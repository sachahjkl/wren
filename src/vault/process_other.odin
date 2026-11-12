#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
package vault

// Windows has no SIGPIPE: a write to a helper that died fails with an error.
@(private)
writer_thread_signals :: proc() {}
