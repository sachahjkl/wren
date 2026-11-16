package page

import "core:testing"
import "wb:dom"

// An Event of the engine carries its wrapper's address in the memory of the instance that made it. An isolated world of
// content scripts is another instance on the same page: its listeners get no address, else they write the event's
// handle at that address in their own memory (the page's cells were broken so, and its engine stopped in a collection).
@(test)
an_engine_event_id_goes_only_to_the_instance_that_made_it :: proc(t: ^testing.T) {
	p := new(Page)
	defer free(p)
	ADDRESS :: 0x73d038
	ev := dom.Event{type = "message", engine_id = ADDRESS, engine_realm = page_id(p), engine_owner = 1}
	c := Call{page = p, caller = p, owner = 1}
	testing.expect_value(t, Event_engineId(&c, Api_Event{data = &ev}), i64(ADDRESS))
	c.owner = 0
	testing.expect_value(t, Event_engineId(&c, Api_Event{data = &ev}), i64(0))
}
