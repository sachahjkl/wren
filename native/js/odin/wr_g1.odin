// wr_g1.odin: the host imports (wr_* in the C, api/*.widl modules) the G1-ported glue reaches. In the C these come
// from gen/wren_api.h as WR_IMPORT("module", "name") (an import_module / import_name attribute, C symbol wr_name). On
// the Odin side a `foreign import _m_<module> "<module>"` block names the wasm import module and each proc's
// @(link_name) is the import field, matching the host's registration (src/page/api_generated.odin and the engine's
// host). Only the imports a ported file no longer leaves referenced in C must be declared here; declaring the others
// too is harmless (wasm-ld folds them to the same import).
//
// These are kept in the odin_glue package (not wj) so the host-boundary ABI lives next to the ported domains that use
// it. Each ported file's unique imports are grouped by module below.
package odin_glue

import "../odin/wj"

// module "async"
foreign import _m_async "async"
@(default_calling_convention = "c")
foreign _m_async {
	@(link_name = "Object_release") wr_Object_release :: proc(object: u64) -> i32 ---
}

// module "events"
foreign import _m_events "events"
@(default_calling_convention = "c")
foreign _m_events {
	@(link_name = "TouchEvent_count") wr_TouchEvent_count :: proc(event: u64, list: i32) -> i32 ---
	@(link_name = "TouchEvent_touch") wr_TouchEvent_touch :: proc(event: u64, list: i32, index: i32, ret: ^wj.Wr_TouchPoint) -> i32 ---
	@(link_name = "Event_data")   wr_Event_data   :: proc(event: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Event_text")   wr_Event_text   :: proc(event: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Event_object") wr_Event_object :: proc(event: u64) -> u64 ---
}

// module "popover"
foreign import _m_popover "popover"
@(default_calling_convention = "c")
foreign _m_popover {
	@(link_name = "Popover_show")     wr_Popover_show     :: proc(element: u64, source: u64) -> i32 ---
	@(link_name = "Popover_hide")     wr_Popover_hide     :: proc(element: u64) -> i32 ---
	@(link_name = "Popover_toggle")   wr_Popover_toggle   :: proc(element: u64, force: i32, source: u64, ret: ^u8) -> i32 ---
	@(link_name = "Popover_state")    wr_Popover_state    :: proc(element: u64) -> i32 ---
	@(link_name = "Popover_targetOf") wr_Popover_targetOf :: proc(invoker: u64) -> u64 ---
}

// module "dom"
foreign import _m_dom "dom"
@(default_calling_convention = "c")
foreign _m_dom {
	// ResizeObserver (web_resize.odin)
	@(link_name = "ResizeObserver_create")      wr_ResizeObserver_create      :: proc(notify: u32, user: i32) -> u64 ---
	@(link_name = "ResizeObserver_observe")     wr_ResizeObserver_observe     :: proc(observer: u64, target: u64, box: i32) -> i32 ---
	@(link_name = "ResizeObserver_unobserve")   wr_ResizeObserver_unobserve   :: proc(observer: u64, target: u64) ---
	@(link_name = "ResizeObserver_disconnect")  wr_ResizeObserver_disconnect  :: proc(observer: u64) ---
	@(link_name = "ResizeObserver_observed")    wr_ResizeObserver_observed    :: proc(observer: u64) -> u32 ---
	@(link_name = "ResizeObserver_takeEntries") wr_ResizeObserver_takeEntries :: proc(observer: u64, buf: [^]u8, cap: u32) -> i32 ---

	// IntersectionObserver (intersection.odin)
	@(link_name = "IntersectionObserver_create")       wr_IntersectionObserver_create       :: proc(notify: u32, user: i32, root: u64, root_margin: [^]u8, root_margin_len: u32, scroll_margin: [^]u8, scroll_margin_len: u32, thresholds: [^]u8, thresholds_len: u32, ret: ^u64) -> i32 ---
	@(link_name = "IntersectionObserver_rootMargin")   wr_IntersectionObserver_rootMargin   :: proc(observer: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "IntersectionObserver_scrollMargin") wr_IntersectionObserver_scrollMargin :: proc(observer: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "IntersectionObserver_observe")      wr_IntersectionObserver_observe      :: proc(observer: u64, target: u64) -> i32 ---
	@(link_name = "IntersectionObserver_unobserve")    wr_IntersectionObserver_unobserve    :: proc(observer: u64, target: u64) ---
	@(link_name = "IntersectionObserver_disconnect")   wr_IntersectionObserver_disconnect   :: proc(observer: u64) ---
	@(link_name = "IntersectionObserver_observed")     wr_IntersectionObserver_observed     :: proc(observer: u64) -> u32 ---
	@(link_name = "IntersectionObserver_takeRecords")  wr_IntersectionObserver_takeRecords  :: proc(observer: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "IntersectionObserver_release")      wr_IntersectionObserver_release      :: proc(observer: u64) ---

	// shared Element / Node imports (also used by C that stays; declaring them here is harmless)
	@(link_name = "Element_setAttribute")    wr_Element_setAttribute    :: proc(element: u64, name: [^]u8, name_len: u32, value: [^]u8, value_len: u32) -> i32 ---
	@(link_name = "Element_getAttribute")    wr_Element_getAttribute    :: proc(element: u64, name: [^]u8, name_len: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Element_removeAttribute") wr_Element_removeAttribute :: proc(element: u64, name: [^]u8, name_len: u32) -> i32 ---
	@(link_name = "Node_isConnected")        wr_Node_isConnected        :: proc(node: u64) -> i32 ---

	// dom_layout.odin
	@(link_name = "Element_boundingRect")      wr_Element_boundingRect      :: proc(element: u64, ret: ^wj.Wr_DomRect) ---
	@(link_name = "Element_clientRectsPacked") wr_Element_clientRectsPacked :: proc(element: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Element_scrollToXY")        wr_Element_scrollToXY_raw    :: proc(element: u64, x: f64, y: f64, relative: i32) ---
	@(link_name = "Element_scrollIntoViewAt")  wr_Element_scrollIntoViewAt  :: proc(element: u64, block: i32, inline_pos: i32) ---
	@(link_name = "Window_scrollToXY")         wr_Window_scrollToXY_raw     :: proc(x: f64, y: f64, relative: i32, smooth: i32) ---

	// dom_forms.odin (dom module parts)
	@(link_name = "Node_parentNode")              wr_Node_parentNode              :: proc(node: u64) -> u64 ---
	@(link_name = "Collection_length")            wr_Collection_length            :: proc(collection: u64) -> u32 ---
	@(link_name = "Collection_item")              wr_Collection_item              :: proc(collection: u64, index: u32) -> u64 ---
	@(link_name = "HTMLFormElement_namedControl") wr_HTMLFormElement_namedControl :: proc(form: u64, name: [^]u8, name_len: u32) -> u64 ---
	@(link_name = "Node_preInsert")               wr_Node_preInsert               :: proc(parent: u64, node: u64, child: u64) -> i32 ---
	@(link_name = "ChildNode_remove")             wr_ChildNode_remove             :: proc(node: u64) ---
	@(link_name = "Document_createElementChecked") wr_Document_createElementChecked :: proc(local_name: [^]u8, local_name_len: u32, ret: ^u64) -> i32 ---

	// dom_style.odin
	@(link_name = "InlineStyle_getProperty")    wr_InlineStyle_getProperty    :: proc(element: u64, name: [^]u8, name_len: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "InlineStyle_priority")       wr_InlineStyle_priority       :: proc(element: u64, name: [^]u8, name_len: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "InlineStyle_setProperty")    wr_InlineStyle_setProperty    :: proc(element: u64, name: [^]u8, name_len: u32, value: [^]u8, value_len: u32, priority: [^]u8, priority_len: u32) -> i32 ---
	@(link_name = "InlineStyle_removeProperty") wr_InlineStyle_removeProperty :: proc(element: u64, name: [^]u8, name_len: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "InlineStyle_cssText")        wr_InlineStyle_cssText        :: proc(element: u64, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "InlineStyle_setCssText")     wr_InlineStyle_setCssText     :: proc(element: u64, text: [^]u8, text_len: u32) -> i32 ---
	@(link_name = "InlineStyle_length")         wr_InlineStyle_length         :: proc(element: u64) -> u32 ---
	@(link_name = "InlineStyle_item")           wr_InlineStyle_item           :: proc(element: u64, index: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "ComputedStyle_get")          wr_ComputedStyle_get          :: proc(element: u64, pseudo: [^]u8, pseudo_len: u32, name: [^]u8, name_len: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "ComputedStyle_count")        wr_ComputedStyle_count        :: proc() -> u32 ---
	@(link_name = "ComputedStyle_name")         wr_ComputedStyle_name         :: proc(index: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "CSS_supportsDeclaration")    wr_CSS_supportsDeclaration    :: proc(property: [^]u8, property_len: u32, value: [^]u8, value_len: u32) -> i32 ---
	@(link_name = "CSS_supportsCondition")      wr_CSS_supportsCondition      :: proc(condition: [^]u8, condition_len: u32) -> i32 ---

	// custom_elements.odin
	@(link_name = "CustomElements_define")         wr_CustomElements_define         :: proc(name: [^]u8, name_len: u32) ---
	@(link_name = "CustomElements_pending")        wr_CustomElements_pending        :: proc() -> u32 ---
	@(link_name = "CustomElements_take")           wr_CustomElements_take           :: proc(buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "CustomElements_release")        wr_CustomElements_release        :: proc(elements: [^]u64, elements_len: u32) ---
	@(link_name = "CustomElements_create")         wr_CustomElements_create         :: proc(name: [^]u8, name_len: u32, ret: ^u64) -> i32 ---
	@(link_name = "Element_setCustomState")        wr_Element_setCustomState        :: proc(element: u64, state: u32) ---
	@(link_name = "CustomElements_disable")        wr_CustomElements_disable        :: proc(name: [^]u8, name_len: u32, shadow: i32, internals: i32) ---
	@(link_name = "Document_shadowIncludingByName") wr_Document_shadowIncludingByName :: proc(name: [^]u8, name_len: u32, buf: [^]u8, cap: u32) -> i32 ---
	@(link_name = "Node_shadowIncludingElements")  wr_Node_shadowIncludingElements  :: proc(root: u64, buf: [^]u8, cap: u32) -> i32 ---
}

// module "forms"
foreign import _m_forms "forms"
@(default_calling_convention = "c")
foreign _m_forms {
	@(link_name = "HTMLInputElement_selectionStart")     wr_HTMLInputElement_selectionStart     :: proc(control: u64) -> i32 ---
	@(link_name = "HTMLTextAreaElement_selectionStart")  wr_HTMLTextAreaElement_selectionStart  :: proc(control: u64) -> i32 ---
	@(link_name = "HTMLInputElement_selectionEnd")       wr_HTMLInputElement_selectionEnd       :: proc(control: u64) -> i32 ---
	@(link_name = "HTMLTextAreaElement_selectionEnd")    wr_HTMLTextAreaElement_selectionEnd    :: proc(control: u64) -> i32 ---
	@(link_name = "HTMLInputElement_setSelectionRange")  wr_HTMLInputElement_setSelectionRange  :: proc(control: u64, start: i32, end: i32, direction: i32) -> i32 ---
	@(link_name = "HTMLTextAreaElement_setSelectionRange") wr_HTMLTextAreaElement_setSelectionRange :: proc(control: u64, start: i32, end: i32, direction: i32) -> i32 ---
	@(link_name = "HTMLFormElement_length")              wr_HTMLFormElement_length              :: proc(form: u64) -> i32 ---
	@(link_name = "HTMLFormElement_elements")            wr_HTMLFormElement_elements            :: proc(form: u64, index: i32) -> u64 ---
}

// thin wrappers converting Odin bool to the i32 the host expects (ABI: C int32_t, not a 1-byte Odin bool).
wr_Element_scrollToXY :: #force_inline proc "c" (element: u64, x: f64, y: f64, relative: bool) { wr_Element_scrollToXY_raw(element, x, y, relative ? 1 : 0) }
wr_Window_scrollToXY :: #force_inline proc "c" (x: f64, y: f64, relative: bool, smooth: bool) { wr_Window_scrollToXY_raw(x, y, relative ? 1 : 0, smooth ? 1 : 0) }
