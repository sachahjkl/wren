// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=history order=21 exposed=Window
/// Window, Location and History (HTML). Navigations requested by a module happen from a task of their own, never
/// inside the call; same-document changes (pushState, fragments) fire popstate / hashchange as HTML says.
package api_history

//@wb handle parent=Object
/// The Window object (an EventTarget: popstate, hashchange, storage...).
Window :: distinct Handle

/// window (the same object every time).
//@wb fn
Window_self :: proc() -> Window

/// document, as a node (target of visibilitychange, readystatechange...).
//@wb fn
Document_self :: proc() -> Node

/// location.href, location.protocol...
//@wb fn
Location_get :: proc(component: URLComponent) -> string

/// location.protocol = ..., location.hash = ... (href behaves like assign). Syntax for an invalid URL, Type when too long.
//@wb fn raises
Location_set :: proc(component: URLComponent, value: string)

/// location.assign(url)
//@wb fn raises
Location_assign :: proc(url: string)

/// location.replace(url)
//@wb fn raises
Location_replace :: proc(url: string)

/// location.reload()
//@wb fn
Location_reload :: proc()

/// history.length
//@wb fn
History_length :: proc() -> i32

/// history.state: Not_Found when null.
//@wb fn raises
History_state :: proc() -> string

/// history.pushState(state, "", url): Data_Clone past history.max_state_bytes, Syntax for an invalid URL, Security
/// for a URL the document cannot be rewritten to.
//@wb fn raises optional=state,url
History_pushState :: proc(state: string, url: string)

/// history.replaceState(state, "", url)
//@wb fn raises optional=state,url
History_replaceState :: proc(state: string, url: string)

/// history.go(delta): back() is go(-1), forward() go(1), go(0) reloads. Asynchronous.
//@wb fn
History_go :: proc(delta: i32 = 0)

/// What history.scrollRestoration says: whether the browser restores the scroll positions of an entry shown again.
ScrollRestoration :: enum i32 {
	Auto,
	Manual,
}

/// history.scrollRestoration, of the current entry.
//@wb fn
History_scrollRestoration :: proc() -> ScrollRestoration

/// history.scrollRestoration = mode, for the current entry (and the entries this document adds after it).
//@wb fn
History_set_scrollRestoration :: proc(mode: ScrollRestoration)

