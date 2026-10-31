package fetch

// The blob URL store: the URL.createObjectURL of a realm, for the loads it does not make itself. The bytes are a copy, since a
// Blob's are in its realm's memory. Process-wide, because a worker's and its document's are on different threads; a URL is good only
// for the origin that made it (File API: "obtain a blob object").

import "core:strings"
import "core:sync"
import "wb:base"
import "wb:url"

@(private = "file")
Blob_Url :: struct {
	bytes:  []byte,
	mime:   string,
	origin: url.Origin,
	refs:   i32,   // the store's, and each load's
}

@(private = "file")
blob_store: struct {
	mu:   sync.Mutex,
	urls: map[string]^Blob_Url,
}

@(private = "file")
blob_key :: proc(href: string) -> string {
	i := strings.index_byte(href, '#')
	return i >= 0 ? href[:i] : href
}

@(private = "file")
blob_release :: proc(b: ^Blob_Url) {
	if sync.atomic_sub(&b.refs, 1) != 1 { return }
	context.allocator = base.process_allocator()
	delete(b.bytes)
	delete(b.mime)
	url.origin_destroy(&b.origin)
	free(b)
}

blob_url_register :: proc(href, mime: string, bytes: []byte, origin: url.Origin) {
	context.allocator = base.process_allocator()
	b := new(Blob_Url)
	b.bytes = make([]byte, len(bytes))
	copy(b.bytes, bytes)
	b.mime, b.origin, b.refs = strings.clone(mime), url.origin_clone(origin), 1
	sync.mutex_guard(&blob_store.mu)
	key := blob_key(href)
	if old, ok := blob_store.urls[key]; ok {
		blob_release(old)
		blob_store.urls[key] = b
		return
	}
	blob_store.urls[strings.clone(key)] = b
}

blob_url_revoke :: proc(href: string) {
	context.allocator = base.process_allocator()
	sync.mutex_guard(&blob_store.mu)
	k, b, ok := delete_map_key(&blob_store.urls, blob_key(href))
	if !ok { return }
	delete(k)
	blob_release(b)
	if len(blob_store.urls) == 0 {
		delete(blob_store.urls)
		blob_store.urls = nil
	}
}

@(private = "file")
delete_map_key :: proc(m: ^map[string]^Blob_Url, key: string) -> (string, ^Blob_Url, bool) {
	if key not_in m^ { return "", nil, false }
	k, v := delete_key(m, key)
	return k, v, true
}

// The load of a blob: URL: a network error when it names nothing, or names what another origin made.
@(private)
blob_hop :: proc(t: ^Task) {
	if t.method != "GET" { fail(t, .Unsupported, "a blob: URL can only be read with GET"); return }
	sync.mutex_lock(&blob_store.mu)
	b := blob_store.urls[blob_key(t.target.href)]
	if b != nil { sync.atomic_add(&b.refs, 1) }
	sync.mutex_unlock(&blob_store.mu)
	if b == nil { fail(t, .Bad_URL, "this blob: URL names nothing (it was revoked, or its realm has gone)"); return }
	defer blob_release(b)
	if t.mode != .Navigate && !url.same_origin(t.origin, b.origin) { fail(t, .Blocked_Same_Origin, "a blob: URL of another origin"); return }
	t.taint = .Basic   // (as a data: response: readable by whoever may ask for it)
	synthetic(t, 200, b.mime, b.bytes)
}