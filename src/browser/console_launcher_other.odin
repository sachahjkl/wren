#+build !windows
package browser

// No console launcher off Windows: a terminal runs the executable itself.
console_launcher :: proc() -> []byte { return nil }
