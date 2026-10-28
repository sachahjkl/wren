// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=42 partial
/// ResizeObserver and IntersectionObserver for JavaScript (src/page/js_observers.odin, js_resize_observer.odin,
/// js_intersection_observer.odin; engine side native/js/runtime/web_resize.c, intersection.c).
///
/// The browser keeps the observations: which element is observed by which observer, with what box, and what was last
/// reported. It measures them from the layout at each rendering update, after the animation frame callbacks and before
/// the paint, and calls the observer's `notify(user)` in the engine when there is something to deliver; the engine takes
/// the entries and runs the script's callback. The targets are pinned while they are observed.
package api_js_observers

/// new ResizeObserver: `notify(user)` runs, inside a rendering update, when some target's observed box changed; it
/// takes the entries with ResizeObserver_takeEntries.
//@wb fn
ResizeObserver_create :: proc(notify: MicrotaskCallback, user: i32) -> Object

/// observer.observe(target, { box }): box 0 content-box, 1 border-box, 2 device-pixel-content-box. Observing a target
/// again with the same box does nothing; with another, the observation starts over.
//@wb fn raises
ResizeObserver_observe :: proc(observer: u64, target: Element, box: i32)

//@wb fn
ResizeObserver_unobserve :: proc(observer: u64, target: Element)

//@wb fn
ResizeObserver_disconnect :: proc(observer: u64)

/// How many targets the observer observes (the engine keeps the observer alive while it is not 0).
//@wb fn
ResizeObserver_observed :: proc(observer: u64) -> u32

/// The entries being delivered, 72 bytes each, little endian: target u64, then eight f64: borderBoxSize (inline, block),
/// contentBoxSize, devicePixelContentBoxSize, and the content rect's left and top.
//@wb fn
ResizeObserver_takeEntries :: proc(observer: u64) -> bytes

/// new IntersectionObserver: `root` is the root element or document (0: the viewport), `thresholds` the f64 values
/// ascending (already checked to be in [0, 1]); `notify(user)` runs, from a task of the page, when entries were queued,
/// and takes them with IntersectionObserver_takeRecords. Syntax when a margin is not one to four lengths in px or %.
//@wb fn raises
IntersectionObserver_create :: proc(notify: MicrotaskCallback, user: i32, root: u64, root_margin: string, scroll_margin: string, thresholds: bytes) -> Object

/// observer.rootMargin / scrollMargin: the four sides, each a number and its unit ("10px 0px 10px 0px").
//@wb fn
IntersectionObserver_rootMargin :: proc(observer: u64) -> string

//@wb fn
IntersectionObserver_scrollMargin :: proc(observer: u64) -> string

//@wb fn raises
IntersectionObserver_observe :: proc(observer: u64, target: Element)

//@wb fn
IntersectionObserver_unobserve :: proc(observer: u64, target: Element)

/// observer.disconnect(): no more targets; the entries already queued stay for takeRecords.
//@wb fn
IntersectionObserver_disconnect :: proc(observer: u64)

/// How many targets the observer observes (the engine keeps the observer alive while it is not 0).
//@wb fn
IntersectionObserver_observed :: proc(observer: u64) -> u32

/// The entries waiting, 128 bytes each, little endian: target u64, time f64, intersectionRatio f64, flags u32 (bit 0
/// isIntersecting, bit 1 isVisible, bit 2 rootBounds is not null), 4 bytes of 0, then twelve f64: rootBounds,
/// boundingClientRect and intersectionRect as x, y, width, height. Nothing changes until IntersectionObserver_release,
/// so a call that did not fit can be made again.
//@wb fn
IntersectionObserver_takeRecords :: proc(observer: u64) -> bytes

/// The engine made the entries it took: they leave the queue (and the pins of their targets go).
//@wb fn
IntersectionObserver_release :: proc(observer: u64)

