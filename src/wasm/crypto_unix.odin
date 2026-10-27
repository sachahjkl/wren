#+build linux, darwin, freebsd, openbsd, netbsd
package wasm

// No DPAPI: the key is stored as it is, in a file only its owner may read (module_cache.odin writes it 0600), the
// protection Chromium has on Linux without a keyring. The Secret Service (libsecret) or the kernel's keyring can wrap
// it later behind these two procedures; a key that cannot be read back only disables the cache, it is never fatal.
@(private)
protect :: proc(data: []byte, allocator := context.allocator) -> (out: []byte, ok: bool) {
	out = make([]byte, len(data), allocator)
	copy(out, data)
	return out, true
}

@(private)
unprotect :: proc(data: []byte, allocator := context.allocator) -> (out: []byte, ok: bool) {
	return protect(data, allocator)
}
