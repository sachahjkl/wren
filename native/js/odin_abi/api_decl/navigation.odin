// Module navigation (api/navigation.widl): the Navigation API over the tab's session history. The engine side is
// native/js/odin/web_navigation.odin. (Navigation_pendingSource returns a struct through an address with no status:
// outside the comptime bridge, called as the import.)
package api_decl

import "../abi"

// navigation.entries(): "<current index>\n" then "<key> <id> <same document 0|1> <url>\n" per entry.
Navigation_entries :: #type proc() -> string
// Changes with every change of the session history (the engine reads the entries again only then).
Navigation_serial :: #type proc() -> i64
// entry.getState(): the state of the entry `key` while its id is `id`; Not_Found when it has none.
Navigation_getState :: #type proc(key: i64, id: i64) -> (string, abi.Api_Error)
// navigation.updateCurrentEntry({state}): Data_Clone past history.max_state_bytes, Invalid_State without entries.
Navigation_updateCurrentEntry :: #type proc(state: string) -> abi.Api_Error
// navigation.navigate(url, {state, history}) (history: 0 auto, 1 push, 2 replace): Syntax for an invalid URL,
// Not_Supported for a push to a javascript: URL, Data_Clone for a state too big. navigate fires inside the call.
Navigation_navigate :: #type proc(url: string, state: Maybe(string), history: i32) -> abi.Api_Error
// navigation.reload({state}): without a state the entry keeps its own.
Navigation_reload :: #type proc(state: Maybe(string)) -> abi.Api_Error
// navigation.traverseTo(key), back(), forward(): Invalid_State when no entry has this key.
Navigation_traverseTo :: #type proc(key: i64) -> abi.Api_Error
// The navigation whose navigate event is being fired: "<type> <flags> <key> <id> <index> <url>". Not_Found outside the
// firing.
Navigation_pending :: #type proc() -> (string, abi.Api_Error)
// destination.getState() of that navigation: Not_Found when it has none.
Navigation_pendingState :: #type proc() -> (string, abi.Api_Error)
// navigation.activation: "<type> <from key>"; "" when the document was not reached by a navigation the browser measured.
Navigation_activation :: #type proc() -> string
