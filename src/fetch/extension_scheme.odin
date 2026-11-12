package fetch

// The scheme of extension pages (docs/extensions.md, section 3.4): chrome-extension://<id>/<path> is a file of that
// extension's package, read off the interface thread from the package's index (never from a path the URL makes up).
//
//   * Who may load a URL of extension E is one function, extension_may_load: E's own origin; a navigation the browser
//     itself starts (the address bar, a bookmark, the shell: no initiator); a path of web_accessible_resources whose
//     `matches` cover the initiator. Anything else gets the same network error as an absent extension or an absent
//     file: a page cannot tell "refused" from "not installed".
//   * The response carries the policy of extension pages (the manifest's, or Chrome's default) and is not cached.
//   * A request whose initiator is an extension origin, to a host the user granted it, is same-origin for CORS
//     (extension_cors_granted): no preflight, the response is readable.
// The registry is the App's (page.Pages.extensions): the Loader gets a pointer to it, as it gets the content blocker.

import "core:fmt"
import "core:os"
import "core:strings"
import "wb:base"
import "wb:extensions"
import "wb:host"
import "wb:http"
import "wb:url"

// The one answer to every refused or absent extension URL (Chrome's net::ERR_FILE_NOT_FOUND).
EXTENSION_NOT_FOUND :: "net::ERR_FILE_NOT_FOUND"

// The rules of section 3.4 (pure). `initiator`: nil for a navigation the browser starts. `rel`: the normalised path.
extension_may_load :: proc(initiator: ^Environment, im: ^extensions.Image, rel: string) -> bool {
	if initiator == nil { return true }                                          // rule 2
	o := initiator.origin
	if !o.opaque && o.scheme == extensions.SCHEME_CHROME && o.host == im.id { return true }   // rule 1
	for war in im.manifest.web_accessible {                                      // rule 3
		listed := false
		for r in war.resources { if extensions.glob_match(r, rel) { listed = true; break } }
		if !listed { continue }
		for p in war.matches { if extensions.pattern_matches(p, initiator.location) { return true } }
	}
	return false
}

// The extension and the path a URL of the scheme names, when it may be loaded by `initiator` (nil, "" otherwise).
extension_resolve :: proc(reg: ^extensions.Registry, target: url.URL, initiator: ^Environment) -> (^extensions.Extension, string) {
	e := extensions.registry_running(reg, target.scheme, target.host)
	if e == nil { return nil, "" }
	rel, ok := extensions.package_path_normalize(url.percent_decode(target.path), context.temp_allocator)
	if !ok || rel == "" || !extensions.image_has_file(e.image, rel) { return nil, "" }
	if !extension_may_load(initiator, e.image, rel) { return nil, "" }
	return e, rel
}

// A request of an extension's page or background to a host the user granted it: same-origin for CORS.
extension_cors_granted :: proc(t: ^Task) -> bool {
	env := t.initiator
	if env == nil || env.origin.opaque || env.origin.scheme != extensions.SCHEME_CHROME { return false }
	reg := t.loader.extensions
	e := extensions.registry_running(reg, env.origin.scheme, env.origin.host)
	return e != nil && extensions.extension_host_allowed(reg, e, t.target.href)
}

@(private)
Ext_Job :: struct {
	loader: ^Loader,
	task:   base.Handle,
	image:  ^extensions.Image,   // retained for the job (a reload may replace it meanwhile)
	rel:    string,
	max:    int,
	data:   []byte,
	ok:     bool,
}

@(private)
extension_hop :: proc(t: ^Task) {
	l := t.loader
	e, rel := extension_resolve(l.extensions, t.target, t.initiator)
	if e == nil { fail(t, .Blocked_File, EXTENSION_NOT_FOUND); return }
	t.taint = .Basic   // (allowed: what it reads is the requester's to read, its own file or a web-accessible one)
	t.stage = .Local
	a := base.process_allocator()
	job := new(Ext_Job, a)
	job^ = {loader = l, task = t.self, image = extensions.image_retain(e.image), rel = strings.clone(rel, a), max = t.max_body > 0 ? t.max_body : l.net.settings.max_body}
	host.run_blocking(l.blocking, extension_work, extension_done, job, extension_discard)
}

@(private)
extension_work :: proc(data: rawptr) {
	j := (^Ext_Job)(data)
	context.allocator = base.process_allocator()
	entry, found := j.image.files[j.rel]
	if !found || entry.size > i64(j.max) { return }
	bytes, err := os.read_entire_file(strings.concatenate({j.image.root, "/", j.rel}, context.temp_allocator), context.allocator)
	if err != nil { return }
	j.data, j.ok = bytes, true
}

@(private)
extension_discard :: proc(data: rawptr) {
	j := (^Ext_Job)(data)
	a := base.process_allocator()
	extensions.image_release(j.image)
	delete(j.rel, a); delete(j.data, a)
	free(j, a)
}

@(private)
extension_done :: proc(data: rawptr) {
	j := (^Ext_Job)(data)
	defer extension_discard(data)
	t := base.pool_get(&j.loader.tasks, j.task)
	if t == nil { return }
	if !j.ok { fail(t, .Blocked_File, EXTENSION_NOT_FOUND); return }
	mime := mime_for_extension(j.rel)
	raw := http.headers_make(context.temp_allocator)
	http.append_header(&raw, "Content-Type", mime)
	http.append_header(&raw, "Content-Length", fmt.tprintf("%d", len(j.data)))
	// the policy of extension pages: their documents and workers (a sandbox page gets its own policy in a later phase)
	if t.destination == .Document || is_frame_destination(t.destination) || t.destination == .Worker {
		http.append_header(&raw, "Content-Security-Policy", j.image.page_csp)
	}
	http.append_header(&raw, "Cache-Control", "no-store")
	m, has := http.parse_mime(mime, context.temp_allocator)
	if why, ok := check_task_mime(t, m, has, false); !ok { fail(t, .Bad_Mime, why); return }
	h, l := t.self, t.loader
	head := t.method == "HEAD"
	send_response(t, 200, raw, m, has)
	cur := base.pool_get(&l.tasks, h)
	if cur == nil { return }
	body := head ? nil : j.data
	if cur.collect {
		append(&cur.collected, ..body)
	} else if len(body) > 0 {
		ev := Event{kind = .Data, data = body}
		deliver(cur, &ev)
		if cur = base.pool_get(&l.tasks, h); cur == nil { return }
	}
	done := Event{kind = .Done}
	if cur.collect { done.data = cur.collected[:] }
	deliver(cur, &done)
	release(l, h)
}
