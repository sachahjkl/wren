// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=26 partial
/// Custom elements (HTML §4.13), the browser's half (src/page/js_custom_elements.odin): which local names have a
/// definition, each element's custom element state, and the queue of reactions (upgrade, connected, disconnected,
/// attribute changed) the DOM's mutations cause. The registry and the callbacks are the engine's
/// (native/js/prelude/customelements.js).
package api_js_custom_elements

/// customElements.define(name, ...) succeeded: elements of that local name now queue reactions.
//@wb fn
CustomElements_define :: proc(name: string)

/// The size CustomElements_take needs now (0: nothing queued): the engine sizes its buffer with it, as the take
/// empties the queue (it must not be called twice to learn its size).
//@wb fn
CustomElements_pending :: proc() -> u32

/// The queued reactions, taken: per reaction u8 kind (1 upgrade, 2 connected, 3 disconnected, 4 attribute changed)
/// and u64 element; an attribute change adds its name, old value and new value (u32 length + UTF-8 each) and a u8
/// of flags (1: there was an old value, 2: there is a new one). Each element stays pinned until
/// CustomElements_release.
//@wb fn
CustomElements_take :: proc() -> bytes

/// The engine wrapped the elements of the last take (its wrappers pin them now).
//@wb fn
CustomElements_release :: proc(elements: []u64)

/// A new element of a defined local name for `new MyElement()`: custom already, nothing queued.
//@wb fn raises
CustomElements_create :: proc(name: string) -> u64

/// The element's custom element state: 0 undefined, 1 custom, 2 failed.
//@wb fn
Element_setCustomState :: proc(element: Element, state: u32)

