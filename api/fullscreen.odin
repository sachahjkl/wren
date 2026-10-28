// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=fullscreen order=20 exposed=Window
/// The Fullscreen API (src/page/fullscreen.odin): an element fills the screen. The page keeps one fullscreen element per
/// document (an <iframe>'s container is the fullscreen element of its parent while its document is), the shell makes
/// the window fill the screen and hides the browser's interface. "fullscreenchange" and "fullscreenerror" are plain
/// events (bubbling, composed) fired at the element, or at the document when the element left the tree.
package api_fullscreen

/// FullscreenOptions.navigationUI: whether the browser's interface (address bar, tabs) may be shown over the page.
FullscreenNavigation :: enum i32 {
	Auto,
	Show,
	Hide,
}

/// element.requestFullscreen(options): settled once the window is in full screen. Rejected with TypeError when the
/// element cannot go (not connected, not an element that may, the document is not allowed by the permissions policy or
/// has no recent click or key press, the tab is not shown, full screen is turned off); "fullscreenerror" is fired too.
//@wb fn
Element_requestFullscreen :: proc(element: Element, navigationUI: FullscreenNavigation) -> Promise

/// document.exitFullscreen(): settled once the window is back. Rejected with TypeError when the document has no
/// fullscreen element.
//@wb fn
Document_exitFullscreen :: proc() -> Promise

/// document.fullscreenElement: the fullscreen element, retargeted against the document; null when there is none.
//@wb fn
Document_fullscreenElement :: proc() -> Element

/// shadowRoot.fullscreenElement: the fullscreen element retargeted against the root (null when not in its tree).
//@wb fn
ShadowRoot_fullscreenElement :: proc(root: Node) -> Element

/// document.fullscreenEnabled: the document may request full screen (turned on, permissions policy "fullscreen").
//@wb fn
Document_fullscreenEnabled :: proc() -> bool

/// document.fullscreen (legacy): the document has a fullscreen element.
//@wb fn
Document_fullscreen :: proc() -> bool

