//! The browser's side of the GPU process: it starts the process at the first context of the browser, sends it what pages draw,
//! takes what comes back, watches it, and when it dies or hangs ends it, tells every context, and can start another.
//!
//! The child is not believed: a kind it should not send, a length past its limit, a context or a question that was never asked, a
//! count that does not add up: each ends the process. Pages see a lost context, and the browser nothing more.

use crate::ipc::{self, sys, Dir, Head, IpcError, Ring, RingReader, RingWriter, ToChild, ToParent, WordReader, Words};
use crate::{WgAttrs, WgInfo};
use std::collections::{HashMap, VecDeque};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// How often the watcher looks at the process.
const WATCH_TICK: Duration = Duration::from_millis(100);
/// How often it asks a process with work to do how it is doing.
const PING_EVERY: Duration = Duration::from_millis(500);
/// A context on a software adapter gets this many times webgl.gpu_hang_ms before it counts as hung: FXC compiles for it, slowly,
/// and one hung context costs every other context of the browser.
const SOFTWARE_HANG_FACTOR: u32 = 2;
/// A process told to end, or killed, has this long before the browser stops waiting to read its exit code.
const END_WAIT_MS: u32 = 2000;
/// How long a waiting page's thread goes between looks at whether the context was lost.
const LOST_POLL: Duration = Duration::from_millis(50);
/// Lines for the console, per context, kept until the page's thread takes them.
const MAX_CONSOLE_LINES: usize = 64;
/// How long a page's thread waits for commands to be taken, or for a frame's turn, before it gives up on this one.
const BACKPRESSURE_WAIT: Duration = Duration::from_millis(1000);
/// Queued commands, in bytes, before a page's thread waits for the context to catch up.
const MAX_QUEUED_BYTES: usize = 512 << 20;
/// Frames on their way to the CPU before a present waits (a page drawing faster than the GPU).
const MAX_FRAMES_IN_FLIGHT: usize = 3;
/// A process that did not say hello by then is no process.
const MIN_START_WAIT: Duration = Duration::from_millis(100);

/// How a process ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum End {
    /// It was told to, or nobody needs it any more.
    Asked,
    /// It ended by itself.
    Crashed,
    /// It stopped answering and was killed.
    Hung,
    /// It broke the protocol and was killed.
    Broke,
}

/// What a person may tune about the process (preferences webgl.gpu_*).
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub hang: Duration,
    pub max_restarts: u32,
    pub restart_window: Duration,
    pub idle_exit: Duration,
    pub keep_rights: bool,
}

impl Limits {
    pub fn of(a: &WgAttrs) -> Limits {
        Limits { hang: Duration::from_millis(a.hang_ms.max(1) as u64), max_restarts: a.max_restarts, restart_window: Duration::from_millis(a.restart_window_ms as u64), idle_exit: Duration::from_millis(a.idle_exit_ms as u64), keep_rights: a.keep_rights != 0 }
    }
}

/// One answer on its way.
#[derive(Default)]
pub struct Slot {
    reply: Mutex<Option<Answer>>,
    ready: Condvar,
    /// The asker's buffer: an answer that does not fit is not kept, only its length.
    cap: u64,
}

/// What came back: the bytes, or what they would need.
#[derive(Default)]
pub struct Answer {
    pub data: Vec<u8>,
    pub rows: Option<(u64, u64, u64)>,
    pub needed: u64,
    pub ok: bool,
}

impl Slot {
    fn new(cap: u64) -> Arc<Slot> {
        Arc::new(Slot { reply: Mutex::new(None), ready: Condvar::new(), cap })
    }
    fn put(&self, a: Answer) {
        if let Ok(mut g) = self.reply.lock() {
            *g = Some(a);
        }
        self.ready.notify_all();
    }
    /// The answer; None at the deadline, or soon after the context is lost.
    fn wait(&self, deadline: Instant, lost: &AtomicBool) -> Option<Answer> {
        let mut g = self.reply.lock().ok()?;
        loop {
            if let Some(r) = g.take() {
                return Some(r);
            }
            let now = Instant::now();
            if now >= deadline || lost.load(Ordering::SeqCst) {
                return None;
            }
            g = self.ready.wait_timeout(g, (deadline - now).min(LOST_POLL)).ok()?.0;
        }
    }
}

/// What the watcher, the reader and the page's thread share of a context.
pub struct Shared {
    pub lost: AtomicBool,
    pub in_flight: AtomicUsize,
    pub queued: AtomicUsize,
    console: Mutex<VecDeque<String>>,
    pub frames: AtomicU64,
    state_change: Mutex<()>,
    state_changed: Condvar,
    notify: Mutex<(Option<extern "C" fn(*mut c_void)>, usize)>,
}

impl Shared {
    fn new(a: &WgAttrs) -> Arc<Shared> {
        Arc::new(Shared {
            lost: AtomicBool::new(false),
            in_flight: AtomicUsize::new(0),
            queued: AtomicUsize::new(0),
            console: Mutex::new(VecDeque::new()),
            frames: AtomicU64::new(0),
            state_change: Mutex::new(()),
            state_changed: Condvar::new(),
            notify: Mutex::new((a.notify, a.notify_user as usize)),
        })
    }
    fn note(&self, text: String) {
        if let Ok(mut q) = self.console.lock() {
            if q.len() < MAX_CONSOLE_LINES {
                q.push_back(text);
            }
        }
    }
    /// Tells the browser something happened.
    fn ping(&self) {
        if let Ok(n) = self.notify.lock() {
            if let Some(f) = n.0 {
                f(n.1 as *mut c_void);
            }
        }
    }
    fn wake(&self) {
        let _g = self.state_change.lock();
        self.state_changed.notify_all();
    }
    pub fn take_console(&self) -> Option<String> {
        self.console.lock().ok()?.pop_front()
    }
    pub fn silence(&self) {
        if let Ok(mut n) = self.notify.lock() {
            n.0 = None;
        }
    }
}

/// A context in a process's table.
struct Entry {
    shared: Arc<Shared>,
    /// Its Handle went: only the thread's end is awaited.
    tomb: bool,
    software: bool,
    ops: u64,
    /// The last time it did anything, or had nothing to do.
    progress: Instant,
    /// Questions from a page waiting for this context.
    asked: usize,
    /// It was told to lose itself and has not said so: its thread may be stuck.
    lose_asked: bool,
}

struct Table {
    entries: HashMap<u32, Entry>,
    empty_since: Instant,
    ping_sent: Option<Instant>,
    ping_seq: u64,
    last_ping: Instant,
    last_pong: Instant,
}

/// One GPU process.
pub struct Proc {
    gpu: &'static Gpu,
    child: sys::Child,
    tx: Mutex<RingWriter>,
    dead: AtomicBool,
    table: Mutex<Table>,
    slots: Mutex<HashMap<u64, Arc<Slot>>>,
    next_qid: AtomicU64,
    hello: Slot,
    /// What the child gave up, as it says (for docs and tests).
    lowered: Mutex<String>,
    end_said: Mutex<Option<End>>,
}

struct GpuState {
    current: Option<Arc<Proc>>,
    deaths: VecDeque<Instant>,
    starts: u64,
}

/// The process of a browser: one, started by the first context. (Tests make their own to kill.)
pub struct Gpu {
    state: Mutex<GpuState>,
    limits: Mutex<Option<Limits>>,
    hooks: AtomicBool,
}

impl Gpu {
    pub const fn new() -> Gpu {
        Gpu {
            state: Mutex::new(GpuState { current: None, deaths: VecDeque::new(), starts: 0 }),
            limits: Mutex::new(None),
            hooks: AtomicBool::new(false),
        }
    }

    pub fn enable_hooks(&self) {
        self.hooks.store(true, Ordering::SeqCst);
    }

    #[cfg(test)]
    pub fn test_set_hang(&self, d: Duration) {
        let mut l = self.limits();
        l.hang = d;
        *lock(&self.limits) = Some(l);
    }

    fn limits(&self) -> Limits {
        let fallback = Limits { hang: Duration::from_secs(30), max_restarts: 3, restart_window: Duration::from_secs(60), idle_exit: Duration::from_secs(60), keep_rights: false };
        self.limits.lock().ok().and_then(|g| *g).unwrap_or(fallback)
    }

    pub fn current(&self) -> Option<Arc<Proc>> {
        lock(&self.state).current.clone()
    }

    pub fn starts(&self) -> u64 {
        lock(&self.state).starts
    }

    /// The living process, or a new one when the limit on restarts allows it; `entry` is in its table before anyone can see it idle.
    fn ensure(&'static self, id: u32, entry: Entry, wait: Duration) -> Result<Arc<Proc>, String> {
        let mut st = lock(&self.state);
        if let Some(p) = st.current.clone() {
            if !p.is_dead() {
                lock(&p.table).entries.insert(id, entry);
                return Ok(p);
            }
            st.current = None;
        }
        let limits = self.limits();
        let now = Instant::now();
        while st.deaths.front().is_some_and(|t| now.duration_since(*t) > limits.restart_window) {
            st.deaths.pop_front();
        }
        if st.deaths.len() as u64 > limits.max_restarts as u64 {
            return Err(format!("the GPU process ended {} times in a short while: WebGL is off for now (webgl.gpu_max_restarts)", st.deaths.len()));
        }
        let p = match Proc::start(self, wait.max(MIN_START_WAIT)) {
            Ok(p) => p,
            Err((p, e)) => {
                drop(st);
                // (its end takes the state's lock)
                if let Some(p) = p {
                    p.die(End::Hung);
                }
                return Err(e);
            }
        };
        st.starts += 1;
        lock(&p.table).entries.insert(id, entry);
        st.current = Some(p.clone());
        Ok(p)
    }

    fn died(&self, p: &Proc, end: End) {
        let mut st = lock(&self.state);
        if st.current.as_deref().is_some_and(|c| std::ptr::eq(c, p)) {
            st.current = None;
        }
        if end != End::Asked {
            st.deaths.push_back(Instant::now());
            let bound = self.limits().max_restarts as usize + 1;
            while st.deaths.len() > bound {
                st.deaths.pop_front();
            }
        }
    }

    /// Nobody needs the process: it goes, and it is no failure. Under the state's lock, so that nobody just got it.
    fn retire(&self, p: &Arc<Proc>) {
        let mut st = lock(&self.state);
        if !st.current.as_ref().is_some_and(|c| Arc::ptr_eq(c, p)) {
            return;
        }
        if !lock(&p.table).entries.is_empty() {
            return;
        }
        st.current = None;
        drop(st);
        p.end_said_set(End::Asked);
        p.dead.store(true, Ordering::SeqCst);
        let _ = p.send(ToChild::Exit, 0, 0, &[], None);
    }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(e) => e.into_inner(),
    }
}

/// What the program to start is. A test binary has no role argument of its own: it runs a test that is the child (tests.rs).
#[cfg(not(test))]
fn program() -> Result<(PathBuf, Vec<String>, &'static str), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    Ok((exe, Vec::new(), ipc::ROLE_ARG))
}

#[cfg(test)]
fn program() -> Result<(PathBuf, Vec<String>, &'static str), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    // (`--skip <text>` is the one thing libtest lets through that a child can read back)
    Ok((exe, vec!["tests::gpu_child_entry".into(), "--exact".into(), "--nocapture".into(), "--skip".into()], crate::tests::TEST_ROLE_PREFIX))
}

impl Proc {
    /// Starts the process and waits for its hello. The thread that starts it stays as long as it runs (sys_linux.rs says why).
    fn start(gpu: &'static Gpu, wait: Duration) -> Result<Arc<Proc>, (Option<Arc<Proc>>, String)> {
        let (exe, extra, prefix) = program().map_err(|e| (None, e))?;
        let hooks = gpu.hooks.load(Ordering::SeqCst);
        let keep_rights = gpu.limits().keep_rights;
        let (made_tx, made_rx) = mpsc::channel::<Result<Arc<Proc>, String>>();
        std::thread::Builder::new()
            .name("wren gpu watcher".to_string())
            .spawn(move || {
                let child = match sys::spawn(&exe, &extra, prefix, hooks, keep_rights) {
                    Ok(c) => c,
                    Err(e) => {
                        let _ = made_tx.send(Err(format!("the GPU process could not start: {e}")));
                        return;
                    }
                };
                let control = child.control() as usize;
                let now = Instant::now();
                let p = Arc::new(Proc {
                    gpu,
                    child,
                    tx: Mutex::new(RingWriter::new(unsafe { Ring::at(control as *mut u8, Dir::ToChild) })),
                    dead: AtomicBool::new(false),
                    table: Mutex::new(Table { entries: HashMap::new(), empty_since: now, ping_sent: None, ping_seq: 0, last_ping: now, last_pong: now }),
                    slots: Mutex::new(HashMap::new()),
                    next_qid: AtomicU64::new(1),
                    hello: Slot::default(),
                    lowered: Mutex::new(String::new()),
                    end_said: Mutex::new(None),
                });
                let reader = p.clone();
                let started = std::thread::Builder::new().name("wren gpu reader".to_string()).spawn(move || {
                    let mut rx = RingReader::new(unsafe { Ring::at(control as *mut u8, Dir::ToParent) });
                    let run = catch_unwind(AssertUnwindSafe(|| reader.read_loop(&mut rx)));
                    let end = match run {
                        Ok(IpcError::Gone) => End::Crashed,
                        Ok(_) | Err(_) => End::Broke,
                    };
                    reader.die(end);
                });
                if let Err(e) = started {
                    p.child.kill();
                    let _ = made_tx.send(Err(format!("no thread: {e}")));
                    return;
                }
                let _ = made_tx.send(Ok(p.clone()));
                drop(made_tx);
                p.watch();
            })
            .map_err(|e| (None, format!("no thread: {e}")))?;
        let p = match made_rx.recv_timeout(wait) {
            Ok(Ok(p)) => p,
            Ok(Err(e)) => return Err((None, e)),
            Err(_) => return Err((None, "the GPU process did not start in time".to_string())),
        };
        if p.hello.wait(Instant::now() + wait, &p.dead).is_none() {
            return Err((Some(p), "the GPU process did not answer in time".to_string()));
        }
        Ok(p)
    }

    pub fn is_dead(&self) -> bool {
        self.dead.load(Ordering::SeqCst)
    }

    pub fn pid(&self) -> u32 {
        self.child.pid()
    }

    pub fn lowered(&self) -> String {
        lock(&self.lowered).clone()
    }

    pub fn kill_for_test(&self) {
        self.child.kill();
    }

    fn end_said_set(&self, end: End) {
        let mut g = lock(&self.end_said);
        if g.is_none() {
            *g = Some(end);
        }
    }

    pub fn end(&self) -> Option<End> {
        *lock(&self.end_said)
    }

    /// A message for the child. Err: the process is over (and if this send found it stuck, it is now). A page's thread comes
    /// through here, so a full ring has a deadline: only a process that takes nothing for that long stops one.
    pub fn send(&self, kind: ToChild, ctx: u32, arg: u64, body: &[&[u8]], deadline: Option<Instant>) -> Result<(), IpcError> {
        let len = body.iter().map(|b| b.len() as u64).sum();
        let head = Head { kind: kind as u32, ctx, arg, len };
        let gone = || self.child.exit_code().is_some();
        let result = {
            let mut tx = lock(&self.tx);
            let bell = self.child.bell();
            let mut r = tx.write(&head.to_bytes(), bell, &gone, deadline);
            for b in body {
                if r.is_err() {
                    break;
                }
                r = tx.write(b, bell, &gone, deadline);
            }
            r
        };
        if let Err(e) = result {
            // (a message cut short: nothing can follow it)
            self.die(match e {
                IpcError::Gone => End::Crashed,
                IpcError::Corrupt => End::Broke,
                IpcError::Stuck => End::Hung,
            });
        }
        result
    }

    /// The process is over, whatever it was doing: killed, every context told, every waiter let go. Any thread; once.
    pub fn die(&self, end: End) {
        self.end_said_set(end);
        let first = !self.dead.swap(true, Ordering::SeqCst);
        self.child.kill();
        let _ = self.child.wait_end(END_WAIT_MS);
        let end = self.end().unwrap_or(end);
        if !first {
            return;
        }
        let why = match end {
            End::Asked => "ended",
            End::Crashed => "crashed",
            End::Hung => "stopped answering and was killed",
            End::Broke => "broke its protocol and was killed",
        };
        let code = self.child.exit_code().unwrap_or(0);
        // (counted before anyone is told: a page that restores at once meets the limit)
        self.gpu.died(self, end);
        let everyone: Vec<Arc<Shared>> = {
            let mut t = lock(&self.table);
            let v = t.entries.values().filter(|e| !e.tomb).map(|e| e.shared.clone()).collect();
            t.entries.clear();
            v
        };
        for s in &everyone {
            s.lost.store(true, Ordering::SeqCst);
            s.in_flight.store(0, Ordering::SeqCst);
            s.queued.store(0, Ordering::SeqCst);
            s.note(format!("WebGL: the GPU process {why} (exit code {code:#x}): the context was lost"));
            s.wake();
            s.ping();
        }
        for (_, slot) in lock(&self.slots).drain() {
            slot.ready.notify_all();
        }
        self.hello.ready.notify_all();
    }

    /// The watcher: the process's life, seen from outside. A context with work that does nothing for webgl.gpu_hang_ms, or a
    /// process that does not answer for as long, is killed; a process nobody needs for webgl.gpu_idle_exit_s goes.
    fn watch(self: Arc<Self>) {
        while !self.is_dead() {
            std::thread::sleep(WATCH_TICK);
            if self.is_dead() {
                break;
            }
            let limits = self.gpu.limits();
            let now = Instant::now();
            let mut hung = false;
            let mut idle = false;
            let mut ping = None;
            {
                let mut t = lock(&self.table);
                let mut work = false;
                for e in t.entries.values_mut() {
                    let pending = e.tomb || e.lose_asked || e.asked > 0 || e.shared.queued.load(Ordering::SeqCst) > 0 || e.shared.in_flight.load(Ordering::SeqCst) > 0;
                    if !pending {
                        e.progress = now;
                    } else {
                        work = true;
                        let allowed = if e.software { limits.hang * SOFTWARE_HANG_FACTOR } else { limits.hang };
                        if now.duration_since(e.progress) > allowed {
                            hung = true;
                        }
                    }
                }
                if t.entries.is_empty() {
                    idle = !limits.idle_exit.is_zero() && now.duration_since(t.empty_since) >= limits.idle_exit;
                } else {
                    t.empty_since = now;
                }
                if work {
                    // a question with no answer for that long: the process itself has stopped
                    if t.ping_sent.is_some_and(|sent| now.duration_since(sent) > limits.hang) {
                        hung = true;
                    }
                    if t.ping_sent.is_none() && now.duration_since(t.last_ping) >= PING_EVERY {
                        t.ping_seq += 1;
                        t.ping_sent = Some(now);
                        t.last_ping = now;
                        ping = Some(t.ping_seq);
                    }
                } else {
                    t.ping_sent = None;
                }
            }
            if hung {
                self.die(End::Hung);
                break;
            }
            if let Some(seq) = ping {
                // (the ring has room or is itself the sign of a hang)
                let _ = self.send(ToChild::Ping, 0, seq, &[], Some(now + limits.hang));
            }
            if idle {
                let me = self.clone();
                self.gpu.retire(&me);
            }
            if self.child.exit_code().is_some() && !self.is_dead() {
                // (the reader sees this too, through its doorbell; a child gone quiet without a word must not depend on it)
                self.die(End::Crashed);
            }
        }
        // (a process that was asked to end has a moment for it, then it is ended; this thread goes last on Linux)
        self.child.kill();
    }

    /// Everything the child says. It returns why it stopped.
    fn read_loop(&self, rx: &mut RingReader) -> IpcError {
        loop {
            match self.read_one(rx) {
                Ok(()) => {}
                Err(e) => return e,
            }
        }
    }

    fn context(&self, id: u32) -> Option<Arc<Shared>> {
        lock(&self.table).entries.get(&id).map(|e| e.shared.clone())
    }

    fn known(&self, id: u32) -> bool {
        id != 0 && (id as u64) < NEXT_ID.load(Ordering::SeqCst)
    }

    fn read_one(&self, rx: &mut RingReader) -> Result<(), IpcError> {
        let bell = self.child.bell();
        let head = rx.head(bell)?;
        let Some(kind) = ToParent::of(head.kind) else { return Err(IpcError::Corrupt) };
        let limit = match kind {
            ToParent::Hello => 256,
            ToParent::Created => 32,
            ToParent::CreateFailed => ipc::MAX_ERROR_BYTES,
            ToParent::Reply => ipc::MAX_REPLY_BYTES + REPLY_HEAD_BYTES,
            ToParent::Done | ToParent::Frame | ToParent::FrameDropped | ToParent::Lost | ToParent::Stopped => 0,
            ToParent::Restored => 4,
            ToParent::Console => ipc::MAX_CONSOLE_BYTES,
            ToParent::Pong => ipc::MAX_PONG_BYTES,
        };
        if head.len > limit {
            return Err(IpcError::Corrupt);
        }
        // a context it was told of, or none at all for what is not about one
        let about_context = !matches!(kind, ToParent::Hello | ToParent::Pong);
        if about_context && !self.known(head.ctx) {
            return Err(IpcError::Corrupt);
        }
        match kind {
            ToParent::Hello => {
                let body = rx.body(head.len, bell)?;
                let mut r = WordReader::new(&body);
                if r.u32() != Some(ipc::PROTOCOL_VERSION) || r.u32().is_none() {
                    return Err(IpcError::Corrupt);
                }
                *lock(&self.lowered) = String::from_utf8_lossy(r.rest()).into_owned();
                self.hello.put(Answer { ok: true, ..Answer::default() });
            }
            ToParent::Created | ToParent::CreateFailed => {
                let body = rx.body(head.len, bell)?;
                let Some(slot) = self.take_slot(head.arg)? else { return Ok(()) };
                let ok = kind == ToParent::Created;
                if ok {
                    let info = info_of(&body).ok_or(IpcError::Corrupt)?;
                    if let Some(e) = lock(&self.table).entries.get_mut(&head.ctx) {
                        e.software = info.software != 0;
                    }
                }
                slot.put(Answer { data: body, ok, ..Answer::default() });
            }
            ToParent::Reply => {
                if head.len < REPLY_HEAD_BYTES {
                    return Err(IpcError::Corrupt);
                }
                let mut h = [0u8; REPLY_HEAD_BYTES as usize];
                rx.read(&mut h, bell)?;
                let n = head.len - REPLY_HEAD_BYTES;
                let mut r = WordReader::new(&h);
                let has = r.u32().ok_or(IpcError::Corrupt)?;
                let _ = r.u32();
                let (first, row, stride) = (r.u64().ok_or(IpcError::Corrupt)?, r.u64().ok_or(IpcError::Corrupt)?, r.u64().ok_or(IpcError::Corrupt)?);
                let rows = if has != 0 { Some((first, row, stride)) } else { None };
                self.progress(head.ctx);
                let Some(slot) = self.take_slot(head.arg)? else {
                    // (a late answer to a question that gave up)
                    return rx.skip(n, bell);
                };
                let needed = match rows {
                    Some((f, ro, st)) => ipc::rows_end(f, ro, st, n).ok_or(IpcError::Corrupt)?,
                    None => n,
                };
                if needed > ipc::MAX_REPLY_BYTES {
                    return Err(IpcError::Corrupt);
                }
                // what does not fit the asker is not kept: it asks again with a larger buffer
                if needed > slot.cap {
                    rx.skip(n, bell)?;
                    slot.put(Answer { needed, rows, ok: true, ..Answer::default() });
                } else {
                    let data = rx.body(n, bell)?;
                    slot.put(Answer { data, needed, rows, ok: true });
                }
                self.asked(head.ctx, -1);
            }
            ToParent::Done => {
                let Some(s) = self.context(head.ctx) else { return Ok(()) };
                let q = s.queued.load(Ordering::SeqCst) as u64;
                if head.arg > q {
                    return Err(IpcError::Corrupt);
                }
                s.queued.fetch_sub(head.arg as usize, Ordering::SeqCst);
                self.progress(head.ctx);
                s.wake();
            }
            ToParent::Frame | ToParent::FrameDropped => {
                let Some(s) = self.context(head.ctx) else { return Ok(()) };
                let n = s.in_flight.load(Ordering::SeqCst);
                if n == 0 {
                    return Err(IpcError::Corrupt);
                }
                s.in_flight.store(n - 1, Ordering::SeqCst);
                self.progress(head.ctx);
                if kind == ToParent::Frame {
                    s.frames.fetch_add(1, Ordering::SeqCst);
                }
                s.wake();
                s.ping();
            }
            ToParent::Lost => {
                // (its frames are told one by one: every present gets one word back, lost or not)
                let Some(s) = self.context(head.ctx) else { return Ok(()) };
                s.lost.store(true, Ordering::SeqCst);
                if let Some(e) = lock(&self.table).entries.get_mut(&head.ctx) {
                    e.lose_asked = false;
                }
                self.progress(head.ctx);
                s.wake();
                s.ping();
            }
            ToParent::Restored => {
                let body = rx.body(head.len, bell)?;
                let mut r = WordReader::new(&body);
                let ok = r.u32().unwrap_or(0) != 0;
                self.progress(head.ctx);
                if let Some(slot) = self.take_slot(head.arg)? {
                    slot.put(Answer { ok, ..Answer::default() });
                    self.asked(head.ctx, -1);
                }
            }
            ToParent::Console => {
                let body = rx.body(head.len, bell)?;
                if let Some(s) = self.context(head.ctx) {
                    s.note(String::from_utf8_lossy(&body).into_owned());
                }
            }
            ToParent::Pong => {
                let body = rx.body(head.len, bell)?;
                self.pong(head.arg, &body)?;
            }
            ToParent::Stopped => {
                let mut t = lock(&self.table);
                if t.entries.get(&head.ctx).is_some_and(|e| e.tomb) {
                    t.entries.remove(&head.ctx);
                    if t.entries.is_empty() {
                        t.empty_since = Instant::now();
                    }
                }
            }
        }
        Ok(())
    }

    /// The slot of a question: Ok(None) when it gave up, Err when it was never asked.
    fn take_slot(&self, qid: u64) -> Result<Option<Arc<Slot>>, IpcError> {
        if qid == 0 || qid >= self.next_qid.load(Ordering::SeqCst) {
            return Err(IpcError::Corrupt);
        }
        Ok(lock(&self.slots).remove(&qid))
    }

    fn progress(&self, id: u32) {
        if let Some(e) = lock(&self.table).entries.get_mut(&id) {
            e.progress = Instant::now();
        }
    }

    fn expect_lost(&self, id: u32) {
        if let Some(e) = lock(&self.table).entries.get_mut(&id) {
            e.lose_asked = true;
            e.progress = Instant::now();
        }
    }

    fn asked(&self, id: u32, by: isize) {
        if let Some(e) = lock(&self.table).entries.get_mut(&id) {
            e.asked = e.asked.saturating_add_signed(by);
        }
    }

    fn pong(&self, seq: u64, body: &[u8]) -> Result<(), IpcError> {
        let mut t = lock(&self.table);
        if seq > t.ping_seq || (body.len() as u64) % ipc::PONG_ENTRY_BYTES != 0 {
            return Err(IpcError::Corrupt);
        }
        let now = Instant::now();
        if seq == t.ping_seq {
            t.ping_sent = None;
        }
        t.last_pong = now;
        let mut r = WordReader::new(body);
        while let (Some(id), Some(_busy), Some(ops)) = (r.u32(), r.u32(), r.u64()) {
            if let Some(e) = t.entries.get_mut(&id) {
                if e.ops != ops {
                    e.ops = ops;
                    e.progress = now;
                }
            }
        }
        Ok(())
    }

    /// A new question.
    fn ask(&self, ctx: u32, cap: u64) -> (u64, Arc<Slot>) {
        let qid = self.next_qid.fetch_add(1, Ordering::SeqCst);
        let slot = Slot::new(cap);
        lock(&self.slots).insert(qid, slot.clone());
        self.asked(ctx, 1);
        (qid, slot)
    }

    fn gave_up(&self, ctx: u32, qid: u64) {
        lock(&self.slots).remove(&qid);
        self.asked(ctx, -1);
    }
}

/// An answer's words in front of its data: has rows, nothing, first, row, stride.
const REPLY_HEAD_BYTES: u64 = 32;

/// What getContext's caller learns, as the child says it: numbers that cannot be are a broken protocol.
fn info_of(body: &[u8]) -> Option<WgInfo> {
    let mut r = WordReader::new(body);
    let mut flag = || r.u32().map(|v| (v != 0) as i32);
    let (software, has_s3tc, has_float_linear, has_float_blend) = (flag()?, flag()?, flag()?, flag()?);
    let (max_samples, width, height) = (r.u32()?, r.u32()?, r.u32()?);
    let antialias = (r.u32()? != 0) as i32;
    if !(1..=crate::gl::MAX_REPORTED_SAMPLES).contains(&max_samples) || !r.rest().is_empty() {
        return None;
    }
    Some(WgInfo { software, has_s3tc, has_float_linear, has_float_blend, max_samples, width, height, antialias })
}

/// Numbers of contexts, in the whole browser: a number means one context, whichever process it is in.
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// A context as the browser holds it.
pub struct Handle {
    gpu: &'static Gpu,
    id: u32,
    attrs: WgAttrs,
    shared: Arc<Shared>,
    wait: Duration,
    state: Mutex<Binding>,
    /// A refused restart was said on the console (the script tries again for a while: once is enough).
    refusal_said: AtomicBool,
}

/// What may change under a Handle: its process and where its frames are. A lock of the page's thread alone: never held across a wait.
struct Binding {
    proc: Option<Arc<Proc>>,
    frames: Option<FrameSection>,
    w: u32,
    h: u32,
}

struct FrameSection {
    section: sys::Section,
    view: ipc::FrameView,
    /// Told to this process.
    told: bool,
}

impl Binding {
    /// The section for the canvas's size, made and told to the process when it is new.
    fn ensure_frames(&mut self, id: u32, wait: Duration) -> Option<()> {
        let (w, h) = (self.w, self.h);
        let bytes = ipc::frame_section_bytes(w, h)?;
        if self.frames.as_ref().is_none_or(|f| f.view.w != w || f.view.h != h) {
            let section = sys::Section::create(bytes.max(1)).ok()?;
            let mut view = unsafe { ipc::FrameView::new(section.base(), bytes, w, h, false)? };
            view.reset(false);
            self.frames = Some(FrameSection { section, view, told: false });
        }
        let f = self.frames.as_mut()?;
        if f.told {
            return Some(());
        }
        let proc = self.proc.as_ref()?;
        let token = proc.child.share(&f.section)?;
        let mut body = Words::default();
        body.u64(token).u64(bytes).u32(w).u32(h);
        proc.send(ToChild::Target, id, 0, &[&body.0], Some(Instant::now() + wait)).ok()?;
        f.told = true;
        Some(())
    }
}

pub(crate) fn wire_attrs(a: &WgAttrs) -> Vec<u8> {
    let mut w = Words::default();
    w.u32(a.webgl2 as u32).u32(a.alpha as u32).u32(a.depth as u32).u32(a.stencil as u32).u32(a.antialias as u32).u32(a.premultiplied as u32).u32(a.preserve as u32).u32(a.fail_if_major_performance_caveat as u32);
    w.u32(a.width).u32(a.height).u32(a.max_dimension).u32(a.allow_software as u32).u32(a.force_software as u32).u32(a.backend as u32).u64(a.max_bytes);
    w.0
}

impl Handle {
    /// A context: in a process, started now if it is the browser's first.
    pub fn create(gpu: &'static Gpu, a: &WgAttrs) -> Result<(Box<Handle>, WgInfo), String> {
        if let Ok(mut l) = gpu.limits.lock() {
            *l = Some(Limits::of(a));
        }
        let wait = Duration::from_millis(a.wait_ms.max(100) as u64);
        let id = NEXT_ID.fetch_add(1, Ordering::SeqCst) as u32;
        let shared = Shared::new(a);
        let entry = Entry { shared: shared.clone(), tomb: false, software: a.force_software != 0, ops: 0, progress: Instant::now(), asked: 0, lose_asked: false };
        let proc = gpu.ensure(id, entry, wait)?;
        let mut attrs = *a;
        attrs.notify = None;
        attrs.notify_user = std::ptr::null_mut();
        let info = Self::make_in(&proc, id, &attrs, wait)?;
        let h = Box::new(Handle { gpu, id, attrs, shared, wait, state: Mutex::new(Binding { proc: Some(proc), frames: None, w: a.width, h: a.height }), refusal_said: AtomicBool::new(false) });
        Ok((h, info))
    }

    /// Asks the process for this context and waits for it.
    fn make_in(proc: &Arc<Proc>, id: u32, a: &WgAttrs, wait: Duration) -> Result<WgInfo, String> {
        let (qid, slot) = proc.ask(id, 256);
        let deadline = Instant::now() + wait;
        let abandon = || {
            proc.gave_up(id, qid);
            if let Some(e) = lock(&proc.table).entries.get_mut(&id) {
                e.tomb = true;
            }
            let _ = proc.send(ToChild::Destroy, id, 0, &[], Some(deadline));
        };
        if proc.send(ToChild::Create, id, qid, &[&wire_attrs(a)], Some(deadline)).is_err() {
            return Err("the GPU process ended".to_string());
        }
        let Some(answer) = slot.wait(deadline, &proc.dead) else {
            let ended = proc.is_dead();
            abandon();
            return Err(if ended { "the GPU process ended".to_string() } else { "the device did not answer in time".to_string() });
        };
        proc.asked(id, -1);
        if !answer.ok {
            lock(&proc.table).entries.remove(&id);
            let _ = proc.send(ToChild::Destroy, id, 0, &[], Some(deadline));
            return Err(String::from_utf8_lossy(&answer.data).into_owned());
        }
        info_of(&answer.data).ok_or_else(|| "the device's answer makes no sense".to_string())
    }

    fn proc(&self) -> Option<Arc<Proc>> {
        lock(&self.state).proc.clone()
    }

    pub fn shared(&self) -> &Shared {
        &self.shared
    }

    pub fn current_process(&self) -> Option<Arc<Proc>> {
        self.proc()
    }

    pub fn id(&self) -> u32 {
        self.id
    }

    /// The handle's end: no callback after this returns, the thread frees everything in its own time.
    pub fn destroy(&self) {
        self.shared.silence();
        let Some(proc) = self.proc() else { return };
        if proc.is_dead() {
            return;
        }
        if let Some(e) = lock(&proc.table).entries.get_mut(&self.id) {
            e.tomb = true;
        }
        let _ = proc.send(ToChild::Destroy, self.id, 0, &[], Some(Instant::now() + self.wait));
    }

    /// Commands: a header and a body (either may be empty). They go straight into the ring.
    pub fn submit(&self, a: &[u8], b: &[u8]) {
        if self.shared.lost.load(Ordering::SeqCst) || (a.is_empty() && b.is_empty()) {
            return;
        }
        let Some(proc) = self.proc() else { return };
        let total = a.len() + b.len();
        // too much waiting already: the page's thread waits for a while, then the context goes
        let queued = self.shared.queued.load(Ordering::SeqCst);
        if queued + total > MAX_QUEUED_BYTES && queued > 0 {
            let deadline = Instant::now() + BACKPRESSURE_WAIT;
            if let Ok(mut g) = self.shared.state_change.lock() {
                while self.shared.queued.load(Ordering::SeqCst) + total > MAX_QUEUED_BYTES && self.shared.queued.load(Ordering::SeqCst) > 0 {
                    let now = Instant::now();
                    if now >= deadline {
                        break;
                    }
                    match self.shared.state_changed.wait_timeout(g, deadline - now) {
                        Ok(x) => g = x.0,
                        Err(_) => return,
                    }
                }
            }
        }
        self.shared.queued.fetch_add(total, Ordering::SeqCst);
        let _ = proc.send(ToChild::Commands, self.id, 0, &[a, b], Some(Instant::now() + self.wait));
    }

    /// Waits for an answer: into (out, cap), its length, or the length needed when it does not fit (nothing is written); -1: the
    /// deadline passed or the context is gone (the context is then lost). When the answer is rows of pixels, they land at their
    /// offsets and what is outside stays.
    ///
    /// # Safety
    /// `out` holds `cap` bytes.
    pub unsafe fn query(&self, req: &[u8], out: *mut u8, cap: usize) -> i64 {
        if self.shared.lost.load(Ordering::SeqCst) {
            return -1;
        }
        let Some(proc) = self.proc() else { return -1 };
        let deadline = Instant::now() + self.wait;
        let (qid, slot) = proc.ask(self.id, cap as u64);
        if proc.send(ToChild::Query, self.id, qid, &[req], Some(deadline)).is_err() {
            proc.gave_up(self.id, qid);
            return -1;
        }
        let Some(a) = slot.wait(deadline, &self.shared.lost) else {
            proc.gave_up(self.id, qid);
            if !self.shared.lost.swap(true, Ordering::SeqCst) {
                self.shared.note("WebGL: the context did not answer in time and was lost".to_string());
            }
            // (if its thread is hung, the watcher ends the process: the thread cannot be left behind)
            proc.expect_lost(self.id);
            let _ = proc.send(ToChild::Lose, self.id, 0, &[], Some(deadline + self.wait));
            return -1;
        };
        // rows and lengths were checked against each other when the answer came (Proc::read_one), against `cap` here
        if a.needed > cap as u64 || out.is_null() && a.needed > 0 {
            return a.needed as i64;
        }
        if let Some((first, row, stride)) = a.rows {
            if row > 0 {
                let rows = a.data.len() as u64 / row;
                for r in 0..rows {
                    let at = first + r * stride;
                    std::ptr::copy_nonoverlapping(a.data[(r * row) as usize..].as_ptr(), out.add(at as usize), row as usize);
                }
            }
            return a.data.len() as i64;
        }
        if !a.data.is_empty() {
            std::ptr::copy_nonoverlapping(a.data.as_ptr(), out, a.data.len());
        }
        a.data.len() as i64
    }

    /// Asks for the drawing buffer as the canvas's next frame. A page drawing faster than the GPU waits here, a little.
    pub fn present(&self) {
        if self.shared.lost.load(Ordering::SeqCst) {
            return;
        }
        if self.shared.in_flight.load(Ordering::SeqCst) >= MAX_FRAMES_IN_FLIGHT {
            let deadline = Instant::now() + BACKPRESSURE_WAIT;
            if let Ok(mut g) = self.shared.state_change.lock() {
                while self.shared.in_flight.load(Ordering::SeqCst) >= MAX_FRAMES_IN_FLIGHT {
                    let now = Instant::now();
                    if now >= deadline {
                        return; // no frame this time
                    }
                    match self.shared.state_changed.wait_timeout(g, deadline - now) {
                        Ok(x) => g = x.0,
                        Err(_) => return,
                    }
                }
            }
        }
        let proc = {
            let mut b = lock(&self.state);
            if b.ensure_frames(self.id, self.wait).is_none() {
                self.shared.note("WebGL: no memory for the canvas's frames".to_string());
                return;
            }
            b.proc.clone()
        };
        let Some(proc) = proc else { return };
        self.shared.in_flight.fetch_add(1, Ordering::SeqCst);
        let _ = proc.send(ToChild::Present, self.id, 0, &[], Some(Instant::now() + self.wait));
    }

    /// The drawing buffer now, for toDataURL, drawImage and the like: waits. Does not count as a presented frame.
    /// With `commit`, it also ends the frame: the drawing buffer starts again as after a present (transferToImageBitmap).
    pub fn snapshot(&self, commit: bool) -> bool {
        if self.shared.lost.load(Ordering::SeqCst) {
            return false;
        }
        let proc = {
            let mut b = lock(&self.state);
            if b.ensure_frames(self.id, self.wait).is_none() {
                return false;
            }
            b.proc.clone()
        };
        let Some(proc) = proc else { return false };
        let deadline = Instant::now() + self.wait;
        let (qid, slot) = proc.ask(self.id, 0);
        self.shared.in_flight.fetch_add(1, Ordering::SeqCst);
        if proc.send(if commit { ToChild::Commit } else { ToChild::Snapshot }, self.id, qid, &[], Some(deadline)).is_err() {
            proc.gave_up(self.id, qid);
            return false;
        }
        let got = slot.wait(deadline, &self.shared.lost).is_some();
        if !got {
            proc.gave_up(self.id, qid);
        }
        got
    }

    /// Copies the latest frame into a bitmap of this size (premultiplied RGBA8, top row first) if a new one came since the last
    /// call: FRAME_NONE, FRAME_NEW or FRAME_OPAQUE.
    ///
    /// # Safety
    /// `dst` holds `height` rows of `stride` bytes.
    pub unsafe fn take_frame(&self, dst: *mut u8, w: u32, height: u32, stride: u32) -> i32 {
        if dst.is_null() || (stride as u64) < w as u64 * 4 {
            return crate::FRAME_NONE;
        }
        let mut b = lock(&self.state);
        let Some(f) = b.frames.as_mut() else { return crate::FRAME_NONE };
        match f.view.take(dst, w, height, stride) {
            Ok(Some(true)) => crate::FRAME_OPAQUE,
            Ok(Some(false)) => crate::FRAME_NEW,
            Ok(None) => crate::FRAME_NONE,
            Err(_) => {
                let proc = b.proc.clone();
                drop(b);
                if let Some(p) = proc {
                    p.die(End::Broke);
                }
                crate::FRAME_NONE
            }
        }
    }

    pub fn resize(&self, w: u32, h: u32) {
        let proc = {
            let mut b = lock(&self.state);
            b.w = w;
            b.h = h;
            b.proc.clone()
        };
        if let Some(proc) = proc {
            let mut body = Words::default();
            body.u32(w).u32(h);
            let _ = proc.send(ToChild::Resize, self.id, 0, &[&body.0], Some(Instant::now() + self.wait));
        }
    }

    /// WEBGL_lose_context.loseContext.
    pub fn lose(&self) {
        self.shared.lost.store(true, Ordering::SeqCst);
        if let Some(proc) = self.proc() {
            proc.expect_lost(self.id);
            let _ = proc.send(ToChild::Lose, self.id, 0, &[], Some(Instant::now() + self.wait));
        }
    }

    /// A new device for a lost context, in a new process when its own has ended and the limit on restarts allows one. Its objects are
    /// gone; the page builds them again.
    pub fn restore(&self) -> bool {
        let current = self.proc();
        let result = match current {
            Some(p) if !p.is_dead() => self.restore_in(&p),
            _ => self.rebind(),
        };
        if result {
            self.shared.lost.store(false, Ordering::SeqCst);
        }
        result
    }

    fn restore_in(&self, p: &Arc<Proc>) -> bool {
        // (its thread has not said it let go: it may be stuck, and then only the end of the process frees it; the page's thread
        // does not wait for that here, the script tries again)
        if lock(&p.table).entries.get(&self.id).is_some_and(|e| e.lose_asked) {
            return false;
        }
        let deadline = Instant::now() + self.wait;
        let (qid, slot) = p.ask(self.id, 0);
        if p.send(ToChild::Restore, self.id, qid, &[], Some(deadline)).is_err() {
            p.gave_up(self.id, qid);
            return false;
        }
        match slot.wait(deadline, &p.dead) {
            Some(a) => a.ok,
            None => {
                p.gave_up(self.id, qid);
                false
            }
        }
    }

    /// The context again, in the process that runs now (or a new one).
    fn rebind(&self) -> bool {
        let entry = Entry { shared: self.shared.clone(), tomb: false, software: self.attrs.force_software != 0, ops: 0, progress: Instant::now(), asked: 0, lose_asked: false };
        let proc = match self.gpu.ensure(self.id, entry, self.wait) {
            Ok(p) => p,
            Err(e) => {
                if !self.refusal_said.swap(true, Ordering::SeqCst) {
                    self.shared.note(format!("WebGL: {e}"));
                }
                return false;
            }
        };
        self.refusal_said.store(false, Ordering::SeqCst);
        let mut a = self.attrs;
        a.fail_if_major_performance_caveat = 0;
        {
            let b = lock(&self.state);
            a.width = b.w;
            a.height = b.h;
        }
        match Self::make_in(&proc, self.id, &a, self.wait) {
            Ok(_) => {
                let mut b = lock(&self.state);
                b.proc = Some(proc);
                // (the section stays; the new process is told of it at the next frame, and nothing old is in it for it)
                if let Some(f) = b.frames.as_mut() {
                    f.told = false;
                    f.view.reset(false);
                }
                true
            }
            Err(e) => {
                self.shared.note(format!("WebGL: {e}"));
                false
            }
        }
    }
}


#[cfg(test)]
impl Handle {
    pub fn test_set_wait(&mut self, d: Duration) {
        self.wait = d;
    }
    pub fn test_misbehave(&self, kind: u32, qid: u64) {
        if let Some(p) = self.proc() {
            let _ = p.send(ToChild::TestMisbehave, self.id, kind as u64 | qid << 8, &[], Some(Instant::now() + self.wait));
        }
    }
    /// A question whose answer will come from `test_misbehave`: its id and slot.
    pub fn test_ask(&self) -> Option<(u64, Arc<Slot>)> {
        self.proc().map(|p| p.ask(self.id, 1 << 20))
    }
    /// Raw bytes on the channel to the child.
    pub fn test_raw(&self, bytes: &[u8]) -> Result<(), IpcError> {
        let Some(p) = self.proc() else { return Err(IpcError::Gone) };
        let gone = || p.child.exit_code().is_some();
        let mut tx = lock(&p.tx);
        tx.write(bytes, p.child.bell(), &gone, Some(Instant::now() + self.wait))
    }
    pub fn test_frame_scribble(&self, slot_word: u32, w: u32, h: u32) {
        if let Some(f) = lock(&self.state).frames.as_mut() {
            f.view.test_scribble(slot_word, w, h);
        }
    }
}

/// A child for hostile tests and kills: makes a question fail or the process hang on demand (test tools).
pub fn test_hook(h: &Handle, kind: u32) -> bool {
    match h.proc() {
        Some(p) if !p.is_dead() => p.send(ToChild::TestMisbehave, h.id, kind as u64, &[], Some(Instant::now() + h.wait)).is_ok(),
        _ => false,
    }
}
