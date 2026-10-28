// The Web Animations domain (module animations of api/animations.widl): the calls the hand-written members of
// web_animations.odin make. The members the bindings generator binds itself (play, pause, cancel, playbackRate...) are
// not repeated. Animation_cssBind is not declared: its result is a struct written through a pointer with no status,
// a shape today's scalar wire has no lowering for (web_animations.odin names the import).
package api_decl

import "../abi"

Animation :: distinct abi.Handle

// new Animation(): `notify(user)` (a function-table index) runs as a microtask when there is something to take
// (Animation_takeOps). 0 without a document.
Animation_create :: #type proc(notify: i32, user: i32) -> Animation
// The effect as the browser plays it: the packed keyframes (offset \x1f easing [\x1f property \x1f value]... with
// \x1e between keyframes), the timing (duration NaN: auto), the effect's composite operation.
Animation_setEffect :: #type proc(animation: Animation, target: u64, keyframes: []u8, duration, delay, end_delay, iterations, iteration_start: f64,
	direction: i32, fill: i32, easing: string, composite: i32) -> abi.Api_Error
Animation_clearEffect :: #type proc(animation: Animation)
Animation_setTimeline :: #type proc(animation: Animation, document_timeline: bool)
Animation_play        :: #type proc(animation: Animation) -> abi.Api_Error
Animation_currentTime :: #type proc(animation: Animation) -> f64   // NaN: unresolved
Animation_set_currentTime :: #type proc(animation: Animation, time: f64) -> abi.Api_Error
Animation_startTime   :: #type proc(animation: Animation) -> f64
Animation_set_startTime :: #type proc(animation: Animation, time: f64)
Animation_playState   :: #type proc(animation: Animation) -> i32
Animation_replaceState :: #type proc(animation: Animation) -> i32
// The letters of what to apply to the promises and the wrapper (r n R f F m k u), not taken away until dropOps.
Animation_takeOps     :: #type proc(animation: Animation) -> string
Animation_dropOps     :: #type proc(animation: Animation, count: i32)
// localTime (which 0), progress (1), currentIteration (2): NaN for null
Animation_computedTiming :: #type proc(animation: Animation, which: i32) -> f64
// The relevant animations of `root` (0: the document), in composite order: 8 bytes per handle.
Animation_relevant    :: #type proc(root: u64, subtree: bool) -> (abi.Bytes, abi.Api_Error)
Animation_cssName     :: #type proc(animation: Animation) -> string
Animation_validEasing :: #type proc(easing: string) -> bool
DocumentTimeline_currentTime :: #type proc() -> f64

// AnimationPlaybackEvent's currentTime (which 0) and timelineTime (1) of a browser event: NaN for null
AnimationPlaybackEvent_time :: #type proc(event: u64, which: i32) -> f64

// The payload of a browser event (module dom: Event_data, Event_text, Event_code). Shared with the events glue:
// move them to its declarations when that domain lands, the wire is the same.
Event_code :: #type proc(event: u64) -> i64
