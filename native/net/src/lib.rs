//! Wren's network stack behind a C ABI for package net (src/net/rust.odin): HTTP/1.1, HTTP/2, HTTP/3 raced against TCP,
//! WebSockets, TLS 1.2 / 1.3 verified against the operating system's trust store, the system resolver and proxy.
//!
//! Mechanism only, as WinHTTP was: no cookies, no redirects followed, no ambient credentials, no cache. Package net keeps
//! its queues, limits, throttling, handles and scopes; this library runs one request (or socket) at a time when asked.
//!
//! Threading: a tokio runtime with its own threads runs every request. Results never call into the host's code with
//! data: they wait in a queue owned here, and the host is told once per burst through `notify` (which posts a task to
//! its event loop, `host.post`). The loop thread then takes the events one by one with `wn_net_poll`; the bytes of the
//! event it took stay valid until its next call (memory allocated here is freed here).
//!
//! Every entry point catches panics, and so does every task: a bug is a failed request, not a dead browser.

use std::collections::{HashMap, VecDeque};
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

mod conn;
mod decode;
mod error;
mod h3conn;
mod http;
mod ws;

pub(crate) use error::NetError;

/// Event kinds; the same numbers as package net (src/net/rust.odin).
pub(crate) const EV_HEADERS: u32 = 0;
pub(crate) const EV_DATA: u32 = 1;
pub(crate) const EV_DONE: u32 = 2;
pub(crate) const EV_FAILED: u32 = 3;
pub(crate) const EV_WS_HEADERS: u32 = 16;
pub(crate) const EV_WS_HANDSHAKE_FAILED: u32 = 17;
pub(crate) const EV_WS_MESSAGE: u32 = 18;
pub(crate) const EV_WS_PEER_CLOSE: u32 = 19;
pub(crate) const EV_WS_WRITE_DONE: u32 = 20;
pub(crate) const EV_WS_SHUTDOWN_DONE: u32 = 21;
pub(crate) const EV_WS_ERROR: u32 = 22;

pub type NotifyFn = extern "C" fn(user: *mut c_void);

/// The transport settings (package net's Settings, from the `network.*` preferences). Durations in ms, 0 = none.
#[repr(C)]
pub struct WnConfig {
    pub user_agent: *const u8,
    pub user_agent_len: usize,
    pub extra_ca_pem: *const u8, // more trusted authorities (PEM), on top of the system's
    pub extra_ca_pem_len: usize,
    pub timeout_resolve_ms: u32,
    pub timeout_connect_ms: u32,
    pub timeout_send_ms: u32,
    pub timeout_receive_ms: u32,
    pub read_chunk: u64,
    pub high_water: u64,
    pub low_water: u64,
    pub idle_timeout_ms: u32,
    pub max_idle_per_host: u32,
    pub h3_race_ms: u32,          // how long QUIC has before TCP starts too
    pub h3_broken_ms: u32,        // how long a host where QUIC failed is left to TCP
    pub threads: u32,
    pub http2: u8,
    pub http3: u8,
    pub proxy_system: u8,
    pub _pad: u8,
}

#[derive(Clone)]
pub(crate) struct Settings {
    pub user_agent: String,
    pub resolve: Option<Duration>,
    pub connect: Option<Duration>,
    pub send: Option<Duration>,
    pub receive: Option<Duration>,
    pub read_chunk: usize,
    pub high_water: usize,
    pub low_water: usize,
    pub h3_race: Duration,
    pub h3_broken: Duration,
    pub http2: bool,
    pub http3: bool,
    pub proxy_system: bool,
}

fn ms(v: u32) -> Option<Duration> {
    (v > 0).then(|| Duration::from_millis(v as u64))
}

unsafe fn bytes<'a>(p: *const u8, n: usize) -> &'a [u8] {
    if p.is_null() || n == 0 { &[] } else { std::slice::from_raw_parts(p, n) }
}

impl Settings {
    unsafe fn from(c: &WnConfig) -> Settings {
        let high = (c.high_water as usize).max(4096);
        Settings {
            user_agent: String::from_utf8_lossy(bytes(c.user_agent, c.user_agent_len)).into_owned(),
            resolve: ms(c.timeout_resolve_ms),
            connect: ms(c.timeout_connect_ms),
            send: ms(c.timeout_send_ms),
            receive: ms(c.timeout_receive_ms),
            read_chunk: (c.read_chunk as usize).clamp(1024, 16 << 20),
            high_water: high,
            low_water: (c.low_water as usize).min(high),
            h3_race: Duration::from_millis(c.h3_race_ms as u64),
            h3_broken: Duration::from_millis(c.h3_broken_ms as u64),
            http2: c.http2 != 0,
            http3: c.http3 != 0,
            proxy_system: c.proxy_system != 0,
        }
    }
}

/// One event as the library keeps it until the host took it.
#[derive(Default)]
pub(crate) struct Ev {
    pub kind: u32,
    pub tag: u64,
    pub status: u32,
    pub error: u32,
    pub secure_flags: u32,
    pub protocol: u32,
    pub btype: u32,
    pub code: u32,
    pub op: u32,
    pub n: u64,
    pub headers: Vec<u8>,
    pub url: Vec<u8>,
    pub data: Vec<u8>,
    pub timing: [f32; 9],
    pub remote: Vec<u8>,
}

/// An event as the host reads it (`wn_net_poll`): pointers valid until the next poll.
#[repr(C)]
pub struct WnEvent {
    pub kind: u32,
    pub status: u32,
    pub tag: u64,
    pub error: u32,
    pub secure_flags: u32,
    pub protocol: u32,
    pub btype: u32,
    pub code: u32,
    pub op: u32,
    pub n: u64,
    pub headers: *const u8,
    pub headers_len: usize,
    pub url: *const u8,
    pub url_len: usize,
    pub data: *const u8,
    pub data_len: usize,
    /// ms from the moment the library was handed the request (-1: did not happen): started, dns_start, dns_end,
    /// connect_start, connect_end, sending, sent, response, done
    pub timing: [f32; 9],
    pub remote_len: u32,
    pub remote: [u8; 48],
}

#[derive(Clone, Copy)]
struct SendPtr(*mut c_void);
unsafe impl Send for SendPtr {}
unsafe impl Sync for SendPtr {}

struct Queue {
    events: VecDeque<Ev>,
    pending: bool, // the host was notified and has not emptied the queue since
}

/// What a request or socket shares with its task.
pub(crate) struct ReqState {
    pub tag: u64,
    pub queued: AtomicUsize,  // bytes handed to the host and not consumed yet
    pub max_body: AtomicU64,
    pub wake: tokio::sync::Notify,
}

struct Running {
    state: Arc<ReqState>,
    abort: Option<tokio::task::AbortHandle>,
    ws: Option<tokio::sync::mpsc::UnboundedSender<ws::Cmd>>,
}

/// What the connections need, shared by the HTTP client's connector, the WebSockets and HTTP/3.
pub(crate) struct Shared {
    pub settings: RwLock<Settings>,
    pub tls_h2: Arc<rustls::ClientConfig>,     // ALPN h2, http/1.1
    pub tls_h1: Arc<rustls::ClientConfig>,     // ALPN http/1.1 (WebSockets, HTTP/2 turned off)
    pub tls_h3: Arc<rustls::ClientConfig>,     // ALPN h3
    pub proxy: Option<hyper_util::client::proxy::matcher::Matcher>,
}

impl Shared {
    pub fn settings(&self) -> Settings {
        self.settings.read().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

pub(crate) struct Inner {
    pub shared: Arc<Shared>,
    pub http: http::HttpClient,
    pub h3: h3conn::H3,
    queue: Mutex<Queue>,
    notify: NotifyFn,
    user: SendPtr,
    running: Mutex<HashMap<u64, Running>>,
    next_id: AtomicU64,
    closed: AtomicBool,
}

impl Inner {
    pub fn push(&self, ev: Ev) {
        if self.closed.load(Ordering::Acquire) { return; }
        let call = {
            let mut q = self.queue.lock().unwrap_or_else(|e| e.into_inner());
            q.events.push_back(ev);
            let first = !q.pending;
            q.pending = true;
            first
        };
        if call && !self.closed.load(Ordering::Acquire) {
            (self.notify)(self.user.0);
        }
    }

    pub fn finished(&self, id: u64) {
        self.running.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
    }

    pub fn fail(&self, tag: u64, kind: u32, e: NetError) {
        self.push(Ev { kind, tag, error: e.code, secure_flags: e.flags, ..Default::default() });
    }
}

pub struct Client {
    rt: Option<tokio::runtime::Runtime>,
    inner: Arc<Inner>,
    current: Option<Ev>,
}

fn build_tls(extra: &[u8], alpn: &[&[u8]]) -> Result<rustls::ClientConfig, rustls::Error> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = if extra.is_empty() {
        rustls_platform_verifier::Verifier::new(provider.clone())?
    } else {
        use rustls::pki_types::pem::PemObject;
        let roots: Vec<_> = rustls::pki_types::CertificateDer::pem_slice_iter(extra).filter_map(|c| c.ok()).collect();
        rustls_platform_verifier::Verifier::new_with_extra_roots(roots, provider.clone())?
    };
    let mut cfg = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13, &rustls::version::TLS12])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth();
    cfg.alpn_protocols = alpn.iter().map(|p| p.to_vec()).collect();
    Ok(cfg)
}

/// Starts the library's threads. Null when TLS could not be set up.
#[no_mangle]
pub unsafe extern "C" fn wn_net_create(cfg: *const WnConfig, notify: NotifyFn, user: *mut c_void) -> *mut Client {
    catch_unwind(AssertUnwindSafe(|| {
        let cfg = &*cfg;
        let settings = Settings::from(cfg);
        let extra = bytes(cfg.extra_ca_pem, cfg.extra_ca_pem_len);
        let (Ok(tls_h2), Ok(tls_h1), Ok(mut tls_h3)) =
            (build_tls(extra, &[b"h2", b"http/1.1"]), build_tls(extra, &[b"http/1.1"]), build_tls(extra, &[b"h3"]))
        else {
            return std::ptr::null_mut();
        };
        tls_h3.enable_early_data = false;
        let threads = cfg.threads.clamp(1, 64) as usize;
        let Ok(rt) = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(threads)
            .thread_name("wren-net")
            .enable_io()
            .enable_time()
            .build()
        else {
            return std::ptr::null_mut();
        };
        let proxy = Some(hyper_util::client::proxy::matcher::Matcher::from_system());
        let shared = Arc::new(Shared {
            settings: RwLock::new(settings),
            tls_h2: Arc::new(tls_h2),
            tls_h1: Arc::new(tls_h1),
            tls_h3: Arc::new(tls_h3),
            proxy,
        });
        let http = {
            let _g = rt.enter();
            http::build_client(shared.clone(), cfg.idle_timeout_ms, cfg.max_idle_per_host)
        };
        let inner = Arc::new(Inner {
            h3: h3conn::H3::new(shared.clone()),
            shared,
            http,
            queue: Mutex::new(Queue { events: VecDeque::new(), pending: false }),
            notify,
            user: SendPtr(user),
            running: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            closed: AtomicBool::new(false),
        });
        Box::into_raw(Box::new(Client { rt: Some(rt), inner, current: None }))
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Cancels everything and stops the threads. `notify` is not called once this returns.
#[no_mangle]
pub unsafe extern "C" fn wn_net_destroy(c: *mut Client) {
    if c.is_null() { return; }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let mut c = Box::from_raw(c);
        c.inner.closed.store(true, Ordering::Release);
        let all: Vec<Running> = c.inner.running.lock().unwrap_or_else(|e| e.into_inner()).drain().map(|(_, r)| r).collect();
        for r in &all {
            if let Some(a) = &r.abort { a.abort(); }
        }
        drop(all);
        if let Some(rt) = c.rt.take() {
            rt.shutdown_timeout(Duration::from_secs(5));
        }
        c.inner.h3.clear();
    }));
}

/// Timeouts and back-pressure marks apply to what starts (and reads) next; the rest is fixed at creation.
#[no_mangle]
pub unsafe extern "C" fn wn_net_configure(c: *mut Client, cfg: *const WnConfig) {
    if c.is_null() || cfg.is_null() { return; }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let c = &*c;
        let new = Settings::from(&*cfg);
        let mut s = c.inner.shared.settings.write().unwrap_or_else(|e| e.into_inner());
        let (agent, h2, h3, proxy) = (s.user_agent.clone(), s.http2, s.http3, s.proxy_system);
        *s = new;
        s.user_agent = agent;
        s.http2 = h2;
        s.http3 = h3;
        s.proxy_system = proxy;
    }));
}

#[repr(C)]
pub struct WnRequest {
    pub tag: u64,
    pub url: *const u8,
    pub url_len: usize,
    pub method: *const u8,
    pub method_len: usize,
    pub headers: *const u8, // "Name: value\r\nName: value"
    pub headers_len: usize,
    pub body: *const u8,
    pub body_len: usize,
    pub max_body: u64,
}

fn register(inner: &Arc<Inner>, tag: u64, max_body: u64) -> (u64, Arc<ReqState>) {
    let id = inner.next_id.fetch_add(1, Ordering::Relaxed);
    let st = Arc::new(ReqState {
        tag,
        queued: AtomicUsize::new(0),
        max_body: AtomicU64::new(max_body),
        wake: tokio::sync::Notify::new(),
    });
    (id, st)
}

/// Starts a request; its events carry `tag`. Returns the request's id (never 0).
#[no_mangle]
pub unsafe extern "C" fn wn_net_request(c: *mut Client, r: *const WnRequest) -> u64 {
    if c.is_null() || r.is_null() { return 0; }
    catch_unwind(AssertUnwindSafe(|| {
        let c = &*c;
        let r = &*r;
        let desc = http::Desc {
            url: String::from_utf8_lossy(bytes(r.url, r.url_len)).into_owned(),
            method: bytes(r.method, r.method_len).to_vec(),
            headers: bytes(r.headers, r.headers_len).to_vec(),
            body: bytes::Bytes::copy_from_slice(bytes(r.body, r.body_len)),
            start: Instant::now(),
        };
        let inner = c.inner.clone();
        let (id, st) = register(&inner, r.tag, if r.max_body == 0 { u64::MAX } else { r.max_body });
        let mut running = inner.running.lock().unwrap_or_else(|e| e.into_inner());
        let rt = c.rt.as_ref().unwrap();
        let task = rt.spawn(http::run(inner.clone(), id, st.clone(), desc));
        running.insert(id, Running { state: st, abort: Some(task.abort_handle()), ws: None });
        id
    }))
    .unwrap_or(0)
}

/// Silent: no event of the request is delivered any more (those already queued are dropped by the host).
#[no_mangle]
pub unsafe extern "C" fn wn_net_cancel(c: *mut Client, id: u64) {
    if c.is_null() { return; }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let c = &*c;
        let r = c.inner.running.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
        if let Some(r) = r {
            if let Some(a) = &r.abort { a.abort(); }
        }
    }));
}

/// The host consumed `n` bytes of the request's (or socket's) data: reading resumes under the low-water mark.
#[no_mangle]
pub unsafe extern "C" fn wn_net_consumed(c: *mut Client, id: u64, n: u64) {
    if c.is_null() { return; }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let c = &*c;
        let st = c.inner.running.lock().unwrap_or_else(|e| e.into_inner()).get(&id).map(|r| r.state.clone());
        if let Some(st) = st {
            // (the reader compares with its own low-water mark when woken)
            let _ = st.queued.fetch_update(Ordering::AcqRel, Ordering::Acquire, |q| Some(q.saturating_sub(n as usize)));
            st.wake.notify_one();
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn wn_net_set_max_body(c: *mut Client, id: u64, max_body: u64) {
    if c.is_null() { return; }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let c = &*c;
        if let Some(r) = c.inner.running.lock().unwrap_or_else(|e| e.into_inner()).get(&id) {
            r.state.max_body.store(if max_body == 0 { u64::MAX } else { max_body }, Ordering::Release);
        }
    }));
}

/// Takes the next event (false: the queue is empty, and the next event notifies again). Loop thread only.
#[no_mangle]
pub unsafe extern "C" fn wn_net_poll(c: *mut Client, out: *mut WnEvent) -> u8 {
    if c.is_null() || out.is_null() { return 0; }
    catch_unwind(AssertUnwindSafe(|| {
        let c = &mut *c;
        c.current = None;
        let ev = {
            let mut q = c.inner.queue.lock().unwrap_or_else(|e| e.into_inner());
            match q.events.pop_front() {
                Some(ev) => ev,
                None => {
                    q.pending = false;
                    return 0;
                }
            }
        };
        let o = &mut *out;
        o.kind = ev.kind;
        o.status = ev.status;
        o.tag = ev.tag;
        o.error = ev.error;
        o.secure_flags = ev.secure_flags;
        o.protocol = ev.protocol;
        o.btype = ev.btype;
        o.code = ev.code;
        o.op = ev.op;
        o.n = ev.n;
        o.headers = ev.headers.as_ptr();
        o.headers_len = ev.headers.len();
        o.url = ev.url.as_ptr();
        o.url_len = ev.url.len();
        o.data = ev.data.as_ptr();
        o.data_len = ev.data.len();
        o.timing = ev.timing;
        let n = ev.remote.len().min(48);
        o.remote = [0; 48];
        o.remote[..n].copy_from_slice(&ev.remote[..n]);
        o.remote_len = n as u32;
        c.current = Some(ev);
        1
    }))
    .unwrap_or(0)
}

#[repr(C)]
pub struct WnWsOpen {
    pub tag: u64,
    pub url: *const u8,
    pub url_len: usize,
    pub headers: *const u8,
    pub headers_len: usize,
    pub max_message: u64,
    pub high_water: u64,
    pub low_water: u64,
    pub keepalive_ms: u32,
    pub _pad: u32,
}

/// Starts a WebSocket handshake (ws: or wss:); its events carry `tag`. Returns the socket's id (never 0).
#[no_mangle]
pub unsafe extern "C" fn wn_ws_open(c: *mut Client, d: *const WnWsOpen) -> u64 {
    if c.is_null() || d.is_null() { return 0; }
    catch_unwind(AssertUnwindSafe(|| {
        let c = &*c;
        let d = &*d;
        let desc = ws::Desc {
            url: String::from_utf8_lossy(bytes(d.url, d.url_len)).into_owned(),
            headers: bytes(d.headers, d.headers_len).to_vec(),
            max_message: d.max_message as usize,
            keepalive: ms(d.keepalive_ms),
            high_water: (d.high_water as usize).max(1),
            low_water: (d.low_water as usize).min(d.high_water as usize),
        };
        let inner = c.inner.clone();
        let (id, st) = register(&inner, d.tag, u64::MAX);
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let mut running = inner.running.lock().unwrap_or_else(|e| e.into_inner());
        let task = c.rt.as_ref().unwrap().spawn(ws::run(inner.clone(), id, st.clone(), desc, rx));
        running.insert(id, Running { state: st, abort: Some(task.abort_handle()), ws: Some(tx) });
        id
    }))
    .unwrap_or(0)
}

unsafe fn ws_cmd(c: *mut Client, id: u64, cmd: ws::Cmd) -> u8 {
    if c.is_null() { return 0; }
    catch_unwind(AssertUnwindSafe(|| {
        let c = &*c;
        let running = c.inner.running.lock().unwrap_or_else(|e| e.into_inner());
        match running.get(&id).and_then(|r| r.ws.as_ref()) {
            Some(tx) => tx.send(cmd).is_ok() as u8,
            None => 0,
        }
    }))
    .unwrap_or(0)
}

/// Completes the upgrade after the WebSocket headers event.
#[no_mangle]
pub unsafe extern "C" fn wn_ws_accept(c: *mut Client, id: u64) -> u8 {
    ws_cmd(c, id, ws::Cmd::Accept)
}

/// Sends one message (copied). A write-done event follows.
#[no_mangle]
pub unsafe extern "C" fn wn_ws_send(c: *mut Client, id: u64, binary: u8, data: *const u8, len: usize) -> u8 {
    ws_cmd(c, id, ws::Cmd::Send { binary: binary != 0, data: bytes(data, len).to_vec() })
}

/// Sends our close frame (1005: an empty one). A shutdown-done event follows.
#[no_mangle]
pub unsafe extern "C" fn wn_ws_shutdown(c: *mut Client, id: u64, code: u16, reason: *const u8, len: usize) -> u8 {
    ws_cmd(c, id, ws::Cmd::Shutdown { code, reason: bytes(reason, len).to_vec() })
}

/// ms since `start` (-1 for none).
pub(crate) fn since(start: Instant, t: Option<Instant>) -> f32 {
    match t {
        Some(t) if t >= start => (t - start).as_secs_f64() as f32 * 1000.0,
        _ => -1.0,
    }
}
