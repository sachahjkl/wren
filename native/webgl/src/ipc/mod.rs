//! What the browser and its GPU process share: two byte rings in one section of shared memory, a section per canvas for its
//! frames, and a doorbell that also says when the other side is gone (docs/js/webgl.md).
//!
//! Either side may be hostile or broken to the other: the child runs drivers and the shaders of every page, and a parent's
//! stream is what a page wrote. So nothing in shared memory is believed: an index is checked before it is used, bytes are
//! copied out before they are looked at, and a length comes with a limit of its kind.

use std::sync::atomic::{fence, AtomicU32, AtomicU64, Ordering};
use std::time::{Duration, Instant};

#[cfg(windows)]
#[path = "sys_windows.rs"]
pub mod sys;
#[cfg(unix)]
#[path = "sys_linux.rs"]
pub mod sys;

/// The argument that makes the program a GPU process. It is never in a command line a person types.
pub const ROLE_ARG: &str = "--wren-gpu-process=";
/// Told in the hello, so that a program from another build is not believed.
pub const PROTOCOL_VERSION: u32 = 1;
const CONTROL_MAGIC: u32 = 0x5747_5055; // "WGPU"

/// Each direction's ring. It is one copy for what passes through, whatever its size (a larger message goes through in pieces,
/// the reader taking them away as they come): it only has to be larger than the usual frame's commands, and it stays resident
/// once a long session has gone round it.
pub const RING_BYTES: usize = 16 << 20;
const PAGE_BYTES: usize = 4096;
/// The whole control section: a head page, then a head page and data per ring.
pub const CONTROL_BYTES: usize = PAGE_BYTES + 2 * (PAGE_BYTES + RING_BYTES);

/// A reader looks this many times more before it sleeps: an answer to a question usually comes sooner than a wake-up would.
const READER_SPINS: u32 = 2000;
/// A writer with a full ring looks this many times between yields, and yields this many times before it sleeps a little.
const WRITER_SPINS: u32 = 200;
const WRITER_YIELDS: u32 = 64;
const WRITER_SLEEP: Duration = Duration::from_micros(200);

// ---- limits of what a message may say ----

/// Commands in one message: what wg_submit's caller may send at once (a buffer or a texture, within webgl.max_mb).
pub const MAX_COMMAND_BYTES: u64 = 8 << 30;
/// A question: its words and a name.
pub const MAX_QUESTION_BYTES: u64 = 4 << 30;
/// An answer: a readPixels of the largest canvas is 16384 x 16384 x 16 bytes.
pub const MAX_REPLY_BYTES: u64 = 8 << 30;
/// A line for the console.
pub const MAX_CONSOLE_BYTES: u64 = 4096;
/// An explanation of why a context could not be made.
pub const MAX_ERROR_BYTES: u64 = 1024;
/// One context in a Pong: id, operations done, busy.
pub const PONG_ENTRY_BYTES: u64 = 16;
/// A Pong: the contexts a process can have, many times what webgl.max_contexts lets one page make.
pub const MAX_PONG_BYTES: u64 = PONG_ENTRY_BYTES * 65536;
/// How much of a message's body is allocated before its bytes are seen: a lie about a length costs no more than this.
pub const BODY_STEP_BYTES: usize = 1 << 20;

/// What goes to the child.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToChild {
    Create = 1,
    Commands = 2,
    Query = 3,
    Present = 4,
    Snapshot = 5,
    Resize = 6,
    Target = 7,
    Lose = 8,
    Restore = 9,
    Destroy = 10,
    Ping = 11,
    Exit = 12,
    Commit = 13,
    /// Test hooks: a child started without them takes these for a broken stream and ends.
    TestMisbehave = 100,
}

impl ToChild {
    pub fn of(v: u32) -> Option<ToChild> {
        Some(match v {
            1 => ToChild::Create,
            2 => ToChild::Commands,
            3 => ToChild::Query,
            4 => ToChild::Present,
            5 => ToChild::Snapshot,
            6 => ToChild::Resize,
            7 => ToChild::Target,
            8 => ToChild::Lose,
            9 => ToChild::Restore,
            10 => ToChild::Destroy,
            11 => ToChild::Ping,
            12 => ToChild::Exit,
            13 => ToChild::Commit,
            100 => ToChild::TestMisbehave,
            _ => return None,
        })
    }
}

/// What comes from the child.
#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToParent {
    Hello = 1,
    Created = 2,
    CreateFailed = 3,
    Reply = 4,
    Done = 5,
    Frame = 6,
    FrameDropped = 7,
    Lost = 8,
    Restored = 9,
    Console = 10,
    Pong = 11,
    Stopped = 12,
}

impl ToParent {
    pub fn of(v: u32) -> Option<ToParent> {
        Some(match v {
            1 => ToParent::Hello,
            2 => ToParent::Created,
            3 => ToParent::CreateFailed,
            4 => ToParent::Reply,
            5 => ToParent::Done,
            6 => ToParent::Frame,
            7 => ToParent::FrameDropped,
            8 => ToParent::Lost,
            9 => ToParent::Restored,
            10 => ToParent::Console,
            11 => ToParent::Pong,
            12 => ToParent::Stopped,
            _ => return None,
        })
    }
}

/// The head of a message, in front of its body.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Head {
    pub kind: u32,
    pub ctx: u32,
    /// The kind's own number: a question's id, a count.
    pub arg: u64,
    pub len: u64,
}

pub const HEAD_BYTES: usize = 24;

impl Head {
    pub fn to_bytes(self) -> [u8; HEAD_BYTES] {
        let mut b = [0u8; HEAD_BYTES];
        b[0..4].copy_from_slice(&self.kind.to_le_bytes());
        b[4..8].copy_from_slice(&self.ctx.to_le_bytes());
        b[8..16].copy_from_slice(&self.arg.to_le_bytes());
        b[16..24].copy_from_slice(&self.len.to_le_bytes());
        b
    }
    pub fn of_bytes(b: &[u8; HEAD_BYTES]) -> Head {
        Head {
            kind: u32::from_le_bytes([b[0], b[1], b[2], b[3]]),
            ctx: u32::from_le_bytes([b[4], b[5], b[6], b[7]]),
            arg: u64::from_le_bytes([b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]]),
            len: u64::from_le_bytes([b[16], b[17], b[18], b[19], b[20], b[21], b[22], b[23]]),
        }
    }
}

/// Why a channel stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IpcError {
    /// The other side ended.
    Gone,
    /// An index in shared memory cannot be true, or a message breaks the protocol.
    Corrupt,
    /// The other side took nothing for longer than the deadline.
    Stuck,
}

#[repr(C)]
struct ControlHead {
    magic: AtomicU32,
    version: AtomicU32,
}

#[repr(C, align(64))]
struct Aligned<T>(T);

/// The indices of a ring, on cache lines of their own. They only grow; the place is the index modulo the capacity.
#[repr(C)]
struct RingHead {
    write: Aligned<AtomicU64>,
    read: Aligned<AtomicU64>,
    /// 1: the reader is about to sleep, the writer rings.
    sleeping: Aligned<AtomicU32>,
}

const _: () = assert!(std::mem::size_of::<RingHead>() <= PAGE_BYTES);
const _: () = assert!(std::mem::size_of::<ControlHead>() <= PAGE_BYTES);

/// One direction in shared memory. (Raw pointers: the other process writes this memory whenever it likes, so no reference to
/// the data may exist, only copies in and out.)
#[derive(Clone, Copy)]
pub struct Ring {
    head: *const RingHead,
    data: *mut u8,
    cap: u64,
}

unsafe impl Send for Ring {}
unsafe impl Sync for Ring {}

/// Which ring of the section is which.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Dir {
    ToChild,
    ToParent,
}

impl Ring {
    /// The ring of a mapped control section (`base`: CONTROL_BYTES).
    pub unsafe fn at(base: *mut u8, dir: Dir) -> Ring {
        let n = match dir {
            Dir::ToChild => 0,
            Dir::ToParent => 1,
        };
        let head = base.add(PAGE_BYTES + n * (PAGE_BYTES + RING_BYTES));
        Ring { head: head as *const RingHead, data: head.add(PAGE_BYTES), cap: RING_BYTES as u64 }
    }
    /// A ring on any memory (tests).
    #[cfg(test)]
    pub unsafe fn on(mem: *mut u8, cap: u64) -> Ring {
        Ring { head: mem as *const RingHead, data: mem.add(PAGE_BYTES), cap }
    }
    fn head(&self) -> &RingHead {
        // (atomics only: any value the other side stores is a valid value)
        unsafe { &*self.head }
    }
}

/// Marks the section as made by this protocol's parent.
pub unsafe fn control_init(base: *mut u8) {
    let c = &*(base as *const ControlHead);
    c.version.store(PROTOCOL_VERSION, Ordering::Relaxed);
    c.magic.store(CONTROL_MAGIC, Ordering::Release);
}

pub unsafe fn control_ok(base: *mut u8) -> bool {
    let c = &*(base as *const ControlHead);
    c.magic.load(Ordering::Acquire) == CONTROL_MAGIC && c.version.load(Ordering::Relaxed) == PROTOCOL_VERSION
}

/// The writing end of a ring: one writer at a time (its owner holds a lock).
pub struct RingWriter {
    ring: Ring,
    pos: u64,
}

impl RingWriter {
    pub fn new(ring: Ring) -> RingWriter {
        RingWriter { ring, pos: 0 }
    }

    /// A test hook: an index that cannot be true.
    pub fn test_corrupt(&mut self) {
        self.ring.head().write.0.store(u64::MAX / 2, Ordering::SeqCst);
    }

    /// The bytes, as they find room. `bell` wakes the reader; `gone` is asked while waiting; past `deadline` it is Stuck, and the
    /// stream is then broken (a message cut short): the caller must end the channel.
    pub fn write(&mut self, mut bytes: &[u8], bell: &sys::Bell, gone: &dyn Fn() -> bool, deadline: Option<Instant>) -> Result<(), IpcError> {
        let head = self.ring.head();
        let cap = self.ring.cap;
        let mut waits = 0u32;
        while !bytes.is_empty() {
            let read = head.read.0.load(Ordering::Acquire);
            if read > self.pos || self.pos - read > cap {
                return Err(IpcError::Corrupt);
            }
            let free = cap - (self.pos - read);
            if free == 0 {
                if gone() {
                    return Err(IpcError::Gone);
                }
                waits += 1;
                if waits % WRITER_SPINS != 0 {
                    std::hint::spin_loop();
                } else if waits / WRITER_SPINS < WRITER_YIELDS {
                    std::thread::yield_now();
                } else {
                    if let Some(d) = deadline {
                        if Instant::now() >= d {
                            return Err(IpcError::Stuck);
                        }
                    }
                    std::thread::sleep(WRITER_SLEEP);
                }
                // (the reader may have gone to sleep before what was published last)
                ring_if_sleeping(head, bell);
                continue;
            }
            waits = 0;
            let at = self.pos % cap;
            let n = (free.min(cap - at) as usize).min(bytes.len());
            unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), self.ring.data.add(at as usize), n) };
            self.pos += n as u64;
            bytes = &bytes[n..];
            head.write.0.store(self.pos, Ordering::Release);
            // (with the store above and the reader's in `sleeping`: one of the two sides sees the other)
            fence(Ordering::SeqCst);
            ring_if_sleeping(head, bell);
        }
        Ok(())
    }
}

fn ring_if_sleeping(head: &RingHead, bell: &sys::Bell) {
    if head.sleeping.0.load(Ordering::Relaxed) != 0 && head.sleeping.0.swap(0, Ordering::SeqCst) != 0 {
        // (never blocks: a peer that claims to sleep and never reads costs it nothing but itself)
        bell.ring();
    }
}

/// The reading end of a ring: one thread.
pub struct RingReader {
    ring: Ring,
    pos: u64,
}

impl RingReader {
    pub fn new(ring: Ring) -> RingReader {
        RingReader { ring, pos: 0 }
    }

    /// Bytes to read now; waits when there are none.
    fn available(&mut self, bell: &sys::Bell) -> Result<u64, IpcError> {
        let head = self.ring.head();
        let mut spins = 0;
        loop {
            let write = head.write.0.load(Ordering::Acquire);
            if write < self.pos || write - self.pos > self.ring.cap {
                return Err(IpcError::Corrupt);
            }
            if write > self.pos {
                return Ok(write - self.pos);
            }
            spins += 1;
            if spins < READER_SPINS {
                std::hint::spin_loop();
                continue;
            }
            spins = 0;
            head.sleeping.0.store(1, Ordering::SeqCst);
            fence(Ordering::SeqCst);
            let write = head.write.0.load(Ordering::Acquire);
            if write != self.pos {
                head.sleeping.0.store(0, Ordering::SeqCst);
                continue;
            }
            let woken = bell.wait();
            head.sleeping.0.store(0, Ordering::SeqCst);
            woken?;
        }
    }

    /// Exactly these bytes, however long they take.
    pub fn read(&mut self, mut out: &mut [u8], bell: &sys::Bell) -> Result<(), IpcError> {
        let cap = self.ring.cap;
        while !out.is_empty() {
            let have = self.available(bell)?;
            let at = self.pos % cap;
            let n = (have.min(cap - at) as usize).min(out.len());
            let (now, rest) = out.split_at_mut(n);
            unsafe { std::ptr::copy_nonoverlapping(self.ring.data.add(at as usize), now.as_mut_ptr(), n) };
            out = rest;
            self.pos += n as u64;
            self.ring.head().read.0.store(self.pos, Ordering::Release);
        }
        Ok(())
    }

    pub fn head(&mut self, bell: &sys::Bell) -> Result<Head, IpcError> {
        let mut b = [0u8; HEAD_BYTES];
        self.read(&mut b, bell)?;
        Ok(Head::of_bytes(&b))
    }

    /// A body of `len` bytes (checked against the kind's limit by the caller), allocated as its bytes arrive.
    pub fn body(&mut self, len: u64, bell: &sys::Bell) -> Result<Vec<u8>, IpcError> {
        let len = usize::try_from(len).map_err(|_| IpcError::Corrupt)?;
        let mut v = Vec::with_capacity(len.min(BODY_STEP_BYTES));
        let mut done = 0;
        while done < len {
            let step = (len - done).min(BODY_STEP_BYTES.max(done));
            // (the vector doubles at most: a claimed length is only ever paid for by bytes that came)
            v.resize(done + step, 0);
            self.read(&mut v[done..done + step], bell)?;
            done += step;
        }
        Ok(v)
    }

    /// Reads and throws away (an answer nobody waits for any more).
    pub fn skip(&mut self, mut len: u64, bell: &sys::Bell) -> Result<(), IpcError> {
        let mut scrap = [0u8; 4096];
        while len > 0 {
            let n = len.min(scrap.len() as u64) as usize;
            self.read(&mut scrap[..n], bell)?;
            len -= n as u64;
        }
        Ok(())
    }
}

/// What a test may ask a child started with the hooks to do.
pub mod test_kind {
    pub const CRASH: u32 = 1;
    pub const HANG_CONTEXT: u32 = 2;
    pub const STALL_READER: u32 = 3;
    pub const BAD_KIND: u32 = 4;
    pub const HUGE_LENGTH: u32 = 5;
    pub const BAD_CONTEXT: u32 = 6;
    pub const UNASKED_REPLY: u32 = 7;
    pub const TOO_MANY_DONE: u32 = 8;
    pub const BAD_ROWS: u32 = 9;
    pub const CORRUPT_INDEX: u32 = 10;
    pub const EXIT_QUIETLY: u32 = 11;
}

// ---- a canvas's frames ----

/// Pictures in a frame section. The child fills one, publishes it, and takes the one published before if the parent did not
/// take it: neither ever waits for the other, and a frame is torn only if a side breaks the rule on purpose.
pub const FRAME_SLOTS: u32 = 3;
pub const SLOT_NEW: u32 = 0x8000_0000;
/// The section's head: the exchange word and each slot's description.
const FRAME_HEAD_BYTES: u64 = PAGE_BYTES as u64;

#[repr(C)]
struct SlotMeta {
    w: AtomicU32,
    h: AtomicU32,
    opaque: AtomicU32,
    _pad: AtomicU32,
}

#[repr(C)]
struct FrameHead {
    /// The slot published, with SLOT_NEW until the parent took it.
    ready: Aligned<AtomicU32>,
    slots: [SlotMeta; FRAME_SLOTS as usize],
}

const _: () = assert!(std::mem::size_of::<FrameHead>() as u64 <= FRAME_HEAD_BYTES);

/// Bytes of a frame section for pictures of this size, or None when that cannot be asked for.
pub fn frame_section_bytes(w: u32, h: u32) -> Option<u64> {
    (w as u64).checked_mul(h as u64)?.checked_mul(4)?.checked_mul(FRAME_SLOTS as u64)?.checked_add(FRAME_HEAD_BYTES)
}

/// A mapped frame section. Both processes hold one; `base` stays valid as long as the mapping does.
pub struct FrameView {
    base: *mut u8,
    bytes: u64,
    /// The slot this side holds: to fill (child) or just read (parent).
    held: u32,
    pub w: u32,
    pub h: u32,
}

unsafe impl Send for FrameView {}

impl FrameView {
    /// `bytes` were mapped at `base` and the pictures are at most w x h. The parent holds slot 0 and the child slot 1: slot 2 is
    /// the one in the exchange word, zero bytes at the start with no NEW.
    pub unsafe fn new(base: *mut u8, bytes: u64, w: u32, h: u32, child: bool) -> Option<FrameView> {
        let need = frame_section_bytes(w, h)?;
        if bytes < need {
            return None;
        }
        let v = FrameView { base, bytes, held: if child { 1 } else { 0 }, w, h };
        Some(v)
    }

    /// A test hook: what a hostile child could leave in the exchange word.
    pub fn test_scribble(&mut self, word: u32, w: u32, h: u32) {
        self.head().ready.0.store(word, Ordering::SeqCst);
        for s in &self.head().slots {
            s.w.store(w, Ordering::SeqCst);
            s.h.store(h, Ordering::SeqCst);
        }
    }

    /// (the parent, when the section is made or a new child takes it over)
    pub fn reset(&mut self, child: bool) {
        self.held = if child { 1 } else { 0 };
        self.head().ready.0.store(2, Ordering::SeqCst);
    }

    fn head(&self) -> &FrameHead {
        unsafe { &*(self.base as *const FrameHead) }
    }

    fn slot_bytes(&self) -> u64 {
        self.w as u64 * self.h as u64 * 4
    }

    fn slot_at(&self, slot: u32) -> *mut u8 {
        unsafe { self.base.add((FRAME_HEAD_BYTES + slot as u64 * self.slot_bytes()) as usize) }
    }

    /// (child) Where to write the next picture of w x h: tightly packed, within this section's size.
    pub fn fill(&mut self, w: u32, h: u32) -> Option<*mut u8> {
        if w > self.w || h > self.h {
            return None;
        }
        Some(self.slot_at(self.held))
    }

    /// (child) The picture written goes out.
    pub fn publish(&mut self, w: u32, h: u32, opaque: bool) {
        let meta = &self.head().slots[self.held as usize];
        meta.w.store(w, Ordering::Relaxed);
        meta.h.store(h, Ordering::Relaxed);
        meta.opaque.store(opaque as u32, Ordering::Relaxed);
        let old = self.head().ready.0.swap(self.held | SLOT_NEW, Ordering::AcqRel);
        // (the parent's word is believed by the child only as far as the index; nothing here depends on it being true)
        self.held = (old & !SLOT_NEW).min(FRAME_SLOTS - 1);
    }

    /// (parent) The newest picture not taken yet, if it is w x h: its rows are copied to `dst`; what the child says of its size is
    /// checked against this section and against the bitmap's, and no pixel is read outside. Ok(None): nothing new, or of
    /// another size. Err: the child broke the protocol.
    ///
    /// # Safety
    /// `dst` holds `height` rows of `stride` bytes, and `stride` >= w * 4.
    pub unsafe fn take(&mut self, dst: *mut u8, w: u32, height: u32, stride: u32) -> Result<Option<bool>, IpcError> {
        let ready = self.head().ready.0.load(Ordering::Acquire);
        if ready & SLOT_NEW == 0 {
            return Ok(None);
        }
        let old = self.head().ready.0.swap(self.held, Ordering::AcqRel);
        let slot = old & !SLOT_NEW;
        if slot >= FRAME_SLOTS {
            return Err(IpcError::Corrupt);
        }
        self.held = slot;
        let meta = &self.head().slots[slot as usize];
        let (fw, fh, opaque) = (meta.w.load(Ordering::Relaxed), meta.h.load(Ordering::Relaxed), meta.opaque.load(Ordering::Relaxed) != 0);
        if fw > self.w || fh > self.h || (fw as u64 * fh as u64 * 4) > self.slot_bytes() {
            return Err(IpcError::Corrupt);
        }
        if fw != w || fh != height || dst.is_null() {
            return Ok(None);
        }
        let from = self.slot_at(slot);
        let row = w as usize * 4;
        debug_assert!(FRAME_HEAD_BYTES + (slot as u64 + 1) * self.slot_bytes() <= self.bytes);
        for y in 0..height as usize {
            std::ptr::copy_nonoverlapping(from.add(y * row), dst.add(y * stride as usize), row);
        }
        Ok(Some(opaque))
    }
}

// ---- a message's bodies ----

/// A body with known fields: little-endian words, read with a check of the length.
#[derive(Default)]
pub struct Words(pub Vec<u8>);

impl Words {
    pub fn u32(&mut self, v: u32) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    pub fn u64(&mut self, v: u64) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
}

pub struct WordReader<'a> {
    b: &'a [u8],
}

impl<'a> WordReader<'a> {
    pub fn new(b: &'a [u8]) -> Self {
        WordReader { b }
    }
    pub fn u32(&mut self) -> Option<u32> {
        let (a, rest) = self.b.split_first_chunk::<4>()?;
        self.b = rest;
        Some(u32::from_le_bytes(*a))
    }
    pub fn u64(&mut self) -> Option<u64> {
        let (a, rest) = self.b.split_first_chunk::<8>()?;
        self.b = rest;
        Some(u64::from_le_bytes(*a))
    }
    pub fn rest(&self) -> &'a [u8] {
        self.b
    }
}

/// The rows of an answer (first offset, row bytes, stride), as the child says: the length the caller's buffer must have, or None
/// when they make no sense for `data` bytes.
pub fn rows_end(first: u64, row: u64, stride: u64, data: u64) -> Option<u64> {
    if row == 0 {
        return if data == 0 { Some(first) } else { None };
    }
    if data % row != 0 {
        return None;
    }
    let rows = data / row;
    if rows > 1 && stride < row {
        return None;
    }
    first.checked_add(stride.checked_mul(rows.saturating_sub(1))?)?.checked_add(row)
}
