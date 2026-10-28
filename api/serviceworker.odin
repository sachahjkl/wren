// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=serviceworker order=63 exposed=(Window,Worker)
/// Service workers (src/page/service_worker.odin; native/js/runtime/web_sw.c): registrations kept by the browser, each
/// with up to three versions (installing, waiting, active), each version a JavaScript worker hosted by a page of its own
/// while it runs; requests intercepted by the loader for the pages it controls. Page side: register, ready, the
/// registrations and their versions, update, unregister, navigation preload, the controller, messages. Worker side: the
/// events the browser sends (install, activate, fetch, message, the answers to its requests) and what the worker does.
/// ServiceWorkerRegistration_info and ServiceWorker_info answer in both realms (a service worker reads the last state
/// the browser sent it).
package api_serviceworker

/// What the current event of a service worker's realm is (kind 0: none waits).
SwEventInfo :: struct {
	/// 1 install, 2 activate, 3 fetch, 4 message, 5 the answer to a request (ServiceWorkerGlobalScope_reply 10),
	/// 6 the registration changed (ServiceWorkerRegistration_info has its new state), 7 a navigation preload's response
	kind: i32,
	/// fetch / preload: the fetch's id; answer: the request's id
	id: u64,
	/// fetch: the request's mode (fetch.Mode); answer: 0 done, else rejected (text 0: why); preload: the status (0: failed)
	mode: i32,
	/// fetch: the request's destination (fetch.Destination)
	destination: i32,
	/// the client (a page's id), 0 for a navigation
	client: u64,
	/// fetch: 1 when a navigation preload runs for it (FetchEvent.preloadResponse)
	flags: i32,
}

/// navigator.serviceWorker.register(script, {scope, updateViaCache, type}): a promise of the registration's id,
/// resolved once the script ran (an unchanged script: at once; TypeError when it failed). Security outside a secure
/// context, for another origin or a scope outside what the script may control.
//@wb fn raises optional=scope
ServiceWorker_register :: proc(script: string, scope: string, update_via_cache: string, module: bool) -> Promise

/// navigator.serviceWorker.ready: a promise of the id of the active registration whose scope holds the page.
//@wb fn
ServiceWorker_ready :: proc() -> Promise

/// getRegistration(clientURL): the id of the registration matching the URL (0: none).
//@wb fn
ServiceWorker_getRegistration :: proc(client_url: string) -> u64

/// getRegistrations(): the ids of the origin's registrations, "\n"-separated.
//@wb fn
ServiceWorker_registrationIds :: proc() -> string

/// navigator.serviceWorker.controller: the id of the version controlling the page (0: none).
//@wb fn
ServiceWorker_controller :: proc() -> u64

/// A registration ("" when it is gone), "\n"-separated: scope, updateViaCache, the installing, waiting and active
/// versions' ids (0: none), navigation preload enabled (1 / 0), its header value.
//@wb fn
ServiceWorkerRegistration_info :: proc(id: u64) -> string

/// A version ("" when unknown): its state, then its script URL ("\n"-separated).
//@wb fn
ServiceWorker_info :: proc(version: u64) -> string

/// registration.unregister(): true when it was the origin's and is gone.
//@wb fn
ServiceWorkerRegistration_unregisterId :: proc(id: u64) -> bool

/// registration.update(): a promise of the registration's id once its script was checked (a new version then
/// installs). Invalid_State when the registration is gone.
//@wb fn raises
ServiceWorkerRegistration_updateId :: proc(id: u64) -> Promise

/// registration.navigationPreload: op 0 getState, 1 enable, 2 disable, 3 setHeaderValue(header). The state after:
/// enabled (1 / 0), "\n", the header value. Invalid_State for enable / disable without an active version.
//@wb fn raises
ServiceWorkerRegistration_preload :: proc(id: u64, op: i32, header: string) -> string

/// serviceWorker.postMessage(message): the serialized message to that version's worker (started if it stopped).
//@wb fn raises
ServiceWorker_postToWorker :: proc(version: u64, data: bytes)

/// The next message a service worker sent this page (Not_Found when none waits): the sender's version id (8 bytes)
/// then the serialized message.
//@wb fn raises
ServiceWorker_takeMessage :: proc() -> bytes

/// In a service worker's realm: its registration's id (0 in any other realm), its version's id, scope, script URL.
//@wb fn
ServiceWorkerGlobalScope_registration :: proc() -> u64

//@wb fn
ServiceWorkerGlobalScope_version :: proc() -> u64

//@wb fn
ServiceWorkerGlobalScope_scope :: proc() -> string

//@wb fn
ServiceWorkerGlobalScope_scriptURL :: proc() -> string

/// The current event; its strings (0 URL / an answer's text, 1 method, 2 header lines), its body; done: the next one.
//@wb fn
SwEvent_next :: proc() -> SwEventInfo

//@wb fn
SwEvent_text :: proc(which: i32) -> string

//@wb fn
SwEvent_body :: proc() -> bytes

//@wb fn
SwEvent_done :: proc()

/// What the worker did: 1 install done (code 1 ok, 0 failed), 2 activate done, 3 respond (code = status, headers,
/// text = the response's URL, body), 4 fall back to the network, 5 fail (text: why), 6 skipWaiting, 7 clients.claim,
/// 8 a message to a client (code = the client's id, 0 every controlled page; body = the serialized message),
/// 10 a request answered later by an event 5 (id = the request's id, code = 1 clients.matchAll (headers:
/// "includeUncontrolled TAB type"), 2 clients.get (text: id), 3 clients.openWindow (text: URL), 4 navigate (text: URL,
/// headers: the client's id), 5 focus (text: the client's id), 6 registration.update, 7 registration.unregister),
/// 11 navigation preload (code = op as ServiceWorkerRegistration_preload, text = the header value).
//@wb fn
ServiceWorkerGlobalScope_reply :: proc(kind: i32, id: u64, code: i64, headers: string, text: string, body: bytes)

