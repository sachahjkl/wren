// Module serviceworker (api/serviceworker.widl): service workers, both sides (the page's navigator.serviceWorker and the
// worker's own global). Registrations and versions are numbers of the browser (an id is not an object handle; 0 is
// none). The engine side is native/js/odin/web_sw.odin. (SwEvent_next returns a struct through an address with no status:
// outside the comptime bridge, called as the import.)
package api_decl

import "../abi"

// navigator.serviceWorker.register(script, {scope, updateViaCache, type}): a promise of the registration's id. `scope`
// absent: the script's directory.
ServiceWorker_register :: #type proc(script: string, scope: Maybe(string), update_via_cache: string, module: bool) -> (Promise, abi.Api_Error)
// navigator.serviceWorker.ready: a promise of a registration's id.
ServiceWorker_ready :: #type proc() -> Promise
// getRegistration(clientURL): the registration id for the URL, 0 for none.
ServiceWorker_getRegistration :: #type proc(client_url: string) -> u64
// getRegistrations(): the ids, one per line.
ServiceWorker_registrationIds :: #type proc() -> string
// navigator.serviceWorker.controller: a version id, 0 for none.
ServiceWorker_controller :: #type proc() -> u64
// A registration: "<scope>\n<updateViaCache>\n<installing>\n<waiting>\n<active>\n<preload enabled>\n<preload header>"; ""
// when it is gone.
ServiceWorkerRegistration_info :: #type proc(id: u64) -> string
// A version: "<state>\n<script URL>".
ServiceWorker_info :: #type proc(version: u64) -> string
ServiceWorkerRegistration_unregisterId :: #type proc(id: u64) -> bool
ServiceWorkerRegistration_updateId :: #type proc(id: u64) -> (Promise, abi.Api_Error)
// NavigationPreloadManager: op 0 getState ("<0|1>\n<header>"), 1 enable, 2 disable, 3 setHeaderValue(header).
ServiceWorkerRegistration_preload :: #type proc(id: u64, op: i32, header: string) -> (string, abi.Api_Error)
// worker.postMessage(message) of a version.
ServiceWorker_postToWorker :: #type proc(version: u64, data: abi.Bytes) -> abi.Api_Error
// The next message a service worker posted to the page: the sender's version id (8 bytes) then the serialized value; empty
// when there is none.
ServiceWorker_takeMessage :: #type proc() -> abi.Bytes

// In a service worker's realm: its registration and version ids, its scope.
ServiceWorkerGlobalScope_registration :: #type proc() -> u64
ServiceWorkerGlobalScope_version :: #type proc() -> u64
ServiceWorkerGlobalScope_scope :: #type proc() -> string
// What the worker answers the browser (kind: SW_REPLY_*): an event's outcome, or a request of its own.
ServiceWorkerGlobalScope_reply :: #type proc(kind: i32, id: u64, code: i64, headers: string, text: string, body: abi.Bytes)
// The text number `which` / the body of the event SwEvent_next announced.
SwEvent_text :: #type proc(which: i32) -> string
SwEvent_body :: #type proc() -> abi.Bytes
// The event has been handled.
SwEvent_done :: #type proc()
