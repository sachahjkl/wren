// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=35 partial
/// Geometry for JavaScript (CSSOM View; src/page/js_dom_layout.odin). The layout belongs to the embedder (the shell
/// lays the document out for its viewport): a reading brings it up to date first through the page's layout hook
/// (set_layout_embedder), which does nothing when no mutation, style change or viewport change happened since. Without
/// an embedder (a page nobody shows) boxes are empty and the viewport is 0 x 0. Values are CSS pixels.
package api_js_dom_layout

/// A rectangle (DOMRect).
DomRect :: struct {
	x: f64,
	y: f64,
	width: f64,
	height: f64,
}

/// element.getBoundingClientRect(): the border box as drawn (transforms applied), in viewport coordinates.
//@wb fn
Element_boundingRect :: proc(element: Element) -> DomRect

/// element.getClientRects(): per box fragment, 32 bytes each (x, y, width, height as f64).
//@wb fn
Element_clientRectsPacked :: proc(element: Element) -> bytes

/// element.clientTop, clientLeft, clientWidth, clientHeight (the viewport's size for the root element).
//@wb fn
Element_clientTop :: proc(element: Element) -> i32

//@wb fn
Element_clientLeft :: proc(element: Element) -> i32

//@wb fn
Element_clientWidth :: proc(element: Element) -> i32

//@wb fn
Element_clientHeight :: proc(element: Element) -> i32

/// element.scrollTop / scrollLeft (the document's scroll offsets for the scrolling element).
//@wb fn
Element_scrollTop :: proc(element: Element) -> f64

//@wb fn
Element_set_scrollTop :: proc(element: Element, value: f64)

//@wb fn
Element_scrollLeft :: proc(element: Element) -> f64

//@wb fn
Element_set_scrollLeft :: proc(element: Element, value: f64)

/// element.scrollWidth / scrollHeight
//@wb fn
Element_scrollWidth :: proc(element: Element) -> i32

//@wb fn
Element_scrollHeight :: proc(element: Element) -> i32

/// element.scrollTo(x, y) / scrollBy (relative): NaN keeps that axis.
//@wb fn
Element_scrollToXY :: proc(element: Element, x: f64, y: f64, relative: bool)

/// element.scrollIntoView(options): block and inline 0 start, 1 center, 2 end, 3 nearest.
//@wb fn
Element_scrollIntoViewAt :: proc(element: Element, block: i32, inline_pos: i32)

/// htmlElement.offsetParent, offsetTop, offsetLeft, offsetWidth, offsetHeight
//@wb fn
HTMLElement_offsetParent :: proc(element: Element) -> Element

//@wb fn
HTMLElement_offsetTop :: proc(element: Element) -> i32

//@wb fn
HTMLElement_offsetLeft :: proc(element: Element) -> i32

//@wb fn
HTMLElement_offsetWidth :: proc(element: Element) -> i32

//@wb fn
HTMLElement_offsetHeight :: proc(element: Element) -> i32

/// document.elementFromPoint(x, y) (viewport coordinates)
//@wb fn
Document_elementFromPoint :: proc(x: f64, y: f64) -> Element

/// window.innerWidth / innerHeight
//@wb fn
Window_innerWidth :: proc() -> i32

//@wb fn
Window_innerHeight :: proc() -> i32

/// window.outerWidth / outerHeight (the viewport's: the shell's window is not the page's business)
//@wb fn
Window_outerWidth :: proc() -> i32

//@wb fn
Window_outerHeight :: proc() -> i32

/// window.scrollX / scrollY and their aliases
//@wb fn
Window_scrollX :: proc() -> f64

//@wb fn
Window_scrollY :: proc() -> f64

//@wb fn
Window_pageXOffset :: proc() -> f64

//@wb fn
Window_pageYOffset :: proc() -> f64

/// window.devicePixelRatio
//@wb fn
Window_devicePixelRatio :: proc() -> f64

/// window.screenX / screenY / screenLeft / screenTop (0: the page does not learn where the window is)
//@wb fn
Window_screenX :: proc() -> i32

//@wb fn
Window_screenY :: proc() -> i32

//@wb fn
Window_screenLeft :: proc() -> i32

//@wb fn
Window_screenTop :: proc() -> i32

/// window.scrollTo(x, y) / scrollBy (relative): NaN keeps that axis; `smooth` asks for a smooth scroll.
//@wb fn
Window_scrollToXY :: proc(x: f64, y: f64, relative: bool, smooth: bool)

/// The bounding box of a range's contents (Range.getBoundingClientRect), as Element_boundingRect.
//@wb fn
Range_boundingRect :: proc(start: Node, start_offset: u32, end: Node, end_offset: u32) -> DomRect

/// Range.getClientRects(), packed as Element_clientRectsPacked.
//@wb fn
Range_clientRectsPacked :: proc(start: Node, start_offset: u32, end: Node, end_offset: u32) -> bytes

