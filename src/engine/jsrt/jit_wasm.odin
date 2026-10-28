package jsrt

// A tiny WebAssembly binary writer for the loop JIT (jit.odin): LEB128, the opcodes the JIT uses, sections.

W_I32 :: 0x7F
W_I64 :: 0x7E
W_F64 :: 0x7C
W_VOID :: 0x40

// opcodes (the binary format's names)
W_UNREACHABLE :: 0x00
W_BLOCK :: 0x02
W_LOOP :: 0x03
W_IF :: 0x04
W_ELSE :: 0x05
W_END :: 0x0B
W_BR :: 0x0C
W_BR_IF :: 0x0D
W_RETURN :: 0x0F
W_LOCAL_GET :: 0x20
W_LOCAL_SET :: 0x21
W_LOCAL_TEE :: 0x22
W_I32_LOAD :: 0x28
W_F64_LOAD :: 0x2B
W_I32_LOAD8_U :: 0x2D
W_I32_STORE :: 0x36
W_F64_STORE :: 0x39
W_I32_STORE8 :: 0x3A
W_I32_CONST :: 0x41
W_I64_CONST :: 0x42
W_F64_CONST :: 0x44
W_I32_EQZ :: 0x45
W_I32_EQ :: 0x46
W_I32_NE :: 0x47
W_I32_LT_S :: 0x48
W_I32_GT_S :: 0x4A
W_I32_LE_S :: 0x4C
W_I32_GE_S :: 0x4E
W_I64_EQZ :: 0x50
W_I64_EQ :: 0x51
W_I64_NE :: 0x52
W_I64_LT_S :: 0x53
W_I64_GT_S :: 0x55
W_I64_GT_U :: 0x56
W_I64_LE_S :: 0x57
W_I64_GE_S :: 0x59
W_F64_CONVERT_I64_S :: 0xB9
W_F64_EQ :: 0x61
W_F64_NE :: 0x62
W_F64_LT :: 0x63
W_F64_GT :: 0x64
W_F64_LE :: 0x65
W_F64_GE :: 0x66
W_I32_ADD :: 0x6A
W_I32_SUB :: 0x6B
W_I32_MUL :: 0x6C
W_I32_REM_S :: 0x6F
W_I32_AND :: 0x71
W_I32_OR :: 0x72
W_I32_XOR :: 0x73
W_I32_SHL :: 0x74
W_I32_SHR_S :: 0x75
W_I32_SHR_U :: 0x76
W_I64_ADD :: 0x7C
W_I64_SUB :: 0x7D
W_I64_MUL :: 0x7E
W_I64_OR :: 0x84
W_I64_SHL :: 0x86
W_F64_NEG :: 0x9A
W_F64_ADD :: 0xA0
W_F64_SUB :: 0xA1
W_F64_MUL :: 0xA2
W_F64_DIV :: 0xA3
W_I32_WRAP_I64 :: 0xA7
W_I64_EXTEND_I32_S :: 0xAC
W_I64_EXTEND_I32_U :: 0xAD
W_F64_CONVERT_I32_S :: 0xB7

Wbuf :: [dynamic]u8

w_u8 :: proc(b: ^Wbuf, x: u8) {append(b, x)}

w_uleb :: proc(b: ^Wbuf, v: u64) {
	x := v
	for {
		bt := u8(x & 0x7f)
		x >>= 7
		if x == 0 {
			append(b, bt)
			return
		}
		append(b, bt | 0x80)
	}
}

w_sleb :: proc(b: ^Wbuf, v: i64) {
	x := v
	for {
		bt := u8(x & 0x7f)
		x >>= 7
		if (x == 0 && bt & 0x40 == 0) || (x == -1 && bt & 0x40 != 0) {
			append(b, bt)
			return
		}
		append(b, bt | 0x80)
	}
}

w_name :: proc(b: ^Wbuf, s: string) {
	w_uleb(b, u64(len(s)))
	for i in 0 ..< len(s) {append(b, s[i])}
}

w_section :: proc(m: ^Wbuf, id: u8, body: ^Wbuf) {
	append(m, id)
	w_uleb(m, u64(len(body)))
	for x in body {append(m, x)}
	clear(body)
}
