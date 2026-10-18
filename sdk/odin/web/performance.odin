package web

// performance.now / timeOrigin / mark / measure / getEntries (import module "performance").

foreign import performance_mod "performance"

Entry_Type :: enum i32 { Any = 0, Mark = 1, Measure = 2 }

@(default_calling_convention = "contextless")
foreign performance_mod {
	Performance_now :: proc() -> f64 ---
	Performance_timeOrigin :: proc() -> f64 ---
	@(link_name = "Performance_mark") raw_mark :: proc(name: [^]u8, nl: i32, start: f64) -> i32 ---
	@(link_name = "Performance_measure") raw_measure :: proc(name: [^]u8, nl: i32, start: [^]u8, sl: i32, end: [^]u8, el: i32) -> i32 ---
	@(link_name = "Performance_measureTimes") raw_measureTimes :: proc(name: [^]u8, nl: i32, start, end: f64) -> i32 ---
	@(link_name = "Performance_entryCount") raw_entryCount :: proc(name: [^]u8, nl: i32, type: Entry_Type) -> i32 ---
	@(link_name = "Performance_entryStartTime") raw_entryStart :: proc(name: [^]u8, nl: i32, type: Entry_Type, index: i32) -> f64 ---
	@(link_name = "Performance_entryDuration") raw_entryDuration :: proc(name: [^]u8, nl: i32, type: Entry_Type, index: i32) -> f64 ---
	@(link_name = "Performance_entryName") raw_entryName :: proc(name: [^]u8, nl: i32, type: Entry_Type, index: i32, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Performance_entryType") raw_entryType :: proc(name: [^]u8, nl: i32, type: Entry_Type, index: i32) -> Entry_Type ---
	@(link_name = "Performance_clearMarks") raw_clearMarks :: proc(name: [^]u8, nl: i32) ---
	@(link_name = "Performance_clearMeasures") raw_clearMeasures :: proc(name: [^]u8, nl: i32) ---
}

// start_time < 0: now
performance_mark :: proc "contextless" (name: string, start_time: f64 = -1) -> i32 { return raw_mark(raw_data(name), i32(len(name)), start_time) }

// measure(name, startMark, endMark): "" = time origin / now.
performance_measure :: proc "contextless" (name: string, start_mark := "", end_mark := "") -> i32 {
	return raw_measure(raw_data(name), i32(len(name)), raw_data(start_mark), i32(len(start_mark)), raw_data(end_mark), i32(len(end_mark)))
}

// getEntriesByName(name, type) / ByType (name "") / getEntries: count, then each entry by index.
performance_entry_count :: proc "contextless" (name: string, type := Entry_Type.Any) -> int { return int(raw_entryCount(raw_data(name), i32(len(name)), type)) }
performance_entry :: proc "contextless" (name: string, type: Entry_Type, index: int) -> (start, duration: f64) {
	return raw_entryStart(raw_data(name), i32(len(name)), type, i32(index)), raw_entryDuration(raw_data(name), i32(len(name)), type, i32(index))
}
performance_clear_marks :: proc "contextless" (name := "") { raw_clearMarks(raw_data(name), i32(len(name))) }
performance_clear_measures :: proc "contextless" (name := "") { raw_clearMeasures(raw_data(name), i32(len(name))) }
