//! The GPU process: the program started with its role argument (ipc::ROLE_ARG), before anything else of the browser is set up. A
//! thread reads the ring from the browser and hands each context's messages to that context's thread (host.rs); it never touches
//! a device, so it still answers when a driver has hung one of them, and the browser can tell which.
//!
//! What it receives is checked: a kind it does not know, a length past its kind's limit or an index in shared memory that cannot
//! be true ends the process, attributes that cannot be are refused, and a context it does not know is ignored. The command
//! stream itself is checked by `Ctx::exec`, word by word.

use crate::gl::Flags;
use crate::host::{self, Msg, Target};
use crate::ipc::{self, sys, Dir, FrameView, Head, IpcError, Ring, RingReader, RingWriter, ToChild, ToParent, WordReader, Words};
use crate::{WgAttrs, BACKEND_VULKAN, THREAD_STACK_BYTES};
use std::collections::HashMap;
use std::sync::atomic::Ordering;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};

/// The longest side a context may ask for: what no GPU has.
const MAX_ATTR_DIMENSION: u32 = 1 << 20;
/// The exit codes this process ends with on purpose.
const EXIT_NORMAL: u32 = 0;
const EXIT_PARENT_GONE: u32 = 2;
const EXIT_BROKEN_STREAM: u32 = 3;
const EXIT_NO_CHANNEL: u32 = 4;
/// How long a test's stalled reader sleeps at a time.
const TEST_STALL_NAP: std::time::Duration = std::time::Duration::from_secs(3600);

/// The attributes of a context, as words on the wire.
pub const ATTR_WORDS: usize = 14;

/// What a child sends goes through this: one message at a time, whichever thread.
pub struct Out {
    tx: Mutex<RingWriter>,
    bell: &'static sys::Bell,
}

impl Out {
    /// A message. The only way this fails is that the browser has gone or broken the ring, and then there is nothing left to do.
    pub fn send(&self, kind: ToParent, ctx: u32, arg: u64, body: &[&[u8]]) {
        let len = body.iter().map(|b| b.len() as u64).sum();
        let head = Head { kind: kind as u32, ctx, arg, len };
        let mut tx = match self.tx.lock() {
            Ok(g) => g,
            Err(e) => e.into_inner(),
        };
        let gone = || false;
        if tx.write(&head.to_bytes(), self.bell, &gone, None).is_err() {
            sys::exit_now(EXIT_PARENT_GONE);
        }
        for b in body {
            if tx.write(b, self.bell, &gone, None).is_err() {
                sys::exit_now(EXIT_PARENT_GONE);
            }
        }
    }
}

/// `--wren-gpu-process=...` as the program's first argument: runs the GPU process and never returns. Otherwise it returns at once;
/// this is called first thing in every program of the browser that can make a context, and costs a look at the arguments.
pub fn entry_if_role() {
    let args = sys::args();
    let Some(role) = args.first().and_then(|a| a.strip_prefix(ipc::ROLE_ARG)) else { return };
    let code = main(role);
    sys::exit_now(code);
}

/// A context as the reader thread knows it.
struct Entry {
    tx: Sender<Msg>,
    flags: Arc<Flags>,
}

pub fn main(role: &str) -> u32 {
    let end = match sys::open_child(role) {
        Ok(e) => e,
        Err(_) => return EXIT_NO_CHANNEL,
    };
    if !unsafe { ipc::control_ok(end.control) } {
        return EXIT_NO_CHANNEL;
    }
    let hooks = end.hooks;
    let lowered = if end.keep_rights { Vec::new() } else { sys::lower_rights(true) };
    // (lives as long as the process: the threads of contexts hold it)
    let bell: &'static sys::Bell = Box::leak(Box::new(end.bell));
    let out: &'static Out = Box::leak(Box::new(Out { tx: Mutex::new(RingWriter::new(unsafe { Ring::at(end.control, Dir::ToParent) })), bell }));
    let mut hello = Words::default();
    hello.u32(ipc::PROTOCOL_VERSION).u32(std::process::id());
    let names = lowered.join(",");
    out.send(ToParent::Hello, 0, 0, &[&hello.0, names.as_bytes()]);
    let mut rx = RingReader::new(unsafe { Ring::at(end.control, Dir::ToChild) });
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| read_loop(&mut rx, bell, out, hooks))) {
        Ok(Ok(())) => EXIT_NORMAL,
        Ok(Err(IpcError::Gone)) => EXIT_PARENT_GONE,
        _ => EXIT_BROKEN_STREAM,
    }
}

/// The attributes, checked: anything that cannot be is refused here. (They come from the browser, which got the size and the flags
/// from a page and the rest from preferences.)
pub(crate) fn attrs_of(body: &[u8]) -> Option<WgAttrs> {
    let mut r = WordReader::new(body);
    let mut flag = || r.u32().map(|v| (v != 0) as i32);
    let (webgl2, alpha, depth, stencil, antialias, premultiplied, preserve, fail) = (flag()?, flag()?, flag()?, flag()?, flag()?, flag()?, flag()?, flag()?);
    let (width, height, max_dimension) = (r.u32()?, r.u32()?, r.u32()?);
    let (allow_software, force_software) = ((r.u32()? != 0) as i32, (r.u32()? != 0) as i32);
    let backend = r.u32()? as i32;
    let max_bytes = r.u64()?;
    if !(1..=MAX_ATTR_DIMENSION).contains(&max_dimension) || !(0..=BACKEND_VULKAN).contains(&backend) || width > MAX_ATTR_DIMENSION || height > MAX_ATTR_DIMENSION || !r.rest().is_empty() {
        return None;
    }
    Some(WgAttrs {
        webgl2,
        alpha,
        depth,
        stencil,
        antialias,
        premultiplied,
        preserve,
        fail_if_major_performance_caveat: fail,
        width,
        height,
        max_dimension,
        allow_software,
        force_software,
        backend,
        max_bytes,
        wait_ms: 0,
        hang_ms: 0,
        max_restarts: 0,
        restart_window_ms: 0,
        idle_exit_ms: 0,
        keep_rights: 0,
        notify: None,
        notify_user: std::ptr::null_mut(),
    })
}

fn read_loop(rx: &mut RingReader, bell: &'static sys::Bell, out: &'static Out, hooks: bool) -> Result<(), IpcError> {
    let mut contexts: HashMap<u32, Entry> = HashMap::new();
    loop {
        let head = rx.head(bell)?;
        let Some(kind) = ToChild::of(head.kind) else { return Err(IpcError::Corrupt) };
        let limit = match kind {
            ToChild::Commands => ipc::MAX_COMMAND_BYTES,
            ToChild::Query => ipc::MAX_QUESTION_BYTES,
            ToChild::Create | ToChild::Prepare => (ATTR_WORDS * 4 + 8) as u64,
            ToChild::Target => 40,
            ToChild::Resize => 8,
            _ => 0,
        };
        if head.len > limit {
            return Err(IpcError::Corrupt);
        }
        match kind {
            ToChild::Create => {
                let body = rx.body(head.len, bell)?;
                let Some(a) = attrs_of(&body) else {
                    let text = "the attributes of the context cannot be";
                    out.send(ToParent::CreateFailed, head.ctx, head.arg, &[text.as_bytes()]);
                    continue;
                };
                if contexts.contains_key(&head.ctx) {
                    let text = "a context with this number exists";
                    out.send(ToParent::CreateFailed, head.ctx, head.arg, &[text.as_bytes()]);
                    continue;
                }
                let (tx, ctx_rx) = mpsc::channel();
                let flags = Arc::new(Flags::default());
                let (id, qid, f) = (head.ctx, head.arg, flags.clone());
                let spawned = std::thread::Builder::new().name("wren webgl".to_string()).stack_size(THREAD_STACK_BYTES).spawn(move || host::run(id, qid, a, ctx_rx, f, out));
                match spawned {
                    Ok(_) => {
                        contexts.insert(head.ctx, Entry { tx, flags });
                    }
                    Err(e) => {
                        let text = format!("no thread: {e}");
                        out.send(ToParent::CreateFailed, head.ctx, head.arg, &[text.as_bytes()]);
                    }
                }
            }
            ToChild::Prepare => {
                // (attributes that cannot be prepare nothing: the Create that follows them is refused)
                let body = rx.body(head.len, bell)?;
                if let Some(a) = attrs_of(&body) {
                    host::prepare(host::Key::of(&a));
                }
            }
            ToChild::Commands => {
                let data = rx.body(head.len, bell)?;
                to_context(&contexts, head.ctx, Msg::Commands(data), out, head.len);
            }
            ToChild::Query => {
                let data = rx.body(head.len, bell)?;
                if let Some(e) = contexts.get(&head.ctx) {
                    if e.tx.send(Msg::Query(data, head.arg)).is_ok() {
                        continue;
                    }
                }
                // (nobody to ask: the empty answer of a lost context)
                let mut w = Words::default();
                w.u32(0).u32(0).u64(0).u64(0).u64(0);
                out.send(ToParent::Reply, head.ctx, head.arg, &[&w.0, &crate::gl::Reply::null().data]);
            }
            ToChild::Present => {
                to_context(&contexts, head.ctx, Msg::Present { snapshot: false, qid: None }, out, 0);
            }
            ToChild::Snapshot => {
                to_context(&contexts, head.ctx, Msg::Present { snapshot: true, qid: Some(head.arg) }, out, 0);
            }
            ToChild::Commit => {
                to_context(&contexts, head.ctx, Msg::Present { snapshot: false, qid: Some(head.arg) }, out, 0);
            }
            ToChild::Resize => {
                let body = rx.body(head.len, bell)?;
                let mut r = WordReader::new(&body);
                let (Some(w), Some(h)) = (r.u32(), r.u32()) else { return Err(IpcError::Corrupt) };
                if w <= MAX_ATTR_DIMENSION && h <= MAX_ATTR_DIMENSION {
                    to_context(&contexts, head.ctx, Msg::Resize(w, h), out, 0);
                }
            }
            ToChild::Target => {
                let body = rx.body(head.len, bell)?;
                let mut r = WordReader::new(&body);
                let (Some(token), Some(bytes), Some(w), Some(h)) = (r.u64(), r.u64(), r.u32(), r.u32()) else { return Err(IpcError::Corrupt) };
                // (a size that does not add up is refused before anything is mapped; mapping checks the section's real size)
                let target = if ipc::frame_section_bytes(w, h) == Some(bytes) {
                    sys::map_token(token, bytes).and_then(|base| match unsafe { FrameView::new(base, bytes, w, h, true) } {
                        Some(view) => Some(Target { view, base, bytes }),
                        None => {
                            unsafe { sys::unmap(base, bytes) };
                            None
                        }
                    })
                } else {
                    None
                };
                to_context(&contexts, head.ctx, Msg::Target(target), out, 0);
            }
            ToChild::Lose => {
                to_context(&contexts, head.ctx, Msg::Lose, out, 0);
            }
            ToChild::Restore => {
                to_context(&contexts, head.ctx, Msg::Restore(head.arg), out, 0);
            }
            ToChild::Destroy => match contexts.remove(&head.ctx) {
                Some(e) => {
                    // (the thread frees everything, in its own time, and says Stopped)
                    let _ = e.tx.send(Msg::Quit);
                }
                None => out.send(ToParent::Stopped, head.ctx, 0, &[]),
            },
            ToChild::Ping => {
                let mut w = Words::default();
                for (id, e) in &contexts {
                    w.u32(*id).u32(e.flags.busy.load(Ordering::SeqCst) as u32).u64(e.flags.ops.load(Ordering::Relaxed));
                }
                out.send(ToParent::Pong, 0, head.arg, &[&w.0]);
            }
            ToChild::Exit => return Ok(()),
            ToChild::TestMisbehave => {
                // (a child started without the hooks takes it for what it then is: a broken stream)
                if !hooks {
                    return Err(IpcError::Corrupt);
                }
                misbehave(head, &contexts, rx, bell, out);
            }
        }
    }
}

fn to_context(contexts: &HashMap<u32, Entry>, id: u32, msg: Msg, out: &'static Out, commands: u64) {
    let sent = contexts.get(&id).map(|e| e.tx.send(msg).is_ok()).unwrap_or(false);
    if !sent && commands > 0 {
        // (a command for a context that went: its bytes still count until they are told done)
        out.send(ToParent::Done, id, commands, &[]);
    }
}

/// What the tests ask of a child (only with the hooks): what a broken or hostile GPU process could do. ipc::test_kind.
fn misbehave(head: Head, contexts: &HashMap<u32, Entry>, _rx: &mut RingReader, _bell: &'static sys::Bell, out: &'static Out) {
    use crate::ipc::test_kind as k;
    let qid = head.arg >> 8;
    match (head.arg & 0xff) as u32 {
        k::CRASH => unsafe {
            // what a driver's bad pointer does
            std::ptr::write_volatile(std::ptr::null_mut::<u32>().wrapping_add(1), 1);
        },
        k::HANG_CONTEXT => {
            if let Some(e) = contexts.get(&head.ctx) {
                let _ = e.tx.send(Msg::TestHang);
            }
        }
        k::STALL_READER => loop {
            std::thread::sleep(TEST_STALL_NAP);
        },
        k::BAD_KIND => out.send_raw_head(Head { kind: 0xDEAD, ctx: 1, arg: 0, len: 0 }),
        k::HUGE_LENGTH => out.send_raw_head(Head { kind: ToParent::Reply as u32, ctx: head.ctx, arg: 0, len: u64::MAX }),
        k::BAD_CONTEXT => out.send_raw_head(Head { kind: ToParent::Lost as u32, ctx: 0x7fff_ffff, arg: 0, len: 0 }),
        k::UNASKED_REPLY => {
            let mut w = Words::default();
            w.u32(0).u32(0).u64(0).u64(0).u64(0);
            out.send(ToParent::Reply, head.ctx, u64::MAX, &[&w.0]);
        }
        k::TOO_MANY_DONE => out.send(ToParent::Done, head.ctx, u64::MAX, &[]),
        k::BAD_ROWS => {
            // rows that end past any buffer, for a question that was asked
            let mut w = Words::default();
            w.u32(1).u32(0).u64(u64::MAX - 8).u64(4).u64(4);
            out.send(ToParent::Reply, head.ctx, qid, &[&w.0, &[0u8; 8]]);
        }
        k::CORRUPT_INDEX => out.corrupt_index(),
        k::EXIT_QUIETLY => sys::exit_now(EXIT_NORMAL),
        _ => {}
    }
}

impl Out {
    fn send_raw_head(&self, head: Head) {
        let mut tx = match self.tx.lock() {
            Ok(g) => g,
            Err(e) => e.into_inner(),
        };
        let gone = || false;
        let _ = tx.write(&head.to_bytes(), self.bell, &gone, None);
    }
    fn corrupt_index(&self) {
        let mut tx = match self.tx.lock() {
            Ok(g) => g,
            Err(e) => e.into_inner(),
        };
        tx.test_corrupt();
        self.bell.ring();
    }
}
