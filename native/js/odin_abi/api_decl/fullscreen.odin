// The Fullscreen API's browser side (module fullscreen; the engine side is native/js/odin/web_fullscreen.odin): the
// request that makes the window fill the screen, settled by a browser promise (a handle of module async).
package api_decl

import "../abi"

// FullscreenOptions.navigationUI: whether the browser's interface may be shown over the page.
Fullscreen_Navigation :: enum i32 {Auto, Show, Hide}

// element.requestFullscreen(options): a browser promise settled once the window is in full screen.
Element_requestFullscreen :: #type proc(element: Element, navigation_ui: Fullscreen_Navigation) -> abi.Handle
