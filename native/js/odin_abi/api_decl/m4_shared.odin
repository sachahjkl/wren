// Declarations of other modules the M4 domains call (events, async, media_source, webcodecs): to fold into those
// modules' files when they are migrated (a twin elsewhere is the same declaration: keep one).
package api_decl

import "../abi"

// A new browser EventTarget (the listeners of an object made in the engine: ports, viewports, statuses).
EventTarget_create :: #type proc() -> abi.Handle
// Releases a host object (Invalid_Handle when it is gone).
Object_release :: #type proc(object: abi.Handle) -> abi.Api_Error

MediaSourceHandle :: distinct abi.Handle
// A MediaSourceHandle of a transfer list: the token the receiving realm adopts (the handle is detached).
MediaSourceHandle_take :: #type proc(h: MediaSourceHandle) -> (u64, abi.Api_Error)
// The receiving realm's MediaSourceHandle of a token.
MediaSourceHandle_adopt :: #type proc(token: u64) -> (MediaSourceHandle, abi.Api_Error)

// The layout the compat members read (api/js_dom_layout.widl, dom.widl). Elements are plain u64 node handles here
// (the DOM's handle kinds are the DOM migration's). Element_boundingRect returns a struct through an address with no
// status: outside the comptime bridge, called as the import.
Window_scrollX :: #type proc() -> f64
Window_scrollY :: #type proc() -> f64
Document_documentElement :: #type proc() -> u64
Element_clientWidth :: #type proc(element: u64) -> i32
Element_clientHeight :: #type proc(element: u64) -> i32
Element_scrollIntoViewAt :: #type proc(element: u64, block: i32, inline_pos: i32)

VideoFrame :: distinct abi.Handle
// A VideoFrame of a transfer list: its pixels moved into a token (0 when the frame is closed).
VideoFrame_takeForTransfer :: #type proc(frame: VideoFrame) -> u64
// The receiving realm's VideoFrame of a token (0 when the token is unknown).
VideoFrame_adoptTransfer :: #type proc(token: u64) -> VideoFrame
