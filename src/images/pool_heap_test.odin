package images

import "core:sync"
import "core:testing"
import "wb:base"

@(test)
decoder_heap_priority_reprioritize_and_remove :: proc(t: ^testing.T) {
	d: Decoder
	d.queue = make([dynamic]^Job)
	defer {
		for j in d.queue { free(j) }
		delete(d.queue)
	}

	make_stub :: proc(prio: i32, seq: u64, tag: u64) -> ^Job {
		j := new(Job)
		j.priority = prio
		j.seq = seq
		j.tag = tag
		j.state = .Queued
		j.heap_idx = -1
		return j
	}

	// Push mixed priorities and ties (same priority must pop in ascending seq order)
	jobs := [?]^Job{
		make_stub(10, 1, 101),
		make_stub(50, 2, 501),
		make_stub(50, 3, 502),
		make_stub(30, 4, 301),
		make_stub(50, 5, 503),
		make_stub(5, 6, 51),
		make_stub(30, 7, 302),
	}
	for j in jobs { queue_push(&d, j) }
	testing.expect_value(t, len(d.queue), len(jobs))

	// Promote lowest job (tag 51) to highest priority (100)
	jobs[5].priority = 100
	queue_sift_up(&d, int(jobs[5].heap_idx))
	queue_sift_down(&d, int(jobs[5].heap_idx))

	// Demote 501 from 50 to 20
	jobs[1].priority = 20
	queue_sift_up(&d, int(jobs[1].heap_idx))
	queue_sift_down(&d, int(jobs[1].heap_idx))

	// Remove interior job 301
	removed := queue_remove_at(&d, int(jobs[3].heap_idx))
	testing.expect_value(t, removed.tag, u64(301))
	testing.expect_value(t, removed.heap_idx, i32(-1))
	free(removed)

	// Expected pop order: 51 (prio 100), 502 (50, seq 3), 503 (50, seq 5), 302 (30, seq 7), 501 (20, seq 2), 101 (10, seq 1)
	want := []u64{51, 502, 503, 302, 501, 101}
	for w in want {
		testing.expect(t, len(d.queue) > 0, "queue not empty")
		got := queue_pop(&d)
		testing.expect_value(t, got.tag, w)
		testing.expect_value(t, got.heap_idx, i32(-1))
		free(got)
	}
	testing.expect_value(t, len(d.queue), 0)
}

@(test)
port_drain_handles_cancel_port_open_growth_and_close :: proc(t: ^testing.T) {
	decoder_start(1)
	defer decoder_stop()
	decoder_hold(true)
	defer decoder_hold(false)

	Ctx :: struct {
		port:        Port_Id,
		cancel_id:   Job_Id,
		delivered:   [dynamic]u64,
		extra_ports: [dynamic]Port_Id,
	}
	ctx := Ctx{
		delivered   = make([dynamic]u64),
		extra_ports = make([dynamic]Port_Id),
	}
	defer {
		for ep in ctx.extra_ports { port_close(ep) }
		delete(ctx.extra_ports)
		delete(ctx.delivered)
	}

	on_done :: proc(user: rawptr, j: ^Job) {
		c := (^Ctx)(user)
		append(&c.delivered, j.tag)
		tag := j.tag
		job_free(j)
		if tag == 1 {
			// Cancel a later job already swapped into this drain batch and force d.ports reallocation
			job_cancel(c.cancel_id)
			for _ in 0 ..< 64 {
				append(&c.extra_ports, port_open(nil, nil, nil))
			}
		} else if tag == 3 {
			// Close the draining port while one more job remains in the batch
			port_close(c.port)
		}
	}

	pid := port_open(nil, on_done, rawptr(&ctx))
	ctx.port = pid
	testing.expect(t, pid != 0, "port opened")

	// Queue 4 finished jobs directly on p.done to exercise port_drain deterministically
	d := dec
	sync.mutex_lock(&d.mu)
	p := base.pool_get(&d.ports, base.Handle(pid))
	testing.expect(t, p != nil, "port present")
	ids: [4]Job_Id
	for i in 0 ..< 4 {
		j := job_make(.Decode, nil, {}, 0, nil, u64(i + 1))
		d.seq += 1
		j.seq = d.seq
		j.id = Job_Id(d.seq)
		j.port = pid
		j.state = .Finished
		ids[i] = j.id
		d.live[j.id] = j
		append(&p.done, j)
	}
	p.posted = true
	sync.mutex_unlock(&d.mu)

	ctx.cancel_id = ids[1]   // tag 2
	port_drain(rawptr(uintptr(pid)))

	// tag 1 delivered, tag 2 skipped (cancelled in batch), tag 3 delivered (closes port), tag 4 freed (not delivered)
	testing.expect_value(t, len(ctx.delivered), 2)
	if len(ctx.delivered) == 2 {
		testing.expect_value(t, ctx.delivered[0], u64(1))
		testing.expect_value(t, ctx.delivered[1], u64(3))
	}
	sync.mutex_lock(&d.mu)
	drains_left := len(d.drains)
	sync.mutex_unlock(&d.mu)
	testing.expect_value(t, drains_left, 0)
}
