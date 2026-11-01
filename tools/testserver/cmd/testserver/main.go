// The test server as a program, for what is not Odin: the scripts (tools\test_env.ps1 Start-WrenTestServer), the demos and the
// release package. The Odin tests load the same server in their own process (src/testserver).
//
//	testserver                           # http on :8765, https (self-signed) on :8766, http on :8767, WPT on :8768
//	testserver -base-port N [-scan] [-port-file F] [-parent-pid P]   # another block of ports (../../ports.go), ending with process P
//	testserver -wpt-only -wpt-port N     # the WPT origin alone
//	testserver -gen-images DIR           # writes the image fixtures, and ends
package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"

	"wb_testserver"
)

func main() {
	var o testserver.Options
	genImages := flag.String("gen-images", "", "write the image fixtures in this folder and end")
	portFile := flag.String("port-file", "", "once everything listens, the base port is written to this file")
	parent := flag.Int("parent-pid", 0, "the server ends with this process")
	flag.IntVar(&o.BasePort, "base-port", envInt("WREN_TEST_BASE_PORT"), "the first block of ports tried")
	flag.BoolVar(&o.Scan, "scan", false, "a busy block is not an error: the next free one is taken")
	flag.BoolVar(&o.WPTOnly, "wpt-only", false, "the web-platform-tests origin alone")
	flag.IntVar(&o.WPTPort, "wpt-port", 0, "the first port of the web-platform-tests origin")
	flag.StringVar(&o.SiteDir, "site", "", "the folder of /site/")
	flag.Parse()
	if *genImages != "" {
		if err := testserver.GenerateImages(*genImages); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	watchParent(*parent)
	port, err := testserver.Start(o)
	if err != nil {
		fmt.Fprintln(os.Stderr, "testserver:", err)
		os.Exit(1)
	}
	writePortFile(*portFile, port)
	select {}
}

func envInt(name string) int {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil && n > 0 {
		return n
	}
	return 0
}

// Written then renamed: a reader never sees half of it.
func writePortFile(f string, port int) {
	if f == "" {
		return
	}
	tmp := f + ".tmp"
	if err := os.WriteFile(tmp, []byte(strconv.Itoa(port)), 0o644); err == nil {
		os.Rename(tmp, f)
	}
}
