package wasm

import "core:mem"
import win "core:sys/windows"

foreign import crypt32_lib "system:Crypt32.lib"

@(private)
DATA_BLOB :: struct {
	cbData: u32,
	pbData: [^]u8,
}

@(default_calling_convention = "system")
foreign crypt32_lib {
	@(private) CryptProtectData :: proc(pDataIn: ^DATA_BLOB, szDataDescr: [^]u16, pOptionalEntropy: ^DATA_BLOB, pvReserved: rawptr, pPromptStruct: rawptr, dwFlags: u32, pDataOut: ^DATA_BLOB) -> b32 ---
	@(private) CryptUnprotectData :: proc(pDataIn: ^DATA_BLOB, ppszDataDescr: ^[^]u16, pOptionalEntropy: ^DATA_BLOB, pvReserved: rawptr, pPromptStruct: rawptr, dwFlags: u32, pDataOut: ^DATA_BLOB) -> b32 ---
}

@(private) CRYPTPROTECT_UI_FORBIDDEN :: 0x1

// DPAPI, current user: a blob only this Windows account can turn back into the key.
@(private)
protect :: proc(data: []byte, allocator := context.allocator) -> (out: []byte, ok: bool) {
	in_blob := DATA_BLOB{u32(len(data)), raw_data(data)}
	out_blob: DATA_BLOB
	if !CryptProtectData(&in_blob, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out_blob) { return }
	defer win.LocalFree(rawptr(out_blob.pbData))
	out = make([]byte, out_blob.cbData, allocator)
	copy(out, out_blob.pbData[:out_blob.cbData])
	return out, true
}

@(private)
unprotect :: proc(data: []byte, allocator := context.allocator) -> (out: []byte, ok: bool) {
	in_blob := DATA_BLOB{u32(len(data)), raw_data(data)}
	out_blob: DATA_BLOB
	if !CryptUnprotectData(&in_blob, nil, nil, nil, nil, CRYPTPROTECT_UI_FORBIDDEN, &out_blob) { return }
	defer win.LocalFree(rawptr(out_blob.pbData))
	out = make([]byte, out_blob.cbData, allocator)
	copy(out, out_blob.pbData[:out_blob.cbData])
	mem.zero_explicit(out_blob.pbData, int(out_blob.cbData))
	return out, true
}
