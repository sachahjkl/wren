package web

// Window, Location and History (import module "history"). Window events (popstate, hashchange, storage) are fired at
// Window_self(); visibilitychange at Document_self().
//   popstate:   event_data = the state, Event_code = 1 when there is one (0: null)
//   hashchange: event_data = newURL, event_text = oldURL

foreign import history_mod "history"

@(default_calling_convention = "contextless")
foreign history_mod {
	Window_self :: proc() -> Handle ---
	Document_self :: proc() -> Handle ---
	@(link_name = "Location_get") raw_locationGet :: proc(c: Url_Component, buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "Location_set") raw_locationSet :: proc(c: Url_Component, value: [^]u8, vl: i32) -> i32 ---
	@(link_name = "Location_assign") raw_locationAssign :: proc(url: [^]u8, n: i32) -> i32 ---
	@(link_name = "Location_replace") raw_locationReplace :: proc(url: [^]u8, n: i32) -> i32 ---
	Location_reload :: proc() -> i32 ---
	History_length :: proc() -> i32 ---
	@(link_name = "History_state") raw_historyState :: proc(buf: [^]u8, cap: i32) -> i32 ---
	@(link_name = "History_pushState") raw_pushState :: proc(state: [^]u8, sl: i32, has_state: i32, url: [^]u8, ul: i32, has_url: i32) -> i32 ---
	@(link_name = "History_replaceState") raw_replaceState :: proc(state: [^]u8, sl: i32, has_state: i32, url: [^]u8, ul: i32, has_url: i32) -> i32 ---
	History_go :: proc(delta: i32) -> i32 ---
}

location_get :: proc "contextless" (c: Url_Component, buf: []u8) -> string { return fit(buf, raw_locationGet(c, raw_data(buf), i32(len(buf)))) }
location_set :: proc "contextless" (c: Url_Component, value: string) -> i32 { return raw_locationSet(c, raw_data(value), i32(len(value))) }
location_assign :: proc "contextless" (url: string) -> i32 { return raw_locationAssign(raw_data(url), i32(len(url))) }
location_replace :: proc "contextless" (url: string) -> i32 { return raw_locationReplace(raw_data(url), i32(len(url))) }

// history.state; found = false when null.
history_state :: proc "contextless" (buf: []u8) -> (state: string, found: bool) {
	n := raw_historyState(raw_data(buf), i32(len(buf)))
	if n < 0 { return "", false }
	return fit(buf, n), true
}

// pushState(state, "", url): has_url = false keeps the current URL.
history_push_state :: proc "contextless" (state: string, url := "", has_url := false, has_state := true) -> i32 {
	return raw_pushState(raw_data(state), i32(len(state)), has_state ? 1 : 0, raw_data(url), i32(len(url)), has_url ? 1 : 0)
}
history_replace_state :: proc "contextless" (state: string, url := "", has_url := false, has_state := true) -> i32 {
	return raw_replaceState(raw_data(state), i32(len(state)), has_state ? 1 : 0, raw_data(url), i32(len(url)), has_url ? 1 : 0)
}
history_back :: proc "contextless" () -> i32 { return History_go(-1) }
history_forward :: proc "contextless" () -> i32 { return History_go(1) }
