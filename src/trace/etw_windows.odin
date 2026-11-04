#+build windows
package trace

// The provider registered with the system (EventRegister), its traits set once (EventSetInformation), its events written
// with their metadata in front (EventWriteTransfer: the first two data descriptors, of the kinds the system reads as such).

when ETW {

foreign import advapi32 "system:Advapi32.lib"

@(private) EVENT_PROVIDER_SET_TRAITS :: 2   // EVENT_INFO_CLASS EventProviderSetTraits
@(private) DATA_EVENT_METADATA :: 1         // EVENT_DATA_DESCRIPTOR_TYPE_EVENT_METADATA
@(private) DATA_PROVIDER_METADATA :: 2      // EVENT_DATA_DESCRIPTOR_TYPE_PROVIDER_METADATA
@(private) MARK_EVENT :: "Mark"
@(private) MARK_FIELD :: "Name"
@(private) PRESENT_EVENT :: "Presented"   // (not "Present": a phase's name)

@(private)
Event_Descriptor :: struct {
	id:      u16,
	version: u8,
	channel: u8,
	level:   u8,
	opcode:  u8,
	task:    u16,
	keyword: u64,
}

@(private)
Event_Data_Descriptor :: struct {
	ptr:       u64,
	size:      u32,
	kind:      u8,
	reserved1: u8,
	reserved2: u16,
}

@(private)
Enable_Callback :: #type proc "system" (source: ^[16]u8, is_enabled: u32, level: u8, any, all: u64, filter, ctx: rawptr)

@(private, default_calling_convention = "system")
foreign advapi32 {
	EventRegister :: proc(provider: ^[16]u8, callback: Enable_Callback, ctx: rawptr, handle: ^u64) -> u32 ---
	EventSetInformation :: proc(handle: u64, class: i32, info: rawptr, size: u32) -> u32 ---
	EventWriteTransfer :: proc(handle: u64, descriptor: ^Event_Descriptor, activity, related: rawptr, count: u32, data: [^]Event_Data_Descriptor) -> u32 ---
}

@(private)
Provider :: struct {
	handle:      u64,
	guid:        [16]u8,
	state:       Enable_State,
	traits:      [ETW_TRAITS_BYTES]u8,
	traits_size: u16,
}

// The process's provider (registered once by `start`, from the main thread before any other); its two events of its own.
@(private) provider: Provider
@(private) etw_present: Etw_Event
@(private) etw_mark_event: Etw_Event

@(private)
etw_start :: proc() {
	if provider.handle != 0 { return }
	provider.guid = provider_guid_of(PROVIDER_NAME)
	provider.traits_size = u16(provider_traits(provider.traits[:], PROVIDER_NAME))
	etw_present = etw_event(PRESENT_EVENT)
	mark_fields := [1]Field{{name = MARK_FIELD, in_type = IN_ANSISTRING, out_type = OUT_UTF8}}
	etw_mark_event.size = u16(event_metadata(etw_mark_event.meta[:], MARK_EVENT, mark_fields[:]))
	if EventRegister(&provider.guid, etw_enable_callback, nil, &provider.handle) != 0 { provider.handle = 0; return }
	EventSetInformation(provider.handle, EVENT_PROVIDER_SET_TRAITS, &provider.traits, u32(provider.traits_size))
}

@(private)
etw_enable_callback :: proc "system" (source: ^[16]u8, is_enabled: u32, level: u8, any, all: u64, filter, ctx: rawptr) {
	enable_update(&provider.state, is_enabled, level, any, all)
}

@(private)
etw_event :: proc(name: string) -> (e: Etw_Event) {
	e.size = u16(event_metadata(e.meta[:], name, nil))
	return
}

@(private)
etw_listening :: #force_inline proc "contextless" () -> bool { return enable_allows(&provider.state, LEVEL_VERBOSE, KEYWORD_ZONES) }

@(private)
etw_emit :: proc "contextless" (e: ^Etw_Event, opcode: Opcode, keyword: u64) {
	if !enable_allows(&provider.state, LEVEL_VERBOSE, keyword) { return }
	data := [2]Event_Data_Descriptor{etw_provider_data(), etw_event_data(e)}
	etw_write(opcode, keyword, data[:])
}

@(private)
etw_mark :: proc "contextless" (text: string) {
	if !enable_allows(&provider.state, LEVEL_VERBOSE, KEYWORD_MARKS) { return }
	nul := u8(0)
	data := [4]Event_Data_Descriptor{etw_provider_data(), etw_event_data(&etw_mark_event), {ptr = u64(uintptr(raw_data(text))), size = u32(len(text))}, {ptr = u64(uintptr(&nul)), size = 1}}
	etw_write(.Info, KEYWORD_MARKS, data[:])
}

@(private)
etw_provider_data :: #force_inline proc "contextless" () -> Event_Data_Descriptor {
	return {ptr = u64(uintptr(&provider.traits)), size = u32(provider.traits_size), kind = DATA_PROVIDER_METADATA}
}

@(private)
etw_event_data :: #force_inline proc "contextless" (e: ^Etw_Event) -> Event_Data_Descriptor {
	return {ptr = u64(uintptr(&e.meta)), size = u32(e.size), kind = DATA_EVENT_METADATA}
}

@(private)
etw_write :: proc "contextless" (opcode: Opcode, keyword: u64, data: []Event_Data_Descriptor) {
	d := Event_Descriptor{channel = CHANNEL_TRACELOGGING, level = LEVEL_VERBOSE, opcode = u8(opcode), keyword = keyword}
	EventWriteTransfer(provider.handle, &d, nil, nil, u32(len(data)), raw_data(data))
}

}
