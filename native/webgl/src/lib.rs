//! WebGL's device side, behind a C ABI for the browser (src/page/webgl.odin): a context is a thread with a wgpu device of its
//! own. The page's thread sends command buffers and waits only for what a page must wait for (getError, readPixels,
//! getShaderParameter), always with a deadline: a device that hangs, a shader whose compilation never ends or a panic lose
//! the context, never the browser. Nothing here starts before the first getContext.
//!
//! How a canvas gets to the screen: `wg_present` asks the thread to copy the drawing buffer to a staging buffer; once
//! mapped, the pixels (premultiplied, top row first) wait in `Shared::frame` for `wg_take_frame`, which the browser calls
//! once per frame into the canvas's bitmap. It is a copy through the CPU, the same path a 2D canvas takes: the toolkit
//! draws with Direct3D 11 on Windows and shares no textures with this device (docs/js/webgl.md).

pub mod draw;
pub mod formats;
pub mod gl;
pub mod ops;
pub mod query;
pub mod translate;

use gl::{Attrs, Ctx, Flags, FrameRead, Reply};
use std::collections::VecDeque;
use std::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// The thread of a context has this much stack (reserved, committed as used): naga's parser and lowering recurse; the translator
/// bounds nesting and statement length so that this is enough.
const THREAD_STACK_BYTES: usize = 256 << 20;
/// Queued commands, in bytes, before a page's thread waits for the context to catch up.
const MAX_QUEUED_BYTES: usize = 512 << 20;
/// How long a page's thread waits for that, and for a frame's turn.
const BACKPRESSURE_WAIT: Duration = Duration::from_millis(1000);
/// Frames on their way to the CPU before a present waits (a page drawing faster than the GPU).
const MAX_FRAMES_IN_FLIGHT: usize = 3;
/// How often the thread looks at frames being mapped while it has nothing else to do.
const MAP_POLL: Duration = Duration::from_millis(1);

pub const BACKEND_AUTO: i32 = 0;
pub const BACKEND_DX12: i32 = 1;
pub const BACKEND_VULKAN: i32 = 2;

/// What a page asks of a context, in the C ABI.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct WgAttrs {
    pub webgl2: i32,
    pub alpha: i32,
    pub depth: i32,
    pub stencil: i32,
    pub antialias: i32,
    pub premultiplied: i32,
    pub preserve: i32,
    pub fail_if_major_performance_caveat: i32,
    pub width: u32,
    pub height: u32,
    pub max_dimension: u32,
    pub allow_software: i32,
    /// Take the software adapter even when there is a GPU (tests, webgl.force_software).
    pub force_software: i32,
    /// Windows: BACKEND_AUTO, BACKEND_DX12 or BACKEND_VULKAN (webgl.backend).
    pub backend: i32,
    pub max_bytes: u64,
    /// Wait for a query, in milliseconds.
    pub wait_ms: u32,
    /// Called (on the context's thread) when a frame is ready or the context was lost. Not after wg_destroy returns.
    pub notify: Option<extern "C" fn(*mut std::ffi::c_void)>,
    pub notify_user: *mut std::ffi::c_void,
}

/// What getContext's caller learns.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct WgInfo {
    pub software: i32,
    pub has_s3tc: i32,
    pub has_float_linear: i32,
    pub has_float_blend: i32,
    pub max_samples: u32,
    pub width: u32,
    pub height: u32,
    pub antialias: i32,
}

enum Msg {
    Commands(Vec<u8>),
    Query(Vec<u8>, Arc<Slot>),
    Present { snapshot: bool, done: Option<Arc<Slot>> },
    Resize(u32, u32),
    Lose,
    Restore,
    Quit,
}

/// One answer on its way.
#[derive(Default)]
struct Slot {
    reply: Mutex<Option<Reply>>,
    ready: Condvar,
}

impl Slot {
    fn put(&self, r: Reply) {
        if let Ok(mut g) = self.reply.lock() {
            *g = Some(r);
        }
        self.ready.notify_all();
    }
    fn wait(&self, deadline: Instant) -> Option<Reply> {
        let mut g = self.reply.lock().ok()?;
        loop {
            if let Some(r) = g.take() {
                return Some(r);
            }
            let now = Instant::now();
            if now >= deadline {
                return None;
            }
            g = self.ready.wait_timeout(g, deadline - now).ok()?.0;
        }
    }
}

/// The last frame ready, and what the thread and the browser share.
#[derive(Default)]
struct Frame {
    pixels: Vec<u8>,
    w: u32,
    h: u32,
    generation: u64,
}

struct Shared {
    lost: AtomicBool,
    frame: Mutex<Frame>,
    frame_ready: Condvar,
    in_flight: AtomicUsize,
    queued: AtomicUsize,
    console: Mutex<Vec<String>>,
    presented: AtomicU64,
    state_change: Mutex<()>,
    state_changed: Condvar,
    notify: Mutex<(Option<extern "C" fn(*mut std::ffi::c_void)>, usize)>,
}

/// A context as the browser holds it.
pub struct Handle {
    tx: Sender<Msg>,
    shared: Arc<Shared>,
    wait: Duration,
    taken: AtomicU64,
}

struct Init {
    result: Result<(WgInfo, wgpu::Device, wgpu::Queue, wgpu::Adapter), String>,
}

/// Microsoft's software rasterizer crashes (an access violation in the driver) when several devices of a process work at once:
/// software contexts take turns, a whole message at a time. Making any device takes this too.
static SOFTWARE_TURN: Mutex<()> = Mutex::new(());

fn software_turn(software: bool) -> Option<std::sync::MutexGuard<'static, ()>> {
    if software {
        Some(SOFTWARE_TURN.lock().unwrap_or_else(|e| e.into_inner()))
    } else {
        None
    }
}

fn make_device(a: &WgAttrs, take_turn: bool) -> Init {
    let _turn = software_turn(take_turn);
    let request = |backends: wgpu::Backends, fallback: bool| -> Option<wgpu::Adapter> {
        let mut desc = wgpu::InstanceDescriptor::new_without_display_handle();
        desc.backends = backends;
        desc.flags = wgpu::InstanceFlags::DISCARD_HAL_LABELS;
        let instance = wgpu::Instance::new(desc);
        let preference = if fallback { wgpu::PowerPreference::None } else { wgpu::PowerPreference::HighPerformance };
        pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions { power_preference: preference, force_fallback_adapter: fallback, compatible_surface: None, apply_limit_buckets: false })).ok()
    };
    // A GPU: on Windows through Vulkan first (FXC, the compiler behind Direct3D 12's path, takes seconds on the large shaders
    // of real pages, for every state a shader is drawn with), if its adapter is a real one. Otherwise Direct3D 12, then software.
    let mut adapter = None;
    if a.force_software == 0 {
        if cfg!(windows) && a.backend != BACKEND_DX12 {
            adapter = request(wgpu::Backends::VULKAN, false).filter(|x| x.get_info().device_type != wgpu::DeviceType::Cpu);
        }
        if adapter.is_none() && (cfg!(windows) && a.backend != BACKEND_VULKAN) {
            adapter = request(wgpu::Backends::DX12, false);
        }
        if adapter.is_none() && !cfg!(windows) {
            adapter = request(wgpu::Backends::VULKAN, false);
        }
    }
    if adapter.is_none() {
        adapter = request(if cfg!(windows) { wgpu::Backends::DX12 } else { wgpu::Backends::VULKAN }, true);
    }
    let Some(adapter) = adapter else {
        return Init { result: Err("no graphics adapter (Direct3D 12 or Vulkan)".to_string()) };
    };
    let info = adapter.get_info();
    let software = info.device_type == wgpu::DeviceType::Cpu;
    if software && a.allow_software == 0 {
        return Init { result: Err("software rendering is switched off (webgl.allow_software)".to_string()) };
    }
    if software && a.fail_if_major_performance_caveat != 0 {
        return Init { result: Err("failIfMajorPerformanceCaveat: the only adapter is a software one".to_string()) };
    }
    let wanted = wgpu::Features::TEXTURE_COMPRESSION_BC | wgpu::Features::FLOAT32_FILTERABLE | wgpu::Features::FLOAT32_BLENDABLE | wgpu::Features::RG11B10UFLOAT_RENDERABLE | wgpu::Features::DEPTH32FLOAT_STENCIL8 | wgpu::Features::ADDRESS_MODE_CLAMP_TO_ZERO;
    let features = adapter.features() & wanted;
    let mut limits = adapter.limits();
    // what is asked is what the adapter has, except what GL does not need more of
    limits.max_bind_groups = limits.max_bind_groups.min(4);
    let device = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("wren webgl"),
        required_features: features,
        required_limits: limits,
        experimental_features: wgpu::ExperimentalFeatures::disabled(),
        memory_hints: wgpu::MemoryHints::Performance,
        trace: wgpu::Trace::Off,
    }));
    let (device, queue) = match device {
        Ok(x) => x,
        Err(e) => return Init { result: Err(format!("the device could not be made: {e}")) },
    };
    let msaa_ok = adapter.get_texture_format_features(wgpu::TextureFormat::Rgba8Unorm).flags.contains(wgpu::TextureFormatFeatureFlags::MULTISAMPLE_X4);
    let w = WgInfo {
        software: software as i32,
        has_s3tc: features.contains(wgpu::Features::TEXTURE_COMPRESSION_BC) as i32,
        has_float_linear: features.contains(wgpu::Features::FLOAT32_FILTERABLE) as i32,
        has_float_blend: features.contains(wgpu::Features::FLOAT32_BLENDABLE) as i32,
        max_samples: if msaa_ok { gl::ANTIALIAS_SAMPLES } else { 1 },
        width: a.width,
        height: a.height,
        antialias: (a.antialias != 0 && msaa_ok) as i32,
    };
    Init { result: Ok((w, device, queue, adapter)) }
}

fn attrs_of(a: &WgAttrs) -> Attrs {
    Attrs {
        webgl2: a.webgl2 != 0,
        alpha: a.alpha != 0,
        depth: a.depth != 0,
        stencil: a.stencil != 0,
        antialias: a.antialias != 0,
        premultiplied: a.premultiplied != 0,
        preserve: a.preserve != 0,
        width: a.width,
        height: a.height,
        max_bytes: a.max_bytes,
        max_dimension: a.max_dimension,
        force_software: a.force_software != 0,
        backend: a.backend,
    }
}

/// Makes a Ctx; the device's errors now go to its flags.
fn make_ctx(device: wgpu::Device, queue: wgpu::Queue, adapter: &wgpu::Adapter, attrs: Attrs, flags: Arc<Flags>) -> Result<Ctx, String> {
    let f = flags.clone();
    device.on_uncaptured_error(Arc::new(move |e: wgpu::Error| {
        match e {
            wgpu::Error::OutOfMemory { .. } => f.out_of_memory.store(true, Ordering::SeqCst),
            _ => f.validation_failed.store(true, Ordering::SeqCst),
        }
        FIRST_ERROR.with(|s| {
            if s.borrow().is_empty() {
                *s.borrow_mut() = e.to_string();
            }
        });
    }));
    let f = flags.clone();
    device.set_device_lost_callback(move |_, _| {
        f.device_lost.store(true, Ordering::SeqCst);
    });
    Ctx::new(device, queue, adapter, attrs, flags)
}

thread_local! {
    static FIRST_ERROR: std::cell::RefCell<String> = const { std::cell::RefCell::new(String::new()) };
}

fn thread_main(rx: Receiver<Msg>, attrs: Attrs, shared: Arc<Shared>, first: Result<(wgpu::Device, wgpu::Queue, wgpu::Adapter), String>, software: bool) {
    let flags = Arc::new(Flags::default());
    let first_turn = software_turn(software);
    let mut adapter_kept = None;
    let mut ctx = match first {
        Ok((device, queue, adapter)) => {
            let c = make_ctx(device, queue, &adapter, attrs, flags.clone());
            adapter_kept = Some(adapter);
            c.ok()
        }
        Err(_) => None,
    };
    if ctx.is_none() {
        shared.lost.store(true, Ordering::SeqCst);
    }
    drop(first_turn);
    let mut reading: VecDeque<(FrameRead, u64)> = VecDeque::new();
    let mut seq = 0u64;
    loop {
        let msg = if reading.is_empty() {
            match rx.recv() {
                Ok(m) => m,
                Err(_) => break,
            }
        } else {
            {
                let _turn = software_turn(software);
                if let Some(c) = ctx.as_mut() {
                    let _ = c.device.poll(wgpu::PollType::Poll);
                }
                finish_reads(&mut reading, &shared, &attrs, ctx.as_mut());
            }
            match rx.recv_timeout(MAP_POLL) {
                Ok(m) => m,
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => break,
            }
        };
        let quit = matches!(msg, Msg::Quit);
        if quit {
            break;
        }
        let turn = software_turn(software);
        let lost_before = shared.lost.load(Ordering::SeqCst);
        // what comes while the context is lost does nothing (answers still go out)
        let run = catch_unwind(AssertUnwindSafe(|| handle(&mut ctx, msg, &shared, &attrs, &mut reading, &mut seq, adapter_kept.as_ref(), &flags)));
        let failed = match run {
            Ok(failed) => failed,
            Err(p) => {
                let text = p.downcast_ref::<String>().cloned().or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string())).unwrap_or_default();
                note(&shared, format!("WebGL: an internal error lost the context: {text}"));
                true
            }
        };
        let flagged = flags.device_lost.load(Ordering::SeqCst) || flags.validation_failed.load(Ordering::SeqCst) || flags.out_of_memory.load(Ordering::SeqCst);
        if flagged {
            let t = FIRST_ERROR.with(|s| s.borrow().clone());
            if !t.is_empty() {
                note(&shared, format!("WebGL: the device reported: {t}"));
            }
            FIRST_ERROR.with(|s| s.borrow_mut().clear());
        }
        if (failed || flagged) && !lost_before {
            lose(&mut ctx, &shared, &mut reading);
            flags.device_lost.store(false, Ordering::SeqCst);
            flags.validation_failed.store(false, Ordering::SeqCst);
            flags.out_of_memory.store(false, Ordering::SeqCst);
        }
        if let Some(c) = ctx.as_mut() {
            if !c.console.is_empty() {
                if let Ok(mut q) = shared.console.lock() {
                    q.append(&mut c.console);
                }
            }
        }
        drop(turn);
    }
    let _turn = software_turn(software);
    drop(reading);
    drop(ctx);
}

// (the pointer is the browser's, for the browser's callback)
unsafe impl Send for WgAttrs {}

/// Tells the browser something happened.
fn ping(shared: &Shared) {
    if let Ok(n) = shared.notify.lock() {
        if let Some(f) = n.0 {
            f(n.1 as *mut std::ffi::c_void);
        }
    }
}

fn note(shared: &Shared, text: String) {
    if let Ok(mut q) = shared.console.lock() {
        if q.len() < 64 {
            q.push(text);
        }
    }
}

fn lose(ctx: &mut Option<Ctx>, shared: &Shared, reading: &mut VecDeque<(FrameRead, u64)>) {
    shared.lost.store(true, Ordering::SeqCst);
    reading.clear();
    *ctx = None;
    shared.in_flight.store(0, Ordering::SeqCst);
    {
        let _g = shared.state_change.lock();
        shared.state_changed.notify_all();
        shared.frame_ready.notify_all();
    }
    ping(shared);
}

/// Runs one message. true: the context must be lost.
#[allow(clippy::too_many_arguments)]
fn handle(ctx: &mut Option<Ctx>, msg: Msg, shared: &Arc<Shared>, attrs: &Attrs, reading: &mut VecDeque<(FrameRead, u64)>, seq: &mut u64, adapter: Option<&wgpu::Adapter>, flags: &Arc<Flags>) -> bool {
    match msg {
        Msg::Commands(data) => {
            let n = data.len();
            let mut failed = false;
            if let Some(c) = ctx.as_mut() {
                if let Err(e) = c.exec(&data) {
                    note(shared, format!("WebGL: {e}"));
                    failed = true;
                }
            }
            shared.queued.fetch_sub(n, Ordering::SeqCst);
            let _g = shared.state_change.lock();
            shared.state_changed.notify_all();
            failed
        }
        Msg::Query(req, slot) => {
            let reply = match ctx.as_mut() {
                Some(c) => {
                    // a query sees what was recorded: errors of draws, pixels of draws
                    let r = c.query(&req);
                    r
                }
                None => Reply::null(),
            };
            slot.put(reply);
            false
        }
        Msg::Present { snapshot, done } => {
            if let Some(c) = ctx.as_mut() {
                if let Some(fr) = begin_read(c, snapshot) {
                    *seq += 1;
                    shared.in_flight.fetch_add(1, Ordering::SeqCst);
                    reading.push_back((fr, *seq));
                    if done.is_some() {
                        let _ = c.device.poll(wgpu::PollType::wait_indefinitely());
                    }
                }
            }
            finish_reads(reading, shared, attrs, ctx.as_mut());
            if let Some(d) = done {
                d.put(Reply::empty());
            }
            false
        }
        Msg::Resize(w, h) => {
            if let Some(c) = ctx.as_mut() {
                c.resize(w, h);
            }
            false
        }
        Msg::Lose => {
            lose(ctx, shared, reading);
            false
        }
        Msg::Restore => {
            if ctx.is_none() {
                let a = WgAttrs {
                    webgl2: attrs.webgl2 as i32,
                    alpha: attrs.alpha as i32,
                    depth: attrs.depth as i32,
                    stencil: attrs.stencil as i32,
                    antialias: attrs.antialias as i32,
                    premultiplied: attrs.premultiplied as i32,
                    preserve: attrs.preserve as i32,
                    fail_if_major_performance_caveat: 0,
                    width: attrs.width,
                    height: attrs.height,
                    max_dimension: attrs.max_dimension,
                    allow_software: 1,
                    force_software: attrs.force_software as i32,
                    backend: attrs.backend,
                    max_bytes: attrs.max_bytes,
                    wait_ms: 0,
                    notify: None,
                    notify_user: std::ptr::null_mut(),
                };
                let init = make_device(&a, false); // (this message has the turn, or does not need it)
                if let Ok((_, device, queue, adapter2)) = init.result {
                    let _ = adapter;
                    if let Ok(c) = make_ctx(device, queue, &adapter2, *attrs, flags.clone()) {
                        *ctx = Some(c);
                        shared.lost.store(false, Ordering::SeqCst);
                    }
                }
            }
            false
        }
        Msg::Quit => false,
    }
}

/// Records the copy of the drawing buffer to a staging buffer and starts its mapping.
fn begin_read(c: &mut Ctx, snapshot: bool) -> Option<FrameRead> {
    if c.needs_clear {
        // nothing was ever drawn: what shows is the buffer's cleared state
        let saved = c.st.draw_fb;
        c.st.draw_fb = 0;
        c.ensure_pass(None);
        c.st.draw_fb = saved;
    }
    c.end_pass();
    let (w, h) = (c.bb.w, c.bb.h);
    let bpr = (w * 4 + wgpu::COPY_BYTES_PER_ROW_ALIGNMENT - 1) / wgpu::COPY_BYTES_PER_ROW_ALIGNMENT * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
    let size = bpr as u64 * h as u64;
    let buffer = match c.frames_free.pop() {
        Some(b) if b.size() == size => b,
        _ => c.device.create_buffer(&wgpu::BufferDescriptor { label: Some("frame"), size, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false }),
    };
    c.ensure_encoder();
    c.encoder.as_mut()?.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo { texture: &c.bb.color, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        wgpu::TexelCopyBufferInfo { buffer: &buffer, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(bpr), rows_per_image: Some(h) } },
        wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
    );
    c.submit();
    let mapped = Arc::new(AtomicBool::new(false));
    let failed = Arc::new(AtomicBool::new(false));
    let (m, f) = (mapped.clone(), failed.clone());
    buffer.slice(..).map_async(wgpu::MapMode::Read, move |r| {
        if r.is_ok() {
            m.store(true, Ordering::SeqCst);
        } else {
            f.store(true, Ordering::SeqCst);
        }
    });
    // A new frame clears the drawing buffer unless the page asked to keep it.
    if !c.attrs.preserve && !snapshot {
        c.needs_clear = true;
    }
    c.drew_since_present = false;
    Some(FrameRead { buffer, mapped, failed, w, h, bpr })
}

/// Frames whose mapping finished go to `Shared::frame`, in order.
fn finish_reads(reading: &mut VecDeque<(FrameRead, u64)>, shared: &Shared, attrs: &Attrs, mut ctx: Option<&mut Ctx>) {
    while let Some((fr, _)) = reading.front() {
        if fr.failed.load(Ordering::SeqCst) {
            reading.pop_front();
            shared.in_flight.fetch_sub(1, Ordering::SeqCst);
            continue;
        }
        if !fr.mapped.load(Ordering::SeqCst) {
            return;
        }
        let (fr, _) = reading.pop_front().unwrap();
        {
            let Ok(view) = fr.buffer.slice(..).get_mapped_range() else {
                shared.in_flight.fetch_sub(1, Ordering::SeqCst);
                continue;
            };
            let (w, h, bpr) = (fr.w as usize, fr.h as usize, fr.bpr as usize);
            let row = w * 4;
            if let Ok(mut f) = shared.frame.lock() {
                f.pixels.resize(row * h, 0);
                f.w = fr.w;
                f.h = fr.h;
                // the drawing buffer holds its bottom row first
                for y in 0..h {
                    let from = (h - 1 - y) * bpr;
                    f.pixels[y * row..(y + 1) * row].copy_from_slice(&view[from..from + row]);
                }
                if !attrs.premultiplied && attrs.alpha {
                    for p in f.pixels.chunks_exact_mut(4) {
                        let a = p[3] as u32;
                        if a != 255 {
                            p[0] = ((p[0] as u32 * a + 127) / 255) as u8;
                            p[1] = ((p[1] as u32 * a + 127) / 255) as u8;
                            p[2] = ((p[2] as u32 * a + 127) / 255) as u8;
                        }
                    }
                }
                f.generation += 1;
            }
        }
        fr.buffer.unmap();
        if let Some(c) = ctx.as_deref_mut() {
            if c.frames_free.len() < gl::FRAME_POOL {
                c.frames_free.push(fr.buffer);
            }
        }
        shared.in_flight.fetch_sub(1, Ordering::SeqCst);
        shared.presented.fetch_add(1, Ordering::SeqCst);
        shared.frame_ready.notify_all();
        {
            let _g = shared.state_change.lock();
            shared.state_changed.notify_all();
        }
        ping(shared);
    }
}

// ---- the C ABI ----

fn guard<R>(fail: R, f: impl FnOnce() -> R) -> R {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fail)
}

unsafe fn slice<'a>(p: *const u8, n: usize) -> &'a [u8] {
    if p.is_null() || n == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p, n)
    }
}

/// A context, or null with an explanation in `err` (at most `err_cap` bytes, not terminated; `err_len` its length).
#[no_mangle]
pub unsafe extern "C" fn wg_create(attrs: *const WgAttrs, info: *mut WgInfo, err: *mut c_char, err_cap: usize, err_len: *mut usize) -> *mut Handle {
    let say = |text: &str| {
        let n = text.len().min(err_cap);
        if !err.is_null() && n > 0 {
            std::ptr::copy_nonoverlapping(text.as_ptr(), err as *mut u8, n);
        }
        if !err_len.is_null() {
            *err_len = n;
        }
    };
    let Some(a) = attrs.as_ref().copied() else {
        return std::ptr::null_mut();
    };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let (itx, irx) = mpsc::channel();
        let (tx, rx) = mpsc::channel();
        let shared = Arc::new(Shared {
            lost: AtomicBool::new(false),
            frame: Mutex::new(Frame::default()),
            frame_ready: Condvar::new(),
            in_flight: AtomicUsize::new(0),
            queued: AtomicUsize::new(0),
            console: Mutex::new(Vec::new()),
            presented: AtomicU64::new(0),
            state_change: Mutex::new(()),
            state_changed: Condvar::new(),
            notify: Mutex::new((a.notify, a.notify_user as usize)),
        });
        let shared2 = shared.clone();
        let attrs = attrs_of(&a);
        let spawned = std::thread::Builder::new().name("wren webgl".to_string()).stack_size(THREAD_STACK_BYTES).spawn(move || {
            let init = catch_unwind(AssertUnwindSafe(|| make_device(&a, true))).map(|i| i.result).unwrap_or_else(|_| Err("the device panicked while starting".to_string()));
            let mut software = true;
            let (first, answer) = match init {
                Ok((w, device, queue, adapter)) => {
                    software = w.software != 0;
                    (Ok((device, queue, adapter)), Ok(w))
                }
                Err(e) => (Err(e.clone()), Err(e)),
            };
            let bad = first.is_err();
            let _ = itx.send(answer);
            if bad {
                return;
            }
            thread_main(rx, attrs, shared2, first, software);
        });
        if let Err(e) = spawned {
            return Err(format!("no thread: {e}"));
        }
        let wait = Duration::from_millis(a.wait_ms.max(100) as u64);
        match irx.recv_timeout(wait) {
            Ok(Ok(w)) => Ok((Box::new(Handle { tx, shared, wait, taken: AtomicU64::new(0) }), w)),
            Ok(Err(e)) => Err(e),
            Err(_) => Err("the device did not answer in time".to_string()),
        }
    }));
    match result {
        Ok(Ok((h, w))) => {
            if let Some(i) = info.as_mut() {
                *i = w;
            }
            Box::into_raw(h)
        }
        Ok(Err(e)) => {
            say(&e);
            std::ptr::null_mut()
        }
        Err(_) => {
            say("the context could not be made");
            std::ptr::null_mut()
        }
    }
}

/// Ends a context: its thread frees everything, in its own time.
#[no_mangle]
pub unsafe extern "C" fn wg_destroy(h: *mut Handle) {
    if h.is_null() {
        return;
    }
    let b = Box::from_raw(h);
    if let Ok(mut n) = b.shared.notify.lock() {
        n.0 = None;
    }
    let _ = b.tx.send(Msg::Quit);
}

/// Sends commands: a header and a body (either may be empty). They are copied.
#[no_mangle]
pub unsafe extern "C" fn wg_submit(h: *const Handle, a: *const u8, an: usize, b: *const u8, bn: usize) {
    let Some(h) = h.as_ref() else { return };
    if h.shared.lost.load(Ordering::SeqCst) {
        return;
    }
    guard((), || {
        let (a, b) = (slice(a, an), slice(b, bn));
        if a.is_empty() && b.is_empty() {
            return;
        }
        let total = a.len() + b.len();
        // too much waiting already: the page's thread waits for a while, then the context goes
        let queued = h.shared.queued.load(Ordering::SeqCst);
        if queued + total > MAX_QUEUED_BYTES && queued > 0 {
            let deadline = Instant::now() + BACKPRESSURE_WAIT;
            if let Ok(mut g) = h.shared.state_change.lock() {
                while h.shared.queued.load(Ordering::SeqCst) + total > MAX_QUEUED_BYTES && h.shared.queued.load(Ordering::SeqCst) > 0 {
                    let now = Instant::now();
                    if now >= deadline {
                        break;
                    }
                    match h.shared.state_changed.wait_timeout(g, deadline - now) {
                        Ok(x) => g = x.0,
                        Err(_) => return,
                    }
                }
            }
        }
        let mut v = Vec::with_capacity(total);
        v.extend_from_slice(a);
        v.extend_from_slice(b);
        h.shared.queued.fetch_add(total, Ordering::SeqCst);
        let _ = h.tx.send(Msg::Commands(v));
    })
}

/// Waits for an answer. It goes into (out, cap): its length, or the length needed when it does not fit (nothing is written);
/// -1: the deadline passed or the context is gone (the context is then lost). When the answer is rows of pixels, they land
/// at their offsets and what is outside stays.
#[no_mangle]
pub unsafe extern "C" fn wg_query(h: *const Handle, req: *const u8, n: usize, out: *mut u8, cap: usize) -> i64 {
    let Some(h) = h.as_ref() else { return -1 };
    if h.shared.lost.load(Ordering::SeqCst) {
        return -1;
    }
    guard(-1, || {
        let slot = Arc::new(Slot::default());
        if h.tx.send(Msg::Query(slice(req, n).to_vec(), slot.clone())).is_err() {
            return -1;
        }
        let Some(reply) = slot.wait(Instant::now() + h.wait) else {
            h.shared.lost.store(true, Ordering::SeqCst);
            note(&h.shared, "WebGL: the context did not answer in time and was lost".to_string());
            let _ = h.tx.send(Msg::Lose);
            return -1;
        };
        if let Some((first, row, stride)) = reply.rows {
            if row > 0 {
                let rows = reply.data.len() / row;
                let end = first + stride * rows.saturating_sub(1) + row;
                if end > cap || out.is_null() {
                    return end as i64;
                }
                for r in 0..rows {
                    std::ptr::copy_nonoverlapping(reply.data[r * row..].as_ptr(), out.add(first + r * stride), row);
                }
            }
            return reply.data.len() as i64;
        }
        let len = reply.data.len();
        if len <= cap && !out.is_null() && len > 0 {
            std::ptr::copy_nonoverlapping(reply.data.as_ptr(), out, len);
        }
        len as i64
    })
}

/// Asks for the drawing buffer as the canvas's next frame. A page drawing faster than the GPU waits here, a little.
#[no_mangle]
pub unsafe extern "C" fn wg_present(h: *const Handle) {
    let Some(h) = h.as_ref() else { return };
    if h.shared.lost.load(Ordering::SeqCst) {
        return;
    }
    guard((), || {
        if h.shared.in_flight.load(Ordering::SeqCst) >= MAX_FRAMES_IN_FLIGHT {
            let deadline = Instant::now() + BACKPRESSURE_WAIT;
            if let Ok(mut g) = h.shared.state_change.lock() {
                while h.shared.in_flight.load(Ordering::SeqCst) >= MAX_FRAMES_IN_FLIGHT {
                    let now = Instant::now();
                    if now >= deadline {
                        return; // no frame this time
                    }
                    match h.shared.state_changed.wait_timeout(g, deadline - now) {
                        Ok(x) => g = x.0,
                        Err(_) => return,
                    }
                }
            }
        }
        let _ = h.tx.send(Msg::Present { snapshot: false, done: None });
    })
}

/// The drawing buffer now, for toDataURL, drawImage and the like: waits. Does not count as a presented frame.
#[no_mangle]
pub unsafe extern "C" fn wg_snapshot(h: *const Handle) -> i32 {
    let Some(h) = h.as_ref() else { return 0 };
    if h.shared.lost.load(Ordering::SeqCst) {
        return 0;
    }
    guard(0, || {
        let slot = Arc::new(Slot::default());
        if h.tx.send(Msg::Present { snapshot: true, done: Some(slot.clone()) }).is_err() {
            return 0;
        }
        slot.wait(Instant::now() + h.wait).is_some() as i32
    })
}

/// Copies the latest frame into a bitmap of this size (premultiplied RGBA8, top row first) if a new one came since the last
/// call. 1: it did.
#[no_mangle]
pub unsafe extern "C" fn wg_take_frame(h: *const Handle, dst: *mut u8, w: u32, height: u32, stride: u32) -> i32 {
    let Some(h) = h.as_ref() else { return 0 };
    guard(0, || {
        let Ok(f) = h.shared.frame.lock() else { return 0 };
        if f.generation == h.taken.load(Ordering::Relaxed) || f.w != w || f.h != height || dst.is_null() {
            return 0;
        }
        h.taken.store(f.generation, Ordering::Relaxed);
        let row = w as usize * 4;
        for y in 0..height as usize {
            std::ptr::copy_nonoverlapping(f.pixels[y * row..].as_ptr(), dst.add(y * stride as usize), row);
        }
        1
    })
}

/// Frames on their way: the browser's loop stays awake for them.
#[no_mangle]
pub unsafe extern "C" fn wg_busy(h: *const Handle) -> i32 {
    match h.as_ref() {
        Some(h) => (h.shared.in_flight.load(Ordering::SeqCst) > 0) as i32,
        None => 0,
    }
}

#[no_mangle]
pub unsafe extern "C" fn wg_resize(h: *const Handle, w: u32, height: u32) {
    if let Some(h) = h.as_ref() {
        let _ = h.tx.send(Msg::Resize(w, height));
    }
}

#[no_mangle]
pub unsafe extern "C" fn wg_is_lost(h: *const Handle) -> i32 {
    match h.as_ref() {
        Some(h) => h.shared.lost.load(Ordering::SeqCst) as i32,
        None => 1,
    }
}

/// WEBGL_lose_context.loseContext.
#[no_mangle]
pub unsafe extern "C" fn wg_lose(h: *const Handle) {
    if let Some(h) = h.as_ref() {
        h.shared.lost.store(true, Ordering::SeqCst);
        let _ = h.tx.send(Msg::Lose);
    }
}

/// Makes a new device for a lost context. Its objects are gone; the page builds them again.
#[no_mangle]
pub unsafe extern "C" fn wg_restore(h: *const Handle) -> i32 {
    let Some(h) = h.as_ref() else { return 0 };
    let _ = h.tx.send(Msg::Restore);
    let slot = Arc::new(Slot::default());
    let _ = h.tx.send(Msg::Query(vec![], slot.clone()));
    let _ = slot.wait(Instant::now() + h.wait);
    (!h.shared.lost.load(Ordering::SeqCst)) as i32
}

/// A message for the page's console, or 0.
#[no_mangle]
pub unsafe extern "C" fn wg_console(h: *const Handle, out: *mut u8, cap: usize) -> usize {
    let Some(h) = h.as_ref() else { return 0 };
    guard(0, || {
        let Ok(mut q) = h.shared.console.lock() else { return 0 };
        if q.is_empty() {
            return 0;
        }
        let m = q.remove(0);
        let n = m.len().min(cap);
        std::ptr::copy_nonoverlapping(m.as_ptr(), out, n);
        n
    })
}

#[cfg(test)]
mod tests;
