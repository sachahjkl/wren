// Module performance (api/performance.widl): High Resolution Time, User Timing and the browser's timeline entries
// (Navigation, Resource, Paint... Timing) on the page's own timeline. The engine side is native/js/odin/web_perf.odin.
// (Performance_now is in dom.odin.)
package api_decl

import "../abi"

// The entries a query matches (Any: every user timing entry). The values from Navigation on are the browser's timeline
// entries (Performance_timeline).
PerformanceEntryType :: enum i32 {
	Any, Mark, Measure, Navigation, Resource, Paint, Event, First_Input, Long_Task, Largest_Contentful_Paint, Layout_Shift,
	Element, Visibility_State, Long_Animation_Frame, Script,
}

// performance.timeOrigin (ms since the Unix epoch).
Performance_timeOrigin :: #type proc() -> f64
// performance.mark(name, {startTime}). Syntax for an empty name.
Performance_mark :: #type proc(name: string, start_time: f64) -> abi.Api_Error
// performance.measure(name, {start, end})
Performance_measureTimes :: #type proc(name: string, start: f64, end: f64) -> abi.Api_Error
// How many entries match `name` ("" = any) and `entry_type`.
Performance_entryCount :: #type proc(name: string, entry_type: PerformanceEntryType) -> i32
// startTime / duration of the index-th matching entry (NaN when none).
Performance_entryStartTime :: #type proc(name: string, entry_type: PerformanceEntryType, index: i32) -> f64
Performance_entryDuration :: #type proc(name: string, entry_type: PerformanceEntryType, index: i32) -> f64
// name / entryType of the index-th matching entry: Not_Found when none.
Performance_entryName :: #type proc(name: string, entry_type: PerformanceEntryType, index: i32) -> (string, abi.Api_Error)
Performance_entryType :: #type proc(name: string, entry_type: PerformanceEntryType, index: i32) -> (PerformanceEntryType, abi.Api_Error)
// performance.clearMarks(name) / clearMeasures(name): "" clears all.
Performance_clearMarks :: #type proc(name: string)
Performance_clearMeasures :: #type proc(name: string)
// The timeline entries of `entry_type` whose sequence number is at least `from_seq`, in order, as a JSON array of objects
// with the members of the entry's interface and `seq`.
Performance_timeline :: #type proc(entry_type: PerformanceEntryType, from_seq: u64) -> string
// The sequence number the next entry of this kind will have.
Performance_timelineNextSeq :: #type proc(entry_type: PerformanceEntryType) -> u64
// The DOM node a timeline entry refers to (its handle), or 0 when there is none or it is no longer in the document.
Performance_timelineNode :: #type proc(entry_type: PerformanceEntryType, seq: u64, index: u32) -> Node
// The kinds (bits 1 << PerformanceEntryType) a PerformanceObserver wants to hear of: only those wake the realm.
Performance_timelineInterest :: #type proc(kinds: u32)
// Where the browser announces new entries of those kinds (a function-table index and its `user` word).
Performance_onTimeline :: #type proc(callback: i32, user: i32)
// performance.setResourceTimingBufferSize(n) / performance.clearResourceTimings().
Performance_setResourceTimingBufferSize :: #type proc(entries: u32)
Performance_clearResourceTimings :: #type proc()
// performance.timing: the moment of attribute `which` of PerformanceTiming (in the interface's order) on the page's
// timeline (ms since the time origin), or NaN when it has not happened.
Performance_timingOf :: #type proc(which: i32) -> f64
