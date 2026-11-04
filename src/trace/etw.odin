package trace

// Wren's ETW provider is a TraceLogging one: each event carries its own description (its name, its fields' names and types),
// so WPA reads it with no manifest installed. The format is that of TraceLoggingProvider.h of the Windows SDK, written out
// here; the system's side is etw_windows.odin.

import "core:crypto/legacy/sha1"
import "core:sync"

PROVIDER_NAME :: "Wren.Browser"
// What EventSource and TraceLogging hash a provider's name under to make its GUID (provider_guid_of).
PROVIDER_GUID_NAMESPACE :: [16]u8{0x48, 0x2c, 0x2d, 0xb2, 0xc3, 0x90, 0x47, 0xc8, 0x87, 0xf8, 0x1a, 0x15, 0xbf, 0xc1, 0x30, 0xfb}
GUID_VERSION_BYTE :: 7
GUID_VERSION_NAME_HASH :: 0x50

CHANNEL_TRACELOGGING :: 11
LEVEL_VERBOSE :: 5
// Each kind of event its keyword, what a session asks for (tools/wren.wprp asks for all three)
KEYWORD_ZONES :: 0x1
KEYWORD_FRAMES :: 0x2
KEYWORD_MARKS :: 0x4

// The opcodes of winmeta.xml: WPA pairs a zone's Start with its Stop (tools/wren_regions.xml).
Opcode :: enum u8 { Info = 0, Start = 1, Stop = 2 }

// A field's types: TlgInANSISTRING (nul-terminated 8-bit characters) shown as TlgOutUTF8; IN_CHAIN says an out type follows.
IN_ANSISTRING :: 2
IN_CHAIN :: 0x80
OUT_UTF8 :: 35

// Metadata kept for an event (its name with its fields) and for the provider (its name).
ETW_EVENT_BYTES :: 64
ETW_TRAITS_BYTES :: 32

Field :: struct {
	name:     string,
	in_type:  u8,
	out_type: u8,   // 0: none
}

when ETW {
	Etw_Event :: struct {
		meta: [ETW_EVENT_BYTES]u8,
		size: u16,
	}
} else {
	Etw_Event :: struct {}
}

// An event's metadata ("EventMetadata"): its size (u16, itself included), its tags (one byte, none), its name and each
// field's (nul-terminated UTF-8), each field's in type, its out type after it when it has one. 0: it does not fit in `out`.
event_metadata :: proc "contextless" (out: []u8, name: string, fields: []Field) -> int {
	need := 2 + 1 + len(name) + 1
	for f in fields { need += len(f.name) + 1 + (f.out_type != 0 ? 2 : 1) }
	if need > len(out) || need > int(max(u16)) { return 0 }
	out[0], out[1] = u8(need), u8(need >> 8)
	out[2] = 0
	at := 3 + copy(out[3:], name)
	out[at] = 0
	at += 1
	for f in fields {
		at += copy(out[at:], f.name)
		out[at] = 0
		at += 1
		if f.out_type == 0 { out[at] = f.in_type; at += 1; continue }
		out[at], out[at + 1] = f.in_type | IN_CHAIN, f.out_type
		at += 2
	}
	return need
}

// The provider's traits ("ProviderMetadata"): their size (u16, itself included) and the provider's name, nul-terminated.
provider_traits :: proc "contextless" (out: []u8, name: string) -> int {
	need := 2 + len(name) + 1
	if need > len(out) { return 0 }
	out[0], out[1] = u8(need), u8(need >> 8)
	copy(out[2:], name)
	out[need - 1] = 0
	return need
}

// The GUID of a provider named `name`, as its bytes in memory: SHA-1 of the namespace and the name upper-cased in UTF-16
// big-endian, its first 16 bytes, marked as a name-based GUID (version 5). Names here are ASCII.
provider_guid_of :: proc(name: string) -> (guid: [16]u8) {
	ctx: sha1.Context
	sha1.init(&ctx)
	ns := PROVIDER_GUID_NAMESPACE
	sha1.update(&ctx, ns[:])
	for c in transmute([]u8)name {
		unit := [2]u8{0, c >= 'a' && c <= 'z' ? c - ('a' - 'A') : c}
		sha1.update(&ctx, unit[:])
	}
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	copy(guid[:], digest[:])
	guid[GUID_VERSION_BYTE] = guid[GUID_VERSION_BYTE] & 0x0f | GUID_VERSION_NAME_HASH
	return
}

// What the sessions listening ask of the provider (the system's enable callback writes it, any thread reads it).
Enable_State :: struct {
	level_plus1: u32,   // 0: no session
	any, all:    u64,   // the keywords: an event needs one of `any` and all of `all`
}

// The enable callback's arguments: `is_enabled` 0 stops, 1 starts, 2 asks for a state (which changes nothing here); level 0
// and no keyword mean everything.
enable_update :: proc "contextless" (s: ^Enable_State, is_enabled: u32, level: u8, any, all: u64) {
	switch is_enabled {
	case 0:
		sync.atomic_store_explicit(&s.level_plus1, 0, .Relaxed)
	case 1:
		sync.atomic_store_explicit(&s.any, any == 0 ? max(u64) : any, .Relaxed)
		sync.atomic_store_explicit(&s.all, all, .Relaxed)
		sync.atomic_store_explicit(&s.level_plus1, level == 0 ? u32(max(u8)) + 1 : u32(level) + 1, .Relaxed)
	}
}

enable_allows :: #force_inline proc "contextless" (s: ^Enable_State, level: u8, keyword: u64) -> bool {
	if u32(level) >= sync.atomic_load_explicit(&s.level_plus1, .Relaxed) { return false }
	all := sync.atomic_load_explicit(&s.all, .Relaxed)
	return keyword & sync.atomic_load_explicit(&s.any, .Relaxed) != 0 && keyword & all == all
}
