package page

import "base:runtime"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:host"

// PointerEvent.prototype.getCoalescedEvents() and PointerEventInit.coalescedEvents (W3C Pointer Events Level 3).
@(test)
pointer_event_get_coalesced_events :: proc(t: ^testing.T) {
	test_pages(t)
	context.allocator = runtime.heap_allocator()
	register_imports()
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	loader := fetch.Loader{loop = &loop}
	settings := settings_default()
	defer settings_destroy(&settings)
	settings.threads.parse_html = false
	scope := base.scope_make("test")
	defer base.scope_close(scope)

	logs: [dynamic]string
	defer { for s in logs { delete(s) }; delete(logs) }
	on_log :: proc(user: rawptr, _: Log_Level, msg: string) { append((^[dynamic]string)(user), strings.clone(msg)) }

	p := page_create(&loop, &loader, &settings, scope, "https://example.test/pointer.html", on_log, rawptr(&logs))
	defer page_close(p)
	load_html(p, transmute([]byte)string(`<!doctype html><body><div id="pad"></div></body>`))
	pad := dom.find_by_id(p.doc, "pad")
	testing.expect(t, pad != base.NIL_HANDLE, "pad exists")

	// 1. Prototype presence, constructor coalescedEvents, validation, and fresh-array semantics.
	st := js_run(p, transmute([]byte)string(`(() => {
		const fails = [];
		const ok = (cond, msg) => { if (!cond) fails.push(msg); };

		ok(typeof PointerEvent.prototype.getCoalescedEvents === "function", "prototype method exists");
		ok(PointerEvent.prototype.getCoalescedEvents.length === 0, "method length is 0");

		// Illegal invocation throws TypeError.
		let threw = false;
		try { PointerEvent.prototype.getCoalescedEvents.call({}); } catch (e) { threw = e instanceof TypeError; }
		ok(threw, "illegal this throws TypeError");

		// Synthetic event without coalescedEvents returns fresh empty array.
		const plain = new PointerEvent("pointermove", { clientX: 5, clientY: 6 });
		const a0 = plain.getCoalescedEvents();
		const a1 = plain.getCoalescedEvents();
		ok(Array.isArray(a0) && a0.length === 0, "synthetic default is empty");
		ok(a0 !== a1, "returns fresh array each call");

		// Constructor coalescedEvents copies sequence and preserves exact PointerEvent items.
		const s1 = new PointerEvent("pointermove", { clientX: 1, clientY: 2 });
		const s2 = new PointerEvent("pointermove", { clientX: 3, clientY: 4 });
		const src = [s1, s2];
		const synth = new PointerEvent("pointermove", { coalescedEvents: src });
		src.push(new PointerEvent("pointermove"));
		const got = synth.getCoalescedEvents();
		ok(got.length === 2 && got[0] === s1 && got[1] === s2, "constructor sequence preserved");
		got.pop();
		ok(synth.getCoalescedEvents().length === 2, "mutating returned array does not mutate event");

		// Invalid coalescedEvents throws TypeError.
		let badItem = false;
		try { new PointerEvent("pointermove", { coalescedEvents: [{}] }); } catch (e) { badItem = e instanceof TypeError; }
		ok(badItem, "non-PointerEvent item throws TypeError");
		let badSeq = false;
		try { new PointerEvent("pointermove", { coalescedEvents: 42 }); } catch (e) { badSeq = e instanceof TypeError; }
		ok(badSeq, "non-iterable coalescedEvents throws TypeError");

		// Listeners for browser-dispatched trusted pointer events.
		window._single = null;
		window._multi = null;
		window._down = null;
		const pad = document.getElementById("pad");
		pad.addEventListener("pointermove", (e) => {
			if (window._mode === "single") {
				window._single = e;
			} else if (window._mode === "multi") {
				window._multi = e;
			}
		});
		pad.addEventListener("pointerdown", (e) => {
			window._down = e;
		});
		document.body.dataset.ctor = fails.length === 0 ? "ok" : fails.join("; ");
	})();`), "pointer_ctor.js")
	testing.expectf(t, st == .Ok, "st=%v logs=%v", st, logs[:])
	ctor_res, _ := dom.get_attribute(p.doc, p.body, "data-ctor")
	testing.expect_value(t, ctor_res, "ok")

	// 2. Trusted pointermove with no extra coalesced samples -> 1-element array matching event state.
	_ = js_run(p, transmute([]byte)string(`window._mode = "single";`), "m1.js")
	dispatch_event(p, pad, dom.Event{type = "pointermove", bubbles = true, cancelable = true, x = 42, y = 84, buttons = 1})

	// 3. Trusted pointermove with 3 recorded coalesced samples -> 3-element array in order.
	_ = js_run(p, transmute([]byte)string(`window._mode = "multi";`), "m2.js")
	samples := []Pointer_Sample{
		{x = 10, y = 20, buttons = 1, time_stamp = 100},
		{x = 15, y = 25, buttons = 1, time_stamp = 104},
		{x = 30, y = 40, buttons = 1, time_stamp = 108},
	}
	pointer_dispatch_move(p, pad, dom.Event{type = "pointermove", bubbles = true, cancelable = true, x = 30, y = 40, buttons = 1, time_stamp = 108}, samples)

	// 4. Trusted pointerdown -> empty coalesced list per spec.
	dispatch_event(p, pad, dom.Event{type = "pointerdown", bubbles = true, cancelable = true, x = 30, y = 40, buttons = 1})

	st2 := js_run(p, transmute([]byte)string(`(() => {
		const fails = [];
		const ok = (cond, msg) => { if (!cond) fails.push(msg); };
		const pad = document.getElementById("pad");

		const s = window._single;
		ok(s instanceof PointerEvent, "single is PointerEvent");
		const sc = s.getCoalescedEvents();
		ok(sc.length === 1, "single trusted pointermove has 1 coalesced event (got " + sc.length + ")");
		if (sc.length === 1) {
			const c = sc[0];
			ok(c instanceof PointerEvent, "coalesced item is PointerEvent");
			ok(c.type === "pointermove", "type matches");
			ok(c.isTrusted === true, "coalesced item isTrusted");
			ok(c.bubbles === false && c.cancelable === false && c.composed === false, "coalesced item non-bubbling/cancelable/composed");
			ok(c.target === pad, "coalesced item target matches");
			ok(c.clientX === 42 && c.clientY === 84, "coalesced coords match");
			ok(c.buttons === 1 && c.pressure === 0.5, "coalesced buttons/pressure match");
			ok(c.pointerId === 1 && c.pointerType === "mouse" && c.isPrimary === true, "coalesced pointer attrs match");
			ok(c.getCoalescedEvents().length === 0, "coalesced item has empty coalesced list");
		}

		const m = window._multi;
		const mc = m.getCoalescedEvents();
		ok(mc.length === 3, "multi trusted pointermove has 3 coalesced events (got " + mc.length + ")");
		if (mc.length === 3) {
			ok(mc[0].clientX === 10 && mc[0].clientY === 20 && mc[0].timeStamp === 100, "sample 0 matches");
			ok(mc[1].clientX === 15 && mc[1].clientY === 25 && mc[1].timeStamp === 104, "sample 1 matches");
			ok(mc[2].clientX === 30 && mc[2].clientY === 40 && mc[2].timeStamp === 108, "sample 2 matches");
			ok(mc[0].target === pad && mc[2].target === pad, "multi sample targets match");
			ok(mc[0].isTrusted === true && mc[0].bubbles === false, "multi sample flags match");
		}

		const d = window._down;
		ok(d instanceof PointerEvent, "down is PointerEvent");
		ok(d.getCoalescedEvents().length === 0, "pointerdown has 0 coalesced events");

		document.body.dataset.dispatch = fails.length === 0 ? "ok" : fails.join("; ");
	})();`), "pointer_dispatch.js")
	testing.expectf(t, st2 == .Ok, "st2=%v logs=%v", st2, logs[:])
	disp_res, _ := dom.get_attribute(p.doc, p.body, "data-dispatch")
	testing.expect_value(t, disp_res, "ok")
}
