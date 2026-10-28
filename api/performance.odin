// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=performance order=59 exposed=(Window,Worker)
/// High Resolution Time and User Timing: performance.now() and timeOrigin on the page's own timeline, mark / measure,
/// getEntriesByName / getEntriesByType (one entry at a time), clearMarks / clearMeasures. Entries are kept in startTime
/// order, at most performance.max_user_timing_entries (the oldest go first).
package api_performance

/// The entries a query matches (Any: every user timing entry). The values from Navigation on are the browser's
/// timeline entries (Performance_timeline): the document's navigation, its resources, paints, slow inputs and long
/// tasks (Long_Task: a task of the window's realm that took 50 ms or more), the largest contentful paint, the layout
/// shifts, the element timing entries and the visibility-state changes.
PerformanceEntryType :: enum i32 {
	Any,
	Mark,
	Measure,
	Navigation,
	Resource,
	Paint,
	Event,
	First_Input,
	Long_Task,
	Largest_Contentful_Paint,
	Layout_Shift,
	Element,
	Visibility_State,
	Long_Animation_Frame,
	Script,
}

/// A function of the realm the browser calls when a kind of timeline entry it was asked for (Performance_timelineInterest)
/// has new entries: `kinds` has one bit for each (1 << PerformanceEntryType).
//@wb callback
TimelineCallback :: #type proc "contextless" (user: i32, kinds: i32)

/// performance.now()
//@wb fn
Performance_now :: proc() -> f64

/// performance.timeOrigin (ms since the Unix epoch).
//@wb fn
Performance_timeOrigin :: proc() -> f64

/// performance.mark(name, {startTime}): a negative or NaN start_time means now. Syntax for an empty name.
//@wb fn raises
Performance_mark :: proc(name: string, start_time: f64 = -1)

/// performance.measure(name, startMark, endMark): an empty start is the time origin, an empty end is now. Syntax for
/// a mark that does not exist.
//@wb fn raises
Performance_measure :: proc(name: string, start_mark: string = "", end_mark: string = "")

/// performance.measure(name, {start, end})
//@wb fn raises
Performance_measureTimes :: proc(name: string, start: f64, end: f64)

/// How many entries match `name` ("" = any) and `entry_type`.
//@wb fn
Performance_entryCount :: proc(name: string, entry_type: PerformanceEntryType) -> i32

/// startTime of the index-th matching entry (NaN when none).
//@wb fn
Performance_entryStartTime :: proc(name: string, entry_type: PerformanceEntryType, index: i32) -> f64

/// duration of the index-th matching entry (NaN when none).
//@wb fn
Performance_entryDuration :: proc(name: string, entry_type: PerformanceEntryType, index: i32) -> f64

/// name of the index-th matching entry: Not_Found when none.
//@wb fn raises
Performance_entryName :: proc(name: string, entry_type: PerformanceEntryType, index: i32) -> string

/// entryType of the index-th matching entry (Mark or Measure): Not_Found when none.
//@wb fn raises
Performance_entryType :: proc(name: string, entry_type: PerformanceEntryType, index: i32) -> PerformanceEntryType

/// performance.clearMarks(name): "" clears all.
//@wb fn
Performance_clearMarks :: proc(name: string = "")

/// performance.clearMeasures(name): "" clears all.
//@wb fn
Performance_clearMeasures :: proc(name: string = "")

/// The timeline entries of `entry_type` (Navigation, Resource, Paint, Event or First_Input) whose sequence number is at
/// least `from_seq`, in order, as a JSON array of objects with the members of the entry's interface (name, startTime,
/// duration, initiatorType, responseStart...) and `seq`. A kept entry never changes; the buffers drop their oldest
/// entries (performance.resource_timing_entries...).
//@wb fn
Performance_timeline :: proc(entry_type: PerformanceEntryType, from_seq: u64 = 0) -> string

/// The sequence number the next entry of this kind will have.
//@wb fn
Performance_timelineNextSeq :: proc(entry_type: PerformanceEntryType) -> u64

/// Wraps the DOM node a timeline entry refers to and returns its handle, or 0 when there is none or it is no longer in
/// the document: the element of the `index`-th member of entry `seq` of `entry_type` — for Largest_Contentful_Paint and
/// Element, index 0 is the entry's own element (its `element` attribute); for Layout_Shift, index i is the node of its
/// i-th source (LayoutShiftAttribution.node). The engine carries the other members of each entry in the JSON of
/// Performance_timeline; only live node handles come from here (a handle cannot be put in JSON and stay valid).
//@wb fn
Performance_timelineNode :: proc(entry_type: PerformanceEntryType, seq: u64, index: u32) -> u64

/// The kinds (bits 1 << PerformanceEntryType) a PerformanceObserver wants to hear of: only those wake the realm.
//@wb fn
Performance_timelineInterest :: proc(kinds: u32)

/// Where the browser announces new entries of the kinds of Performance_timelineInterest (a task of the page).
//@wb fn
Performance_onTimeline :: proc(callback: TimelineCallback, user: i32 = 0)

/// performance.setResourceTimingBufferSize(n) / performance.clearResourceTimings().
//@wb fn
Performance_setResourceTimingBufferSize :: proc(entries: u32)

//@wb fn
Performance_clearResourceTimings :: proc()

/// performance.timing (Navigation Timing 1): the moment of attribute `which` of PerformanceTiming (0 navigationStart,
/// 1 unloadEventStart ... 20 loadEventEnd, in the interface's order) on the page's timeline (ms since the time
/// origin), or NaN when it has not happened or does not apply (the attribute is then 0). The network phases of the
/// document's own fetch are not measured: they are all the time origin.
//@wb fn
Performance_timingOf :: proc(which: i32) -> f64

