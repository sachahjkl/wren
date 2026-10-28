// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=navigation order=57 exposed=Window
/// The Navigation API (HTML): window.navigation over the tab's session history. The browser keeps the entries, their
/// states and every navigation; the engine fires navigate (wj_nav_fire, reading Navigation_pending) before the browser
/// commits a navigation, and the rest (wj_nav_commit) after a same-document commit. Keys and ids are numbers here.
package api_navigation

/// navigation.entries(): "<current index>\n" then "<key> <id> <same document 0|1> <url>\n" per entry (the same-origin
/// entries around the current one; none for an opaque origin, current index -1).
//@wb fn
Navigation_entries :: proc() -> string

/// Changes with every change of the session history (the engine reads the entries again only then).
//@wb fn
Navigation_serial :: proc() -> i64

/// entry.getState(): the state of the entry `key` while its id is `id`; Not_Found when it has none.
//@wb fn raises
Navigation_getState :: proc(key: i64, id: i64) -> string

/// navigation.updateCurrentEntry({state}): Data_Clone past history.max_state_bytes, Invalid_State without entries.
//@wb fn raises
Navigation_updateCurrentEntry :: proc(state: string)

/// navigation.navigate(url, {state, history}) (history: 0 auto, 1 push, 2 replace): Syntax for an invalid URL,
/// Not_Supported for a push to a javascript: URL, Data_Clone for a state too big. navigate fires inside the call.
//@wb fn raises optional=state
Navigation_navigate :: proc(url: string, state: string, history: i32 = 0)

/// navigation.reload({state}): without a state the entry keeps its own.
//@wb fn raises optional=state
Navigation_reload :: proc(state: string)

/// navigation.traverseTo(key), back(), forward(): Invalid_State when no entry has this key. From a task of its own.
//@wb fn raises
Navigation_traverseTo :: proc(key: i64)

/// The navigation whose navigate event is being fired: "<type> <flags> <key> <id> <index> <url>" (type: 0 push,
/// 1 replace, 2 reload, 3 traverse; flags: 1 same document, 2 user initiated, 4 hash change, 8 can intercept,
/// 16 cancelable, 32 has a state). Not_Found outside the firing.
//@wb fn raises
Navigation_pending :: proc() -> string

/// destination.getState() of that navigation: Not_Found when it has none.
//@wb fn raises
Navigation_pendingState :: proc() -> string

/// What started that navigation, besides its URL: the element (event.sourceElement: a link, a submitter, a form
/// submitted without one) and, for a POST form submission, the form and its submitter (event.formData). 0: none.
NavigationSource :: struct {
	source: u64,
	form: u64,
	submitter: u64,
}

//@wb fn
Navigation_pendingSource :: proc() -> NavigationSource

/// navigation.activation: "<type> <from key>" (type as Navigation_pending's; from key 0: null, the entry of the
/// document this one replaced when it is among navigation.entries()); "" when the document was not reached by a
/// navigation the browser measured (activation null).
//@wb fn
Navigation_activation :: proc() -> string

