#+build !windows
package jsrt_judge

// No crash report off Windows: a crash ends the replay with the system's own message.
fuzz_crash_report_install :: proc() {}
