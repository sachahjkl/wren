//go:build !windows

package main

// -parent-pid is honored on Windows only (parent_windows.go).
func watchParent() {}
