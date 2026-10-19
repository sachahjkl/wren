// Where the demo pages are: examples/site from the repository (run from its root, as the tests do), or demos\ next
// to the executable (the release package: wren.exe, testserver.exe and demos\ side by side), or what -site DIR says.
package main

import (
	"os"
	"path/filepath"
)

var siteDir = findSiteDir()

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func findSiteDir() string {
	for i, a := range os.Args {
		if a == "-site" && i+1 < len(os.Args) {
			return os.Args[i+1]
		}
	}
	if isDir("examples/site") {
		return "examples/site"
	}
	if exe, err := os.Executable(); err == nil {
		if d := filepath.Join(filepath.Dir(exe), "demos"); isDir(d) {
			return d
		}
	}
	if isDir("demos") {
		return "demos"
	}
	return "examples/site"
}

// A file of the site: sitePath("images", "red.png").
func sitePath(parts ...string) string {
	return filepath.Join(append([]string{siteDir}, parts...)...)
}
