package fuzz

import "wb:wasm"

// The guests the build made (the test pages' modules), when there are.
WASM_FILES := []Seed_Files{{dir = "examples/site", suffixes = {".wasm"}}}

// The header alone; a memory exported; a table with a maximum; an export section that names nothing Wren needs.
WASM_SEEDS := []string{
	"\x00asm\x01\x00\x00\x00",
	"\x00asm\x01\x00\x00\x00\x05\x03\x01\x00\x01\x07\x0a\x01\x06memory\x02\x00",
	"\x00asm\x01\x00\x00\x00\x04\x05\x01\x70\x01\x01\x0a\x05\x04\x01\x01\x01\x02",
	"\x00asm\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00\x03\x02\x01\x00\x07\x05\x01\x01f\x00\x00\x0a\x04\x01\x02\x00\x0b",
	"\x00asm\x01\x00\x00\x00\x02\x0c\x01\x03env\x03mem\x02\x00\x01\x00\x05\x04name",
}

WASM_TOKENS := []string{
	"\x00asm", "\x01\x00\x00\x00", "\x00", "\x01", "\x02", "\x03", "\x04", "\x05", "\x06", "\x07", "\x08", "\x09", "\x0a", "\x0b", "\x0c", "\x0d",
	"\x70", "\x6f", "\x7f", "\x7e", "\x60", "\x80\x80\x80\x80\x10", "\xff\xff\xff\xff\x0f", "\x80\x80\x80\x80\x80\x80\x80\x80\x80\x01", "memory", "__indirect_function_table", "env",
}

target_wasm :: proc(data: []u8) {
	info, err := wasm.analyze_image(data)
	if err == "" { _, _ = wasm.patch_image(data, info, context.temp_allocator) }
	_, _ = wasm.unbound_tables(data, context.temp_allocator)
}
