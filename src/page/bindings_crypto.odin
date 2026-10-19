package page

// Web Crypto, the parts that make sense without JavaScript objects (import module "crypto"):
//   * crypto.getRandomValues: the system RNG (BCryptGenRandom), at most crypto.max_random_bytes per call;
//   * crypto.randomUUID: a version 4 UUID from the same source;
//   * crypto.subtle.digest: SHA-1 / SHA-256 / SHA-384 / SHA-512 through BCrypt, fulfilled with a buffer. Inputs of at
//     least crypto.digest_offload_bytes are copied and hashed on a worker of the blocking pool.

import "core:strings"
import win "core:sys/windows"
import "wb:host"

foreign import bcrypt_lib "system:Bcrypt.lib"

@(default_calling_convention = "system")
foreign bcrypt_lib {
	BCryptCreateHash :: proc(hAlgorithm: rawptr, phHash: ^rawptr, pbHashObject: [^]u8, cbHashObject: u32, pbSecret: [^]u8, cbSecret: u32, dwFlags: u32) -> i32 ---
	BCryptHashData :: proc(hHash: rawptr, pbInput: [^]u8, cbInput: u32, dwFlags: u32) -> i32 ---
	BCryptFinishHash :: proc(hHash: rawptr, pbOutput: [^]u8, cbOutput: u32, dwFlags: u32) -> i32 ---
	BCryptDestroyHash :: proc(hHash: rawptr) -> i32 ---
}

Digest_Algorithm :: enum u8 { Invalid, SHA1, SHA256, SHA384, SHA512 }

digest_algorithm :: proc(name: string) -> Digest_Algorithm {
	switch {
	case strings.equal_fold(name, "SHA-1"):   return .SHA1
	case strings.equal_fold(name, "SHA-256"): return .SHA256
	case strings.equal_fold(name, "SHA-384"): return .SHA384
	case strings.equal_fold(name, "SHA-512"): return .SHA512
	}
	return .Invalid
}

digest_size :: proc(a: Digest_Algorithm) -> int {
	switch a {
	case .Invalid: return 0
	case .SHA1:   return 20
	case .SHA256: return 32
	case .SHA384: return 48
	case .SHA512: return 64
	}
	return 0
}

// BCrypt's pseudo-handles of the hash providers (Windows 10+): no provider to open or close, usable from any thread.
@(private)
bcrypt_alg :: proc(a: Digest_Algorithm) -> rawptr {
	switch a {
	case .Invalid: return nil
	case .SHA1:   return rawptr(uintptr(0x31))
	case .SHA256: return rawptr(uintptr(0x41))
	case .SHA384: return rawptr(uintptr(0x51))
	case .SHA512: return rawptr(uintptr(0x61))
	}
	return nil
}

// One-shot digest; `out` must hold digest_size(a) bytes. Any thread.
digest :: proc(a: Digest_Algorithm, data: []byte, out: []byte) -> bool {
	if a == .Invalid || len(out) < digest_size(a) { return false }
	h: rawptr
	if BCryptCreateHash(bcrypt_alg(a), &h, nil, 0, nil, 0, 0) != 0 { return false }
	defer BCryptDestroyHash(h)
	rest := data
	for len(rest) > 0 {
		n := min(len(rest), 1 << 30)
		if BCryptHashData(h, raw_data(rest), u32(n), 0) != 0 { return false }
		rest = rest[n:]
	}
	return BCryptFinishHash(h, raw_data(out), u32(digest_size(a)), 0) == 0
}

random_bytes :: proc(out: []byte) -> bool {
	rest := out
	for len(rest) > 0 {
		n := min(len(rest), 1 << 30)
		if win.BCryptGenRandom(nil, raw_data(rest), u32(n), win.BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0 { return false }
		rest = rest[n:]
	}
	return true
}

// "xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx"
random_uuid :: proc(out: ^[36]u8) -> bool {
	b: [16]u8
	if !random_bytes(b[:]) { return false }
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	HEX := "0123456789abcdef"
	k := 0
	for v, i in b {
		if i == 4 || i == 6 || i == 8 || i == 10 { out[k] = '-'; k += 1 }
		out[k] = HEX[v >> 4]; out[k + 1] = HEX[v & 15]
		k += 2
	}
	return true
}

////////////////////////////////
// Imports

// getRandomValues(dst): fills guest memory. Quota past crypto.max_random_bytes, as the specification requires.
Crypto_getRandomValues :: proc(c: ^Call, destination: []u8) -> Api_Error {
	if len(destination) > c.page.settings.web.max_random_bytes { return fail(c, .Quota, "QuotaExceededError: more than crypto.max_random_bytes") }
	if len(destination) == 0 { return .None }
	return random_bytes(destination) ? .None : .Not_Supported
}

Crypto_randomUUID :: proc(c: ^Call) -> (string, Api_Error) {
	u := new([36]u8, context.temp_allocator)
	if !random_uuid(u) { return "", .Not_Supported }
	return string(u[:]), .None
}

@(private)
Digest_Job :: struct {
	page:    u64,
	promise: u64,
	owner:   u32,
	alg:     Digest_Algorithm,
	input:   []byte,
	out:     [64]u8,
	ok:      bool,
}

@(private)
digest_start :: proc(p: ^Page, owner: u32, alg_name: string, data: []byte) -> u64 {
	pr := promise_create(p, owner)
	a := digest_algorithm(alg_name)
	if a == .Invalid {
		promise_reject(p, pr, WEB_ERR_NOT_SUPPORTED, "NotSupportedError: unknown digest algorithm")
		return pr
	}
	if len(data) < p.settings.web.digest_offload_bytes || p.loader == nil || p.loader.blocking == nil {
		out: [64]u8
		if !digest(a, data, out[:]) { promise_reject(p, pr, WEB_ERR_NOT_SUPPORTED, "OperationError: digest failed"); return pr }
		// the promise settles from a task, as with any other asynchronous operation
		resolve_digest_later(p, pr, owner, out[:digest_size(a)])
		return pr
	}
	job := new(Digest_Job)
	job^ = Digest_Job{page = p.web.id, promise = pr, owner = owner, alg = a, input = make([]byte, len(data))}
	copy(job.input, data)
	host.run_blocking(p.loader.blocking, proc(data: rawptr) {
		j := (^Digest_Job)(data)
		j.ok = digest(j.alg, j.input, j.out[:])
	}, proc(data: rawptr) {
		j := (^Digest_Job)(data)
		defer { delete(j.input); free(j) }
		pg := page_by_id(j.page)
		if pg == nil { return }
		if !j.ok { promise_reject(pg, j.promise, WEB_ERR_NOT_SUPPORTED, "OperationError: digest failed"); return }
		settle_digest(pg, j.promise, j.owner, j.out[:digest_size(j.alg)])
	}, job)
	return pr
}

@(private)
settle_digest :: proc(p: ^Page, pr: u64, owner: u32, d: []byte) {
	b := buffer_create(p, d, owner)
	if b == 0 { promise_reject(p, pr, WEB_ERR_QUOTA, "QuotaExceededError: page memory limit"); return }
	promise_resolve(p, pr, i64(b))
}

@(private)
Digest_Result :: struct { promise: u64, owner: u32, n: int, out: [64]u8 }

@(private)
resolve_digest_later :: proc(p: ^Page, pr: u64, owner: u32, d: []byte) {
	r := new(Digest_Result)
	r.promise, r.owner, r.n = pr, owner, len(d)
	copy(r.out[:], d)
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		r := (^Digest_Result)(data)
		defer free(r)
		if pg != nil { settle_digest(pg, r.promise, r.owner, r.out[:r.n]) }
	}, r)
}

// crypto.subtle.digest(algorithm, data): a promise fulfilled with a buffer holding the digest.
SubtleCrypto_digest :: proc(c: ^Call, algorithm: string, data: []u8) -> u64 { return digest_start(c.page, c.owner, algorithm, data) }

SubtleCrypto_digestBuffer :: proc(c: ^Call, algorithm: string, data: Api_Buffer) -> u64 {
	return digest_start(c.page, c.owner, algorithm, data.data.bytes[:])
}