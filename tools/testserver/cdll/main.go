// The test server as a shared library of Go's own runtime (-buildmode=c-shared: build\testserver.dll), which the Odin tests load
// and start in their own process (src/testserver): no process to start or to end, no file to read the port from. The server
// runs on the goroutines and threads of that runtime, beside the test's own, and goes with the process.
package main

// #include <stddef.h>
import "C"

import (
	"io"
	"log"
	"unsafe"

	"wb_testserver"
)

// Starts the server from this base port, the next free block if it is taken, and returns the base port of the block it listens
// on: everything is bound when this returns. 0: it could not, and `why` holds the reason. To be called once in a process.
//
//export WrenTestServerStart
func WrenTestServerStart(basePort C.int, why *C.char, whyBytes C.int) C.int {
	log.SetOutput(io.Discard) // (the handlers' logs would land in the output of the test)
	port, err := testserver.Start(testserver.Options{BasePort: int(basePort), Scan: true})
	if err != nil {
		text := unsafe.Slice((*byte)(unsafe.Pointer(why)), int(whyBytes))
		text[copy(text[:len(text)-1], err.Error())] = 0
		return 0
	}
	return C.int(port)
}

// What the handlers have counted goes: for a test, a new server.
//
//export WrenTestServerReset
func WrenTestServerReset() { testserver.Reset() }

// The test authority's certificate (PEM) into `out`: its length, or 0 when it does not fit.
//
//export WrenTestServerCA
func WrenTestServerCA(out *C.char, outBytes C.int) C.int {
	pem := testserver.TestAuthorityPEM()
	if len(pem) > int(outBytes) {
		return 0
	}
	copy(unsafe.Slice((*byte)(unsafe.Pointer(out)), int(outBytes)), pem)
	return C.int(len(pem))
}

func main() {}
