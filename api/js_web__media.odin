// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=media order=50 exposed=Window
package api_js_web__media

//@wb handle parent=Object host=Media_Query_List lookup=lookup_MediaQueryList
/// A media query list evaluated against the page's viewport (CSSOM View matchMedia); an EventTarget whose "change"
/// event is fired when the result changes (after a resize, a zoom, a change of the color scheme), Event_code being
/// the new result.
MediaQueryList :: distinct Handle

/// A dimension of the screen (CSS pixels of the monitor showing the page).
ScreenField :: enum i32 {
	Width,
	Height,
	Avail_Width,
	Avail_Height,
	Avail_Left,
	Avail_Top,
	Color_Depth,
}

/// window.matchMedia(query): an invalid query is "not all" (it never matches).
//@wb fn
MediaQueryList_create :: proc(query: string) -> MediaQueryList

/// mql.media: the query list serialized.
//@wb fn
MediaQueryList_media :: proc(list: MediaQueryList) -> string

/// mql.matches, as of the page's last style computation (or now when it never had one).
//@wb fn
MediaQueryList_matches :: proc(list: MediaQueryList) -> bool

/// screen.width, screen.availHeight...
//@wb fn
Screen_get :: proc(field: ScreenField) -> i32

