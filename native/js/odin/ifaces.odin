// ifaces.odin: interface indices used by more than one ported domain, resolved by name once and cached (the glue
// never hardcodes the generated WJ_IFACE_* numbers). An index only one domain uses stays file-private in that domain.
package odin_glue

import "../odin/wj"

@(private) _iface_element := i32(-2)
@(private) _iface_node := i32(-2)
@(private) _iface_html_element := i32(-2)
@(private) _iface_event := i32(-2)
@(private) _iface_event_target := i32(-2)

iface_element :: proc "c" () -> i32 { if _iface_element == -2 { _iface_element = wj.iface("Element") }; return _iface_element }
iface_node :: proc "c" () -> i32 { if _iface_node == -2 { _iface_node = wj.iface("Node") }; return _iface_node }
iface_html_element :: proc "c" () -> i32 { if _iface_html_element == -2 { _iface_html_element = wj.iface("HTMLElement") }; return _iface_html_element }
iface_event :: proc "c" () -> i32 { if _iface_event == -2 { _iface_event = wj.iface("Event") }; return _iface_event }
iface_event_target :: proc "c" () -> i32 { if _iface_event_target == -2 { _iface_event_target = wj.iface("EventTarget") }; return _iface_event_target }
