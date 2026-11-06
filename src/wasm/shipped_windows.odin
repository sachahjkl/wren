package wasm

import win32 "core:sys/windows"

// `code` was copied: its pages of the program's file leave the process's working set, 21 MB. (On pages that were not locked VirtualUnlock says it failed, and takes them out.)
@(private)
shipped_pages_drop :: proc(code: []byte) { _ = win32.VirtualUnlock(raw_data(code), len(code)) }
