// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=animations order=1 exposed=Window
/// Web Animations (src/page/web_animations.odin): Element.animate, Animation, KeyframeEffect, document.timeline. The
/// browser keeps each animation's state (start time, hold time, playback rate, pending play or pause, play state,
/// replace state) and plays its keyframe effect on the style timeline (src/style/script_anim.odin) like a CSS
/// animation; the engine keeps the JavaScript objects (the KeyframeEffect, the promises) and mirrors what the browser
/// tells it (Animation_takeOps). Times are milliseconds on the document timeline; NaN stands for null (unresolved).
/// "finish", "cancel" and "remove" are fired at the animation (AnimationPlaybackEvent: Event x = currentTime, y =
/// timelineTime, NaN for null).
package api_animations

//@wb handle parent=Object host=Web_Animation lookup=lookup_Animation
Animation :: distinct Handle

AnimationPlayState :: enum i32 {
	Idle,
	Running,
	Paused,
	Finished,
}

AnimationReplaceState :: enum i32 {
	Active,
	Removed,
	Persisted,
}

/// new Animation(): no effect, on the document timeline. `notify(user)` runs as a microtask when there is something
/// to take (Animation_takeOps).
//@wb fn
Animation_create :: proc(notify: MicrotaskCallback, user: i32) -> Animation

/// Sets the animation's keyframe effect: its target (0: none), its keyframes packed by the engine (offsets computed:
/// keyframes separated by U+001E, fields by U+001F: offset, easing, then property / value pairs), its timing
/// (duration NaN: "auto"; direction and fill as the style engine's enums, fill "auto" as none) and composite
/// operation (0 replace, 1 add, 2 accumulate). Type when an easing does not parse.
//@wb fn raises optional=target
Animation_setEffect :: proc(animation: Animation, target: Element, keyframes: string, duration: f64, delay: f64, end_delay: f64, iterations: f64, iteration_start: f64, direction: i32, fill: i32, easing: string, composite: i32)

/// animation.effect = null
//@wb fn
Animation_clearEffect :: proc(animation: Animation)

/// animation.timeline = document.timeline (true) or null (false).
//@wb fn
Animation_setTimeline :: proc(animation: Animation, document_timeline: bool)

/// play(): Invalid_State to play backwards an effect that never ends.
//@wb fn raises
Animation_play :: proc(animation: Animation)

/// pause(): Invalid_State to pause before the start of an effect that never ends, backwards.
//@wb fn raises
Animation_pause :: proc(animation: Animation)

/// finish(): Invalid_State at a playback rate of 0, or forwards with an effect that never ends.
//@wb fn raises
Animation_finish :: proc(animation: Animation)

/// cancel()
//@wb fn
Animation_cancel :: proc(animation: Animation)

/// reverse(): Invalid_State without a timeline, or as play().
//@wb fn raises
Animation_reverse :: proc(animation: Animation)

/// persist()
//@wb fn
Animation_persist :: proc(animation: Animation)

/// commitStyles(): the effect's animated values written into the target's style attribute. No_Modification_Allowed
/// without a target element, Invalid_State when it is not rendered.
//@wb fn raises
Animation_commitStyles :: proc(animation: Animation)

/// updatePlaybackRate(rate)
//@wb fn
Animation_updatePlaybackRate :: proc(animation: Animation, rate: f64)

/// animation.playbackRate
//@wb fn
Animation_playbackRate :: proc(animation: Animation) -> f64

/// animation.playbackRate = rate (the current time is kept)
//@wb fn
Animation_set_playbackRate :: proc(animation: Animation, rate: f64)

/// animation.currentTime (NaN: null)
//@wb fn
Animation_currentTime :: proc(animation: Animation) -> f64

/// animation.currentTime = t: Type for null when the current time is resolved.
//@wb fn raises
Animation_set_currentTime :: proc(animation: Animation, time: f64)

/// animation.startTime (NaN: null)
//@wb fn
Animation_startTime :: proc(animation: Animation) -> f64

/// animation.startTime = t (NaN: null)
//@wb fn
Animation_set_startTime :: proc(animation: Animation, time: f64)

/// animation.playState
//@wb fn
Animation_playState :: proc(animation: Animation) -> AnimationPlayState

/// animation.replaceState
//@wb fn
Animation_replaceState :: proc(animation: Animation) -> AnimationReplaceState

/// animation.pending
//@wb fn
Animation_pending :: proc(animation: Animation) -> bool

/// What changed for the engine since the last call, one letter each, in order: r the ready promise is resolved, R it
/// is rejected (AbortError) and replaced by a resolved one, n a new pending ready promise; f the finished promise is
/// resolved, F it is rejected (AbortError) and replaced by a pending one, m a new pending finished promise; k / u the
/// wrapper must be kept alive (the animation may still fire events or show its effect) / may go.
/// Nothing is taken away: Animation_dropOps does once the engine applied them.
//@wb fn
Animation_takeOps :: proc(animation: Animation) -> string

/// The first `count` letters of Animation_takeOps were applied.
//@wb fn
Animation_dropOps :: proc(animation: Animation, count: i32)

/// AnimationPlaybackEvent of the browser: which 0 currentTime, 1 timelineTime (NaN: null).
//@wb fn
AnimationPlaybackEvent_time :: proc(event: Event, which: i32) -> f64

/// effect.getComputedTiming() of the animation's effect: which 0 localTime, 1 progress, 2 currentIteration; NaN: null.
//@wb fn
Animation_computedTiming :: proc(animation: Animation, which: i32) -> f64

/// The relevant animations (Web Animations 1 §5.7) of `root` (with `subtree`: of it and its descendants), or of the
/// whole document when `root` is 0, in composite order: 8 bytes per handle.
//@wb fn optional=root
Animation_relevant :: proc(root: Node, subtree: bool) -> bytes

/// A CSS animation or transition among Animation_relevant's handles (src/page/web_animations_css.odin).
CssAnimationInfo :: struct {
	/// 0 not a CSS one (a script's), 1 CSSAnimation, 2 CSSTransition
	kind: i32,
	target: u64,
	delay: f64,
	duration: f64,
	iterations: f64,
}

/// What a CSS animation or transition is, for its wrapper; `notify(user)` then runs as for Animation_create.
//@wb fn
Animation_cssBind :: proc(animation: Animation, notify: MicrotaskCallback, user: i32) -> CssAnimationInfo

/// CSSAnimation.animationName / CSSTransition.transitionProperty ("" once it is gone).
//@wb fn
Animation_cssName :: proc(animation: Animation) -> string

/// document.timeline.currentTime (NaN: null)
//@wb fn
DocumentTimeline_currentTime :: proc() -> f64

/// Whether `easing` is an easing function (CSS Easing 2).
//@wb fn
Animation_validEasing :: proc(easing: string) -> bool

