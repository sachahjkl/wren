//! The GPU process: the channel on its own, then a real child on the software adapter that is killed, hung and made hostile. Each
//! end-to-end test has a Gpu of its own, so that what it kills is only its own. A machine without an adapter skips those.

use crate::gl::Reply;
use crate::ipc::{self, sys, test_kind as k, FrameView, Head, IpcError, Ring, RingReader, RingWriter};
use crate::parent::{End, Gpu, Handle};
use crate::*;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const SMALL_RING: u64 = 4096;
const LONG_ENOUGH: Duration = Duration::from_secs(60);
/// Streams of hostile commands: each that loses its context costs a new device, seconds on a software adapter.
const HOSTILE_ROUNDS: u32 = 60;

fn ring_mem() -> Vec<u64> {
    vec![0u64; (4096 + SMALL_RING as usize) / 8 + 1]
}

// ---- the wire ----

#[test]
fn a_head_says_what_it_said() {
    let h = Head { kind: 7, ctx: 0xABCD, arg: u64::MAX - 1, len: 1 << 40 };
    assert_eq!(Head::of_bytes(&h.to_bytes()), h);
}

#[test]
fn rows_that_make_no_sense_are_refused() {
    assert_eq!(ipc::rows_end(0, 4, 8, 8), Some(12));
    assert_eq!(ipc::rows_end(8, 4, 4, 4), Some(12));
    assert_eq!(ipc::rows_end(u64::MAX - 2, 4, 4, 8), None, "past the end of the address space");
    assert_eq!(ipc::rows_end(0, u64::MAX, u64::MAX, u64::MAX), Some(u64::MAX), "one row: its own length");
    assert_eq!(ipc::rows_end(0, 4, 2, 8), None, "rows on top of each other");
    assert_eq!(ipc::rows_end(0, 3, 4, 8), None, "not a whole number of rows");
    assert_eq!(ipc::rows_end(0, 0, 0, 8), None, "data with no rows");
    assert_eq!(ipc::rows_end(0, 4, u64::MAX, 12), None, "a stride that overflows");
}

#[test]
fn a_frame_section_has_a_size_or_none() {
    assert_eq!(ipc::frame_section_bytes(2, 3), Some(4096 + 2 * 3 * 4 * ipc::FRAME_SLOTS as u64));
    assert_eq!(ipc::frame_section_bytes(u32::MAX, u32::MAX), None);
}

#[test]
fn attributes_that_cannot_be_are_refused() {
    let good = crate::parent::wire_attrs(&test_attrs(10, 20));
    let a = child::attrs_of(&good).expect("good attributes");
    assert_eq!((a.width, a.height, a.webgl2), (10, 20, 0));
    assert!(child::attrs_of(&good[..good.len() - 1]).is_none(), "cut short");
    let mut more = good.clone();
    more.push(0);
    assert!(child::attrs_of(&more).is_none(), "too long");
    let mut bad = test_attrs(10, 20);
    bad.backend = 77;
    assert!(child::attrs_of(&crate::parent::wire_attrs(&bad)).is_none(), "no such backend");
    let mut bad = test_attrs(10, 20);
    bad.max_dimension = 0;
    assert!(child::attrs_of(&crate::parent::wire_attrs(&bad)).is_none(), "no dimension");
    let mut bad = test_attrs(1 << 30, 20);
    bad.max_dimension = 16;
    assert!(child::attrs_of(&crate::parent::wire_attrs(&bad)).is_none(), "a side no GPU has");
}

// ---- the ring ----

#[test]
fn more_than_a_ring_goes_through_a_ring_in_order() {
    let mut mem = ring_mem();
    let ring = unsafe { Ring::on(mem.as_mut_ptr() as *mut u8, SMALL_RING) };
    let (writer_bell, reader_bell) = sys::test_bell_pair();
    const TOTAL: usize = 1 << 22;
    let sender = std::thread::spawn(move || {
        let mut w = RingWriter::new(ring);
        let data: Vec<u8> = (0..TOTAL).map(|i| (i % 251) as u8).collect();
        for chunk in data.chunks(10_007) {
            w.write(chunk, &writer_bell, &|| false, Some(Instant::now() + LONG_ENOUGH)).unwrap();
        }
    });
    let mut r = RingReader::new(ring);
    let mut got = vec![0u8; TOTAL];
    r.read(&mut got, &reader_bell).unwrap();
    sender.join().unwrap();
    assert!(got.iter().enumerate().all(|(i, b)| *b == (i % 251) as u8));
}

#[test]
fn an_index_that_cannot_be_is_corruption_on_both_ends() {
    let mut mem = ring_mem();
    let ring = unsafe { Ring::on(mem.as_mut_ptr() as *mut u8, SMALL_RING) };
    let (a, b) = sys::test_bell_pair();
    let mut w = RingWriter::new(ring);
    w.test_corrupt();
    let mut r = RingReader::new(ring);
    let mut out = [0u8; 4];
    assert_eq!(r.read(&mut out, &b), Err(IpcError::Corrupt), "a write index past the capacity");

    let mut mem = ring_mem();
    let ring = unsafe { Ring::on(mem.as_mut_ptr() as *mut u8, SMALL_RING) };
    // (the second u64 of the head's second line: the read index, ahead of what was ever written)
    mem[8] = 1 << 40;
    let mut w = RingWriter::new(ring);
    assert_eq!(w.write(&[1, 2, 3], &a, &|| false, None), Err(IpcError::Corrupt), "a read index past what was written");
}

#[test]
fn a_full_ring_nobody_reads_has_a_deadline() {
    let mut mem = ring_mem();
    let ring = unsafe { Ring::on(mem.as_mut_ptr() as *mut u8, SMALL_RING) };
    let (a, _b) = sys::test_bell_pair();
    let mut w = RingWriter::new(ring);
    let data = vec![0u8; SMALL_RING as usize + 1];
    let t = Instant::now();
    assert_eq!(w.write(&data, &a, &|| false, Some(t + Duration::from_millis(50))), Err(IpcError::Stuck));
    assert_eq!(RingWriter::new(ring).write(&data, &a, &|| true, None), Err(IpcError::Gone), "the other side ended");
}

// ---- frames ----

fn frame_section(w: u32, h: u32) -> (sys::Section, FrameView, FrameView) {
    let bytes = ipc::frame_section_bytes(w, h).unwrap();
    let s = sys::Section::create(bytes).unwrap();
    let mut parent = unsafe { FrameView::new(s.base(), bytes, w, h, false).unwrap() };
    parent.reset(false);
    let child = unsafe { FrameView::new(s.base(), bytes, w, h, true).unwrap() };
    (s, parent, child)
}

#[test]
fn frames_go_through_the_section_newest_first() {
    let (_s, mut parent, mut child) = frame_section(2, 2);
    let mut dst = [0u8; 16];
    assert_eq!(unsafe { parent.take(dst.as_mut_ptr(), 2, 2, 8) }, Ok(None), "nothing yet");
    for fill in [1u8, 2, 3] {
        let p = child.fill(2, 2).unwrap();
        unsafe { std::ptr::write_bytes(p, fill, 16) };
        child.publish(2, 2, fill == 3);
    }
    assert_eq!(unsafe { parent.take(dst.as_mut_ptr(), 2, 2, 8) }, Ok(Some(true)));
    assert_eq!(dst, [3u8; 16], "the newest");
    assert_eq!(unsafe { parent.take(dst.as_mut_ptr(), 2, 2, 8) }, Ok(None), "taken once");
    // the slots keep circulating, the parent's never written
    for fill in [4u8, 5] {
        let p = child.fill(2, 2).unwrap();
        unsafe { std::ptr::write_bytes(p, fill, 16) };
        child.publish(2, 2, false);
        assert_eq!(unsafe { parent.take(dst.as_mut_ptr(), 2, 2, 8) }, Ok(Some(false)));
        assert_eq!(dst, [fill; 16]);
    }
}

#[test]
fn a_frame_that_does_not_fit_stays_out() {
    let (_s, _parent, mut child) = frame_section(2, 2);
    assert!(child.fill(3, 2).is_none());
    assert!(child.fill(2, 3).is_none());
    assert!(child.fill(1, 1).is_some(), "smaller fits");
}

#[test]
fn a_child_cannot_make_the_parent_read_outside_its_section() {
    let (_s, mut parent, _child) = frame_section(4, 4);
    let mut dst = [0u8; 64];
    // a slot that does not exist
    parent.test_scribble(ipc::SLOT_NEW | 7, 4, 4);
    assert_eq!(unsafe { parent.take(dst.as_mut_ptr(), 4, 4, 16) }, Err(IpcError::Corrupt));
    // a picture larger than the section's pictures
    let (_s, mut parent, _child) = frame_section(4, 4);
    parent.test_scribble(ipc::SLOT_NEW | 1, 5000, 5000);
    assert_eq!(unsafe { parent.take(dst.as_mut_ptr(), 4, 4, 16) }, Err(IpcError::Corrupt));
    // a picture of another size than the bitmap's: nothing is copied
    let (_s, mut parent, _child) = frame_section(4, 4);
    parent.test_scribble(ipc::SLOT_NEW | 1, 2, 2);
    assert_eq!(unsafe { parent.take(dst.as_mut_ptr(), 4, 4, 16) }, Ok(None));
    assert_eq!(dst, [0u8; 64]);
}

// ---- a real child ----

fn test_attrs(w: u32, h: u32) -> WgAttrs {
    WgAttrs {
        webgl2: 0,
        alpha: 1,
        depth: 0,
        stencil: 0,
        antialias: 0,
        premultiplied: 1,
        preserve: 0,
        fail_if_major_performance_caveat: 0,
        width: w,
        height: h,
        max_dimension: 16384,
        allow_software: 1,
        force_software: 1,
        backend: BACKEND_AUTO,
        max_bytes: 1 << 28,
        wait_ms: 60_000,
        hang_ms: 120_000,
        max_restarts: 8,
        restart_window_ms: 60_000,
        idle_exit_ms: 0,
        keep_rights: 0,
        notify: None,
        notify_user: std::ptr::null_mut(),
    }
}

fn private_gpu() -> &'static Gpu {
    let g: &'static Gpu = Box::leak(Box::new(Gpu::new()));
    g.enable_hooks();
    g
}

struct Ctx {
    h: *mut Handle,
    notified: Arc<AtomicUsize>,
}

extern "C" fn count_notify(user: *mut std::ffi::c_void) {
    unsafe { (*(user as *const AtomicUsize)).fetch_add(1, Ordering::SeqCst) };
}

fn make(gpu: &'static Gpu, mut a: WgAttrs) -> Result<Ctx, String> {
    let notified = Arc::new(AtomicUsize::new(0));
    a.notify = Some(count_notify);
    a.notify_user = Arc::as_ptr(&notified) as *mut std::ffi::c_void;
    let mut info = WgInfo::default();
    let mut err = [0u8; 512];
    let mut n = 0usize;
    let h = unsafe { create_on(gpu, &a, &mut info, err.as_mut_ptr() as *mut _, err.len(), &mut n) };
    if h.is_null() {
        return Err(String::from_utf8_lossy(&err[..n]).into_owned());
    }
    Ok(Ctx { h, notified })
}

/// A context, or None on a machine with no adapter at all: then the test has nothing to show.
fn context_or_skip(gpu: &'static Gpu, a: WgAttrs) -> Option<Ctx> {
    match make(gpu, a) {
        Ok(c) => Some(c),
        Err(e) => {
            eprintln!("skipped: {e}");
            assert!(e.contains("adapter") || e.contains("software"), "{e}");
            None
        }
    }
}

impl Ctx {
    /// A shorter deadline than the one the device was made under, which a loaded machine needs.
    fn set_wait(&mut self, d: Duration) {
        unsafe { (*self.h).test_set_wait(d) };
    }
    fn handle(&self) -> &Handle {
        unsafe { &*self.h }
    }
    fn lost(&self) -> bool {
        unsafe { wg_is_lost(self.h) != 0 }
    }
    fn clear(&self, r: f32, g: f32, b: f32) {
        let mut w = Vec::new();
        for v in [ops::CLEAR_COLOR, r.to_bits(), g.to_bits(), b.to_bits(), 1f32.to_bits(), ops::CLEAR, 0x4000] {
            w.extend_from_slice(&v.to_ne_bytes());
        }
        unsafe { wg_submit(self.h, w.as_ptr(), w.len(), std::ptr::null(), 0) };
    }
    fn pixel(&self) -> Option<[u8; 4]> {
        let mut q = Vec::new();
        for v in [ops::Q_READ_PIXELS, 0, 0, 1, 1, formats::RGBA, formats::UNSIGNED_BYTE, 4, 0] {
            q.extend_from_slice(&(v as u32).to_ne_bytes());
        }
        let mut out = [0u8; 4];
        let n = unsafe { wg_query(self.h, q.as_ptr(), q.len(), out.as_mut_ptr(), 4) };
        if n < 0 {
            None
        } else {
            Some(out)
        }
    }
    fn draws_and_reads(&self) -> bool {
        self.clear(0.0, 1.0, 0.0);
        self.pixel() == Some([0, 255, 0, 255])
    }
    fn console(&self) -> String {
        let mut text = String::new();
        let mut buf = [0u8; 1024];
        loop {
            let n = unsafe { wg_console(self.h, buf.as_mut_ptr(), buf.len()) };
            if n == 0 {
                return text;
            }
            text.push_str(&String::from_utf8_lossy(&buf[..n]));
            text.push('\n');
        }
    }
}

impl Drop for Ctx {
    fn drop(&mut self) {
        unsafe { wg_destroy(self.h) };
    }
}

fn wait_for(limit: Duration, what: &str, mut f: impl FnMut() -> bool) {
    let until = Instant::now() + limit;
    while !f() {
        assert!(Instant::now() < until, "waited too long for: {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn one_process_for_many_contexts_with_its_rights_lowered() {
    let gpu = private_gpu();
    let Some(a) = context_or_skip(gpu, test_attrs(8, 8)) else { return };
    let b = make(gpu, test_attrs(8, 8)).unwrap();
    assert_eq!(gpu.starts(), 1);
    let p = gpu.current().unwrap();
    assert_ne!(p.pid(), std::process::id());
    let lowered = p.lowered();
    #[cfg(windows)]
    for what in ["dll-search", "privileges", "low-integrity"] {
        assert!(lowered.contains(what), "{what} is not in {lowered}");
    }
    #[cfg(unix)]
    assert!(lowered.contains("no-new-privs"), "{lowered}");
    assert!(a.draws_and_reads());
    b.clear(0.0, 0.0, 1.0);
    assert_eq!(b.pixel(), Some([0, 0, 255, 255]), "each has its own");
    assert!(a.draws_and_reads());
    unsafe { wg_present(a.h) };
    let mut bitmap = [0u8; 8 * 8 * 4];
    wait_for(LONG_ENOUGH, "a frame", || unsafe { wg_take_frame(a.h, bitmap.as_mut_ptr(), 8, 8, 32) != FRAME_NONE });
    assert_eq!(&bitmap[..4], &[0, 255, 0, 255], "the frame came through the section");
}

#[test]
fn killed_while_drawing_every_context_is_lost_and_another_process_takes_over() {
    let gpu = private_gpu();
    let Some(a) = context_or_skip(gpu, test_attrs(32, 32)) else { return };
    let b = make(gpu, test_attrs(32, 32)).unwrap();
    assert!(a.draws_and_reads());
    let first = gpu.current().unwrap();
    let pid = first.pid();
    let killer = std::thread::spawn({
        let first = first.clone();
        move || {
            std::thread::sleep(Duration::from_millis(30));
            first.kill_for_test();
        }
    });
    // drawing goes on until the process is gone; nothing here may fail or block past its deadline
    let until = Instant::now() + LONG_ENOUGH;
    while !a.lost() && Instant::now() < until {
        a.clear(1.0, 0.0, 0.0);
        unsafe { wg_present(a.h) };
        let _ = a.pixel();
    }
    killer.join().unwrap();
    assert!(a.lost(), "the drawing context");
    wait_for(LONG_ENOUGH, "the other context", || b.lost());
    assert!(a.notified.load(Ordering::SeqCst) > 0 && b.notified.load(Ordering::SeqCst) > 0, "the browser was told");
    assert_eq!(a.pixel(), None, "a lost context answers nothing");
    wait_for(LONG_ENOUGH, "the process's end", || !sys::test_pid_alive(pid));
    assert_eq!(first.end(), Some(End::Crashed));
    assert!(a.console().contains("GPU process"), "the page's console says why");
    // a new context and a restored one, in a new process
    assert_eq!(unsafe { wg_restore(a.h) }, 1, "restored");
    assert!(!a.lost());
    assert!(a.draws_and_reads());
    let second = gpu.current().unwrap();
    assert_ne!(second.pid(), pid);
    assert_eq!(gpu.starts(), 2);
    assert_eq!(unsafe { wg_restore(b.h) }, 1);
    assert!(b.draws_and_reads());
    assert_eq!(gpu.starts(), 2, "the same new process");
    // frames still come, through a section the new process was told of
    unsafe { wg_present(a.h) };
    let mut bitmap = [0u8; 32 * 32 * 4];
    wait_for(LONG_ENOUGH, "a frame after the restart", || unsafe { wg_take_frame(a.h, bitmap.as_mut_ptr(), 32, 32, 128) != FRAME_NONE });
    assert_eq!(&bitmap[..4], &[0, 255, 0, 255]);
}

#[test]
fn a_crash_inside_the_child_loses_contexts_and_nothing_else() {
    let gpu = private_gpu();
    let Some(a) = context_or_skip(gpu, test_attrs(8, 8)) else { return };
    assert!(a.draws_and_reads());
    assert!(parent::test_hook(a.handle(), k::CRASH));
    wait_for(LONG_ENOUGH, "the context lost", || a.lost());
    assert_eq!(unsafe { wg_restore(a.h) }, 1);
    assert!(a.draws_and_reads());
}

#[test]
fn a_hung_context_is_lost_at_its_deadline_and_the_process_killed_soon_after() {
    let gpu = private_gpu();
    let attrs = test_attrs(8, 8);
    let Some(mut a) = context_or_skip(gpu, attrs) else { return };
    let other = make(gpu, attrs).unwrap();
    assert!(a.draws_and_reads());
    a.set_wait(Duration::from_millis(300));
    // (a software context is allowed twice that; a device takes longer than that to make, hence after)
    gpu.test_set_hang(Duration::from_millis(300));
    let first = gpu.current().unwrap();
    let pid = first.pid();
    assert!(parent::test_hook(a.handle(), k::HANG_CONTEXT));
    let t = Instant::now();
    assert_eq!(a.pixel(), None, "the question gets no answer");
    let waited = t.elapsed();
    assert!(waited >= Duration::from_millis(250) && waited < Duration::from_secs(20), "the deadline held: {waited:?}");
    assert!(a.lost());
    assert!(a.console().contains("did not answer"));
    wait_for(LONG_ENOUGH, "the hung process killed", || !sys::test_pid_alive(pid));
    assert_eq!(first.end(), Some(End::Hung));
    wait_for(LONG_ENOUGH, "every context told", || other.lost());
    gpu.test_set_hang(Duration::from_secs(120));
    a.set_wait(LONG_ENOUGH);
    assert_eq!(unsafe { wg_restore(a.h) }, 1, "a new process");
    assert!(a.draws_and_reads());
    assert_ne!(gpu.current().unwrap().pid(), pid);
}

#[test]
fn a_process_that_stops_reading_is_killed_and_pages_are_let_go() {
    let gpu = private_gpu();
    let Some(mut a) = context_or_skip(gpu, test_attrs(8, 8)) else { return };
    assert!(a.draws_and_reads());
    a.set_wait(Duration::from_millis(300));
    gpu.test_set_hang(Duration::from_millis(300));
    let first = gpu.current().unwrap();
    assert!(parent::test_hook(a.handle(), k::STALL_READER));
    // the ring fills: the page's thread stays within its deadline however much it sends
    let big = vec![0u8; 1 << 20];
    let t = Instant::now();
    for _ in 0..64 {
        unsafe { wg_submit(a.h, big.as_ptr(), big.len(), std::ptr::null(), 0) };
        if a.lost() {
            break;
        }
    }
    assert!(t.elapsed() < Duration::from_secs(20), "the sender was held for {:?}", t.elapsed());
    wait_for(LONG_ENOUGH, "the context lost", || a.lost());
    wait_for(LONG_ENOUGH, "the process's end", || first.is_dead());
    assert_eq!(first.end(), Some(End::Hung));
}

#[test]
fn the_limit_on_restarts_holds_and_time_lifts_it() {
    let gpu = private_gpu();
    let mut attrs = test_attrs(8, 8);
    attrs.max_restarts = 2;
    attrs.restart_window_ms = 20_000;
    let Some(mut a) = context_or_skip(gpu, attrs) else { return };
    for round in 0..3 {
        gpu.current().unwrap().kill_for_test();
        wait_for(LONG_ENOUGH, "the context lost", || a.lost());
        let restored = unsafe { wg_restore(a.h) };
        if round < 2 {
            assert_eq!(restored, 1, "round {round}");
            assert!(a.draws_and_reads());
        } else {
            assert_eq!(restored, 0, "past the limit");
        }
    }
    let refused = make(gpu, attrs).err().unwrap_or_default();
    assert!(refused.contains("webgl.gpu_max_restarts"), "{refused}");
    assert!(a.console().contains("webgl.gpu_max_restarts"));
    // the page's own world goes on: the time passes, and it may try again
    wait_for(Duration::from_secs(60), "the window to pass", || unsafe { wg_restore(a.h) } == 1);
    assert!(a.draws_and_reads());
    let again = make(gpu, attrs);
    assert!(again.is_ok());
    drop(again);
    a = make(gpu, attrs).unwrap();
    assert!(a.draws_and_reads());
}

#[test]
fn a_hostile_child_is_killed_and_the_parent_is_unharmed() {
    let gpu = private_gpu();
    let Some(_probe) = context_or_skip(gpu, test_attrs(8, 8)) else { return };
    let mut attrs = test_attrs(8, 8);
    attrs.max_restarts = 1000;
    for kind in [k::BAD_KIND, k::HUGE_LENGTH, k::BAD_CONTEXT, k::UNASKED_REPLY, k::TOO_MANY_DONE, k::CORRUPT_INDEX] {
        let a = make(gpu, attrs).unwrap();
        assert!(a.draws_and_reads(), "kind {kind}");
        let p = gpu.current().unwrap();
        assert!(parent::test_hook(a.handle(), kind));
        wait_for(LONG_ENOUGH, "the context lost", || a.lost());
        assert!(p.is_dead(), "kind {kind}");
        assert_eq!(p.end(), Some(End::Broke), "kind {kind}");
        wait_for(LONG_ENOUGH, "killed", || !sys::test_pid_alive(p.pid()));
    }
    // rows that end past any buffer, as the answer to a real question
    let a = make(gpu, attrs).unwrap();
    assert!(a.draws_and_reads());
    let p = gpu.current().unwrap();
    let (qid, _slot) = a.handle().test_ask().unwrap();
    a.handle().test_misbehave(k::BAD_ROWS, qid);
    wait_for(LONG_ENOUGH, "the context lost", || a.lost());
    assert_eq!(p.end(), Some(End::Broke));
    // a frame section with a word that cannot be: only when the browser takes the frame
    let a = make(gpu, attrs).unwrap();
    assert!(a.draws_and_reads());
    unsafe { wg_present(a.h) };
    let mut bitmap = [0u8; 8 * 8 * 4];
    wait_for(LONG_ENOUGH, "a frame", || unsafe { wg_take_frame(a.h, bitmap.as_mut_ptr(), 8, 8, 32) != FRAME_NONE });
    let p = gpu.current().unwrap();
    a.handle().test_frame_scribble(ipc::SLOT_NEW | 200, 8, 8);
    assert_eq!(unsafe { wg_take_frame(a.h, bitmap.as_mut_ptr(), 8, 8, 32) }, FRAME_NONE);
    assert!(a.lost());
    assert_eq!(p.end(), Some(End::Broke));
    // and after all that, the browser still draws
    let last = make(gpu, attrs).unwrap();
    assert!(last.draws_and_reads());
}

#[test]
fn a_broken_stream_ends_the_child_and_only_the_child() {
    let gpu = private_gpu();
    let Some(a) = context_or_skip(gpu, test_attrs(8, 8)) else { return };
    let mut attrs = test_attrs(8, 8);
    attrs.max_restarts = 1000;
    let garbage: [&[u8]; 3] = [
        // a kind that does not exist
        &Head { kind: 0xFFFF, ctx: 1, arg: 0, len: 0 }.to_bytes(),
        // a length past any limit
        &Head { kind: ipc::ToChild::Commands as u32, ctx: 1, arg: 0, len: u64::MAX }.to_bytes(),
        // a test hook of a child that was not... (this one has them: see below) a Resize with a length past its limit
        &Head { kind: ipc::ToChild::Resize as u32, ctx: 1, arg: 0, len: 4096 }.to_bytes(),
    ];
    let mut c = a;
    for bytes in garbage {
        let p = gpu.current().unwrap();
        assert!(c.handle().test_raw(bytes).is_ok());
        wait_for(LONG_ENOUGH, "the child's end", || !sys::test_pid_alive(p.pid()));
        wait_for(LONG_ENOUGH, "the context lost", || c.lost());
        c = make(gpu, attrs).unwrap();
        assert!(c.draws_and_reads(), "a new child draws");
    }
}

#[test]
fn a_child_without_the_hooks_takes_a_hook_for_a_broken_stream() {
    let gpu: &'static Gpu = Box::leak(Box::new(Gpu::new()));
    let Some(a) = context_or_skip(gpu, test_attrs(8, 8)) else { return };
    let p = gpu.current().unwrap();
    assert!(parent::test_hook(a.handle(), k::HANG_CONTEXT));
    wait_for(LONG_ENOUGH, "the child's end", || !sys::test_pid_alive(p.pid()));
    wait_for(LONG_ENOUGH, "the context lost", || a.lost());
}

#[test]
fn a_malformed_stream_loses_its_context_and_the_process_lives() {
    let gpu = private_gpu();
    let Some(a) = context_or_skip(gpu, test_attrs(16, 16)) else { return };
    let other = make(gpu, test_attrs(16, 16)).unwrap();
    let pid = gpu.current().unwrap().pid();
    let bytes: Vec<u8> = [0xFFFF_FFF0u32, 1, 2, 3].iter().flat_map(|w| w.to_ne_bytes()).collect();
    unsafe { wg_submit(a.h, bytes.as_ptr(), bytes.len(), std::ptr::null(), 0) };
    wait_for(LONG_ENOUGH, "the context lost", || a.lost());
    assert!(other.draws_and_reads(), "the other context goes on");
    assert_eq!(gpu.current().unwrap().pid(), pid);
    assert_eq!(unsafe { wg_restore(a.h) }, 1, "restored in the same process");
    assert!(a.draws_and_reads());
    assert_eq!(gpu.starts(), 1);
}

#[test]
fn hostile_commands_cost_contexts_or_a_process_and_never_the_browser() {
    let gpu = private_gpu();
    // (real operations with wild arguments can ask for a draw that lasts for ever: the short limits end it)
    let mut attrs = test_attrs(16, 16);
    attrs.max_restarts = 1000;
    let short = Duration::from_millis(1500);
    let Some(mut a) = context_or_skip(gpu, attrs) else { return };
    a.set_wait(short);
    gpu.test_set_hang(short);
    // a little generator: the same streams on every run
    let mut seed = 0x9E37_79B9_7F4A_7C15u64;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed
    };
    let mut lost = 0;
    for _round in 0..HOSTILE_ROUNDS {
        let n = (next() % 64) as usize + 1;
        let mut words: Vec<u32> = Vec::with_capacity(n);
        for i in 0..n {
            let v = next();
            words.push(match v % 4 {
                // an operation that exists gets past the first check
                0 if i == 0 => (v >> 8) as u32 % 110,
                0 => (v >> 8) as u32 % 16,
                1 => (v >> 8) as u32,
                2 => u32::MAX - (v >> 8) as u32 % 16,
                _ => 0,
            });
        }
        let bytes: Vec<u8> = words.iter().flat_map(|w| w.to_ne_bytes()).collect();
        unsafe { wg_submit(a.h, bytes.as_ptr(), bytes.len(), std::ptr::null(), 0) };
        // the question is hostile too
        let mut out = [0u8; 256];
        let _ = unsafe { wg_query(a.h, bytes.as_ptr(), bytes.len(), out.as_mut_ptr(), out.len()) };
        if a.lost() {
            lost += 1;
            a = make(gpu, attrs).unwrap();
            a.set_wait(short);
            gpu.test_set_hang(short);
        }
    }
    assert!(lost > 0, "a malformed stream loses a context");
    eprintln!("{lost} contexts lost, {} processes", gpu.starts());
    assert!(make(gpu, attrs).unwrap().draws_and_reads(), "and after all that it still draws");
}

#[test]
fn it_goes_when_nobody_needs_it_and_comes_back_when_somebody_does() {
    let gpu = private_gpu();
    let mut attrs = test_attrs(8, 8);
    attrs.idle_exit_ms = 150;
    let Some(a) = context_or_skip(gpu, attrs) else { return };
    let p = gpu.current().unwrap();
    assert!(a.draws_and_reads());
    drop(a);
    wait_for(LONG_ENOUGH, "the process's end", || !sys::test_pid_alive(p.pid()));
    assert_eq!(p.end(), Some(End::Asked), "no crash");
    let b = make(gpu, attrs).unwrap();
    assert!(b.draws_and_reads());
    assert_eq!(gpu.starts(), 2);
    drop(p);
}

#[test]
fn started_ahead_a_page_finds_its_process_and_device_ready() {
    let gpu = private_gpu();
    let attrs = test_attrs(8, 8);
    gpu.start_ahead(&attrs);
    wait_for(LONG_ENOUGH, "the process started ahead", || gpu.current().is_some());
    gpu.start_ahead(&attrs);
    let Some(a) = context_or_skip(gpu, attrs) else { return };
    assert_eq!(gpu.starts(), 1, "the context took the process started ahead, a second start ahead started nothing");
    assert!(a.draws_and_reads(), "the device made ahead draws");
    let b = make(gpu, attrs).unwrap();
    b.clear(0.0, 0.0, 1.0);
    assert_eq!(b.pixel(), Some([0, 0, 255, 255]), "and the next context has a device of its own");
    assert!(a.draws_and_reads());
    // a process that ended badly is started again by a page that asks, never ahead
    let p = gpu.current().unwrap();
    p.kill_for_test();
    wait_for(LONG_ENOUGH, "the end of the process", || gpu.current().is_none());
    gpu.start_ahead(&attrs);
    assert!(gpu.current().is_none() && gpu.starts() == 1, "nothing started ahead after a crash");
}

#[test]
fn a_process_started_ahead_for_nothing_is_not_started_ahead_again() {
    let gpu = private_gpu();
    let mut attrs = test_attrs(8, 8);
    attrs.idle_exit_ms = 150;
    gpu.start_ahead(&attrs);
    wait_for(LONG_ENOUGH, "the process started ahead", || gpu.current().is_some());
    let p = gpu.current().unwrap();
    wait_for(LONG_ENOUGH, "its end, with no context", || !sys::test_pid_alive(p.pid()));
    assert_eq!(p.end(), Some(End::Asked), "no crash");
    gpu.start_ahead(&attrs);
    assert!(gpu.current().is_none() && gpu.starts() == 1, "a browser that sees no WebGL starts no process ahead again");
    // a page that asks still gets its context
    let Some(a) = context_or_skip(gpu, attrs) else { return };
    assert!(a.draws_and_reads());
    assert_eq!(gpu.starts(), 2);
    drop(p);
}

/// The other half of the next test: a parent that starts a process, says its id in a file and waits to be killed.
#[test]
fn parent_for_the_death_test() {
    let Ok(path) = std::env::var("WREN_WEBGL_TEST_PARENT_FILE") else { return };
    let gpu = private_gpu();
    let a = make(gpu, test_attrs(8, 8)).expect("a context in the parent");
    assert!(a.draws_and_reads());
    let pid = gpu.current().unwrap().pid();
    std::fs::write(&path, pid.to_string()).unwrap();
    std::thread::sleep(Duration::from_secs(600));
}

#[test]
fn it_ends_with_its_parent_even_a_killed_one() {
    if make(private_gpu(), test_attrs(8, 8)).is_err() {
        return;
    }
    let file = std::env::temp_dir().join(format!("wren-webgl-parent-{}.txt", std::process::id()));
    let _ = std::fs::remove_file(&file);
    let exe = std::env::current_exe().unwrap();
    let mut parent = std::process::Command::new(exe).args(["ipc_tests::parent_for_the_death_test", "--exact", "--nocapture"]).env("WREN_WEBGL_TEST_PARENT_FILE", &file).spawn().unwrap();
    let mut pid = 0;
    wait_for(Duration::from_secs(120), "the parent's child", || {
        if let Ok(s) = std::fs::read_to_string(&file) {
            pid = s.trim().parse().unwrap_or(0);
        }
        pid != 0
    });
    let _ = std::fs::remove_file(&file);
    assert!(sys::test_pid_alive(pid));
    parent.kill().unwrap();
    let _ = parent.wait();
    wait_for(Duration::from_secs(20), "the child's end after its parent's", || !sys::test_pid_alive(pid));
}

#[test]
fn a_reply_that_is_not_kept_says_how_much_it_needs() {
    // (the path of readPixels into a buffer too small: nothing written, its length given)
    let gpu = private_gpu();
    let Some(a) = context_or_skip(gpu, test_attrs(8, 8)) else { return };
    assert!(a.draws_and_reads());
    let mut q = Vec::new();
    for v in [ops::Q_READ_PIXELS, 0, 0, 8, 8, formats::RGBA, formats::UNSIGNED_BYTE, 8 * 8 * 4, 0] {
        q.extend_from_slice(&(v as u32).to_ne_bytes());
    }
    let mut small = [7u8; 4];
    let n = unsafe { wg_query(a.h, q.as_ptr(), q.len(), small.as_mut_ptr(), small.len()) };
    assert_eq!(n, 8 * 8 * 4);
    assert_eq!(small, [7u8; 4], "nothing written");
    let _ = Reply::empty();
}
