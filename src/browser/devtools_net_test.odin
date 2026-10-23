package browser

import "core:testing"

@(test)
net_profiles_roundtrip :: proc(t: ^testing.T) {
	defer net_profiles_destroy()
	net_profiles_load("c_a|My A|1000|500|80|2;c_b|B|0|0|0|0;;bad|x")
	a, ok := net_profile_find("c_a")
	testing.expect(t, ok && a.name == "My A" && a.down_kbps == 1000 && a.up_kbps == 500 && a.latency_ms == 80 && a.loss_pct == 2, "a custom profile is read")
	_, bad := net_profile_find("bad")
	testing.expect(t, !bad, "a short item is skipped")
	testing.expect_value(t, net_profiles_text(), "c_a|My A|1000|500|80|2;c_b|B|0|0|0|0")
	f, fok := net_profile_find("fast_3g")
	testing.expect(t, fok && f.builtin && f.down_kbps == 1600 && f.latency_ms == 150, "Fast 3G")
	s, _ := net_profile_find("slow_3g")
	testing.expect(t, s.down_kbps == 400 && s.up_kbps == 400 && s.latency_ms == 400, "Slow 3G")
	o, _ := net_profile_find("offline")
	testing.expect(t, o.offline && net_profile_active(o), "Offline holds everything")
	n, _ := net_profile_find("none")
	testing.expect(t, !net_profile_active(n), "no throttling")
	_, missing := net_profile_find("nope")
	testing.expect(t, !missing)
}

@(test)
net_messages_are_kept_by_kind :: proc(t: ^testing.T) {
	e: Net_Entry
	defer net_free_entry(&e)
	net_msg_push(&e, 100, true, false, false, transmute([]byte)string("hello"), "", "")
	net_msg_push(&e, 150, false, true, false, []byte{1, 2, 250}, "", "")
	net_msg_push(&e, 200, false, false, true, nil, "close 1000 done", "")
	net_msg_push(&e, 250, false, false, false, transmute([]byte)string("data"), "tick", "42")
	testing.expect_value(t, len(e.msgs), 4)
	testing.expect_value(t, e.msgs_total, 4)
	testing.expect(t, e.msgs[0].out && e.msgs[0].text == "hello" && e.msgs[0].size == 5, "a sent text message")
	testing.expect(t, e.msgs[1].binary && e.msgs[1].text == "01 02 fa" && e.msgs[1].size == 3, "a binary message is shown as hex")
	testing.expect(t, e.msgs[2].control && e.msgs[2].name == "close 1000 done", "a close frame")
	testing.expect(t, e.msgs[3].name == "tick" && e.msgs[3].id == "42", "an event of a stream")
	testing.expect(t, e.msgs[1].at == 150 - 0, "time since the request began")
}

@(test)
net_messages_are_bounded :: proc(t: ^testing.T) {
	e: Net_Entry
	defer net_free_entry(&e)
	for i in 0 ..< NET_MSG_KEEP + 5 { net_msg_push(&e, f64(i), false, false, false, transmute([]byte)string("x"), "", "") }
	testing.expect(t, len(e.msgs) <= NET_MSG_KEEP, "the oldest go first")
	testing.expect_value(t, e.msgs_total, NET_MSG_KEEP + 5)
	big := make([]byte, NET_MSG_TEXT * 2)
	defer delete(big)
	for &b in big { b = 'a' }
	net_msg_push(&e, 1, false, false, false, big, "", "")
	last := e.msgs[len(e.msgs) - 1]
	testing.expect(t, last.size == len(big) && len(last.text) == NET_MSG_TEXT, "a long text keeps its start and its size")
}
