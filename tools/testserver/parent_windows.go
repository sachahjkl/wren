package main

import (
	"log"
	"os"
	"syscall"
)

// -parent-pid N: the server ends with the process that started it (a test script stopped by force, a job killed),
// instead of keeping its ports and serving the files of a worktree to the next run.
func watchParent() {
	pid := argInt("-parent-pid", 0)
	if pid <= 0 {
		return
	}
	const synchronize = 0x00100000
	h, err := syscall.OpenProcess(synchronize, false, uint32(pid))
	if err != nil {
		log.Printf("testserver: parent process %d is gone", pid)
		os.Exit(0)
	}
	go func() {
		syscall.WaitForSingleObject(h, syscall.INFINITE)
		log.Printf("testserver: parent process %d ended", pid)
		os.Exit(0)
	}()
}
