package web

// crypto.getRandomValues, crypto.randomUUID, crypto.subtle.digest (import module "crypto").

foreign import crypto_mod "crypto"

// Negative results of the web API imports (beyond Error) and codes of promise rejections.
Web_Error :: enum i32 {
	None          = 0,
	Type          = -10,
	Range         = -11,
	Security      = -12,
	Quota         = -13,
	Not_Supported = -14,
	Syntax        = -15,
	Abort         = -16,
	Timeout       = -17,
	Invalid_State = -18,
	Data_Clone    = -19,
	Network       = -20,
	Encoding      = -21,
}

@(default_calling_convention = "contextless")
foreign crypto_mod {
	@(link_name = "Crypto_getRandomValues") raw_getRandomValues :: proc(dst: [^]u8, n: i32) -> i32 ---
	@(link_name = "Crypto_randomUUID") raw_randomUUID :: proc(buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "SubtleCrypto_digest") raw_digest :: proc(alg: [^]u8, al: i32, data: [^]u8, n: i32) -> Handle ---
	@(link_name = "SubtleCrypto_digestBuffer") raw_digestBuffer :: proc(alg: [^]u8, al: i32, buffer: Handle) -> Handle ---
}

// Fills `dst`; Web_Error.Quota past the limit (65536 bytes by default).
get_random_values :: proc "contextless" (dst: []u8) -> Web_Error {
	n := raw_getRandomValues(raw_data(dst), i32(len(dst)))
	return n < 0 ? Web_Error(n) : .None
}

random_uuid :: proc "contextless" (buf: ^[36]u8) -> string {
	n := raw_randomUUID(raw_data(buf[:]), 36)
	return string(buf[:min(int(max(n, 0)), 36)])
}

// crypto.subtle.digest("SHA-256", data): a promise; Promise_value is a buffer handle with the digest.
digest :: proc "contextless" (algorithm: string, data: []u8) -> Handle {
	return raw_digest(raw_data(algorithm), i32(len(algorithm)), raw_data(data), i32(len(data)))
}

digest_buffer :: proc "contextless" (algorithm: string, buffer: Handle) -> Handle {
	return raw_digestBuffer(raw_data(algorithm), i32(len(algorithm)), buffer)
}
