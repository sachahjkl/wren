// Module frames (api/frames.widl): the other windows of the tab ("nested navigables"), reached through the browser
// by navigable id (native/js/odin/frames.odin). An id is a number of the browser's, not an object handle; 0 is none.
package api_decl

import "../abi"

Navigable :: distinct abi.Handle

Frame_self        :: #type proc() -> Navigable
Frame_top         :: #type proc(navigable: Navigable) -> Navigable
Frame_parent      :: #type proc(navigable: Navigable) -> Navigable
Frame_length      :: #type proc(navigable: Navigable) -> u32
Frame_child       :: #type proc(navigable: Navigable, index: u32) -> Navigable
Frame_named       :: #type proc(navigable: Navigable, name: string) -> Navigable
Frame_childNames  :: #type proc(navigable: Navigable) -> abi.Bytes   // NUL-separated
Frame_closed      :: #type proc(navigable: Navigable) -> bool
Frame_sameOrigin  :: #type proc(navigable: Navigable) -> bool
Frame_documentOf  :: #type proc(navigable: Navigable) -> Node
Frame_elementOf   :: #type proc(navigable: Navigable) -> Node
Frame_ofDocument  :: #type proc(node: Node) -> Navigable
Frame_target      :: #type proc(node: Node) -> bool
Frame_adoptNode   :: #type proc(node: Node, into: Node) -> (abi.Bytes, abi.Api_Error)
Frame_windowTarget :: #type proc(navigable: Navigable) -> EventTarget
Frame_realmSelf   :: #type proc() -> u64
Frame_realmOf     :: #type proc(navigable: Navigable) -> u64
Frame_bridge      :: #type proc(realm: u64, request: abi.Bytes) -> u32
Frame_bridgeReply :: #type proc() -> abi.Bytes
Frame_ofElement   :: #type proc(element: Element) -> Navigable
Frame_navigate    :: #type proc(navigable: Navigable, url: string, replace: bool) -> abi.Api_Error
Frame_open        :: #type proc(url: string, target: string, features: string) -> (Navigable, abi.Api_Error)
Frame_opener      :: #type proc(navigable: Navigable) -> Navigable
Frame_close       :: #type proc(navigable: Navigable)
Frame_disown      :: #type proc()
// a structured-clone of the message and the transferred ports' ends
Frame_postMessagePorts :: #type proc(navigable: Navigable, data: abi.Bytes, target_origin: string, ports: []u64) -> abi.Api_Error
