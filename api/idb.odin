// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=idb order=22 exposed=(Window,Worker)
/// IndexedDB (the JavaScript engine's prelude, native/js/lazy/idb.js, is the only caller). One entry point: the
/// operation is a code and its arguments and its reply are bytes in the encoding of src/idb (LEB128 integers, length
/// prefixed byte strings). The first byte of the reply is a status (src/idb Error: 0 is success). Raises Security when
/// the page may not use IndexedDB (an opaque origin, indexeddb.enabled off, no profile storage).
///
/// Operations: 1 open, 2 delete, 3 list, 4 close, 5 versionchange handled, 6 begin a transaction, 7 commit, 8 abort,
/// 9 execute a request of a transaction, 10 queue a task for the realm, 11 take the event being delivered,
/// 12 ask for the end-of-checkpoint hook (transactions go inactive), 13 limits, 14 the source of the prelude (answered before
/// anything else: it needs no client; the realm loads it when a script first uses an IndexedDB interface).
/// Windows and dedicated workers: a worker's realm is a client of the same manager as the pages of its origin.
package api_idb

/// See the module comment.
//@wb fn raises
Idb_call :: proc(op: i32, args: bytes) -> bytes

