//! A context in the GPU process: a thread with a wgpu device of its own. It runs the command buffers its queue brings, answers
//! through the ring to the browser, and writes frames into the section of its canvas. A panic in naga or wgpu ends the context,
//! and whatever a driver does worse ends this process, never the browser (src/parent.rs).

use crate::child::Out;
use crate::gl::{self, Attrs, Ctx, Flags, FrameRead, Reply};
use crate::ipc::{self, sys, FrameView, ToParent, Words};
use crate::{WgAttrs, WgInfo, BACKEND_DX12, BACKEND_VULKAN};
use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How often the thread looks at frames being mapped while it has nothing else to do.
const MAP_POLL: Duration = Duration::from_millis(1);
/// How long a thread told to hang by a test sleeps at a time.
const TEST_HANG_NAP: Duration = Duration::from_secs(3600);

pub enum Msg {
    Commands(Vec<u8>),
    Query(Vec<u8>, u64),
    Present { snapshot: bool, qid: Option<u64> },
    Resize(u32, u32),
    /// Where frames go from now on.
    Target(Option<Target>),
    Lose,
    Restore(u64),
    Quit,
    /// A test: the thread never comes back, as if a driver had hung.
    TestHang,
}

/// A frame section, mapped in this process.
pub struct Target {
    pub view: FrameView,
    pub base: *mut u8,
    pub bytes: u64,
}

unsafe impl Send for Target {}

impl Drop for Target {
    fn drop(&mut self) {
        unsafe { sys::unmap(self.base, self.bytes) };
    }
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

struct Init {
    result: Result<(WgInfo, wgpu::Device, wgpu::Queue, wgpu::Adapter), String>,
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
    let wanted = wgpu::Features::TEXTURE_COMPRESSION_BC | wgpu::Features::FLOAT32_FILTERABLE | wgpu::Features::FLOAT32_BLENDABLE | wgpu::Features::RG11B10UFLOAT_RENDERABLE | wgpu::Features::DEPTH32FLOAT_STENCIL8 | wgpu::Features::ADDRESS_MODE_CLAMP_TO_ZERO | wgpu::Features::VERTEX_WRITABLE_STORAGE;
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

thread_local! {
    static FIRST_ERROR: std::cell::RefCell<String> = const { std::cell::RefCell::new(String::new()) };
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

/// A context's thread, from its first instruction: the device, the answer to Create, then its messages.
pub fn run(id: u32, qid: u64, a: WgAttrs, rx: Receiver<Msg>, flags: Arc<Flags>, out: &'static Out) {
    let init = catch_unwind(AssertUnwindSafe(|| make_device(&a, true))).map(|i| i.result).unwrap_or_else(|_| Err("the device panicked while starting".to_string()));
    let (device, queue, adapter, software) = match init {
        Ok((w, device, queue, adapter)) => {
            let mut body = Words::default();
            body.u32(w.software as u32).u32(w.has_s3tc as u32).u32(w.has_float_linear as u32).u32(w.has_float_blend as u32).u32(w.max_samples).u32(w.width).u32(w.height).u32(w.antialias as u32);
            let software = w.software != 0;
            out.send(ToParent::Created, id, qid, &[&body.0]);
            (device, queue, adapter, software)
        }
        Err(e) => {
            let n = e.len().min(ipc::MAX_ERROR_BYTES as usize);
            out.send(ToParent::CreateFailed, id, qid, &[&e.as_bytes()[..n]]);
            out.send(ToParent::Stopped, id, 0, &[]);
            return;
        }
    };
    let mut t = Thread { id, attrs: attrs_of(&a), wg: a, out, flags, ctx: None, target: None, reading: VecDeque::new(), lost: false, software };
    {
        let _turn = software_turn(software);
        match make_ctx(device, queue, &adapter, t.attrs, t.flags.clone()) {
            Ok(c) => t.ctx = Some(c),
            Err(e) => {
                t.note(format!("WebGL: {e}"));
                t.say_lost();
            }
        }
    }
    drop(adapter);
    t.main(rx);
    out.send(ToParent::Stopped, id, 0, &[]);
}

struct Thread {
    id: u32,
    attrs: Attrs,
    wg: WgAttrs,
    out: &'static Out,
    flags: Arc<Flags>,
    ctx: Option<Ctx>,
    target: Option<Target>,
    reading: VecDeque<FrameRead>,
    lost: bool,
    software: bool,
}

impl Thread {
    fn note(&self, text: String) {
        let n = text.len().min(ipc::MAX_CONSOLE_BYTES as usize);
        self.out.send(ToParent::Console, self.id, 0, &[&text.as_bytes()[..n]]);
    }

    fn say_lost(&mut self) {
        self.lost = true;
        self.out.send(ToParent::Lost, self.id, 0, &[]);
    }

    fn main(&mut self, rx: Receiver<Msg>) {
        loop {
            let msg = if self.reading.is_empty() {
                match rx.recv() {
                    Ok(m) => m,
                    Err(_) => break,
                }
            } else {
                {
                    let _turn = software_turn(self.software);
                    if let Some(c) = self.ctx.as_mut() {
                        let _ = c.device.poll(wgpu::PollType::Poll);
                    }
                    self.finish_reads();
                }
                match rx.recv_timeout(MAP_POLL) {
                    Ok(m) => m,
                    Err(RecvTimeoutError::Timeout) => continue,
                    Err(RecvTimeoutError::Disconnected) => break,
                }
            };
            if matches!(msg, Msg::Quit) {
                break;
            }
            let turn = software_turn(self.software);
            self.flags.busy.store(true, Ordering::SeqCst);
            let lost_before = self.lost;
            // what comes while the context is lost does nothing (answers still go out)
            let run = catch_unwind(AssertUnwindSafe(|| self.handle(msg)));
            let failed = match run {
                Ok(failed) => failed,
                Err(p) => {
                    let text = p.downcast_ref::<String>().cloned().or_else(|| p.downcast_ref::<&str>().map(|s| s.to_string())).unwrap_or_default();
                    self.note(format!("WebGL: an internal error lost the context: {text}"));
                    true
                }
            };
            let flagged = self.flags.device_lost.load(Ordering::SeqCst) || self.flags.validation_failed.load(Ordering::SeqCst) || self.flags.out_of_memory.load(Ordering::SeqCst);
            if flagged {
                let t = FIRST_ERROR.with(|s| s.borrow().clone());
                if !t.is_empty() {
                    self.note(format!("WebGL: the device reported: {t}"));
                }
                FIRST_ERROR.with(|s| s.borrow_mut().clear());
            }
            if (failed || flagged) && !lost_before {
                self.lose();
                self.flags.device_lost.store(false, Ordering::SeqCst);
                self.flags.validation_failed.store(false, Ordering::SeqCst);
                self.flags.out_of_memory.store(false, Ordering::SeqCst);
            }
            if let Some(c) = self.ctx.as_mut() {
                let lines = std::mem::take(&mut c.console);
                for line in lines {
                    self.note(line);
                }
            }
            self.flags.busy.store(false, Ordering::SeqCst);
            drop(turn);
        }
        let _turn = software_turn(self.software);
        self.reading.clear();
        self.ctx = None;
    }

    fn lose(&mut self) {
        for fr in self.reading.drain(..) {
            drop(fr);
            self.out.send(ToParent::FrameDropped, self.id, 0, &[]);
        }
        self.ctx = None;
        self.say_lost();
    }

    /// Runs one message. true: the context must be lost.
    fn handle(&mut self, msg: Msg) -> bool {
        match msg {
            Msg::Commands(data) => {
                let n = data.len();
                let mut failed = false;
                if let Some(c) = self.ctx.as_mut() {
                    if let Err(e) = c.exec(&data) {
                        let text = format!("WebGL: {e}");
                        self.note(text);
                        failed = true;
                    }
                }
                self.out.send(ToParent::Done, self.id, n as u64, &[]);
                failed
            }
            Msg::Query(req, qid) => {
                let reply = match self.ctx.as_mut() {
                    // a query sees what was recorded: errors of draws, pixels of draws
                    Some(c) => c.query(&req),
                    None => Reply::null(),
                };
                self.answer(qid, reply);
                false
            }
            Msg::Present { snapshot, qid } => {
                if let Some(c) = self.ctx.as_mut() {
                    match begin_read(c, snapshot) {
                        Some(fr) => {
                            self.reading.push_back(fr);
                            if qid.is_some() {
                                if let Some(c) = self.ctx.as_mut() {
                                    let _ = c.device.poll(wgpu::PollType::wait_indefinitely());
                                }
                            }
                        }
                        None => self.out.send(ToParent::FrameDropped, self.id, 0, &[]),
                    }
                } else {
                    // (every present gets one word back, lost or not)
                    self.out.send(ToParent::FrameDropped, self.id, 0, &[]);
                }
                self.finish_reads();
                if let Some(q) = qid {
                    self.answer(q, Reply::empty());
                }
                false
            }
            Msg::Resize(w, h) => {
                if let Some(c) = self.ctx.as_mut() {
                    c.resize(w, h);
                }
                false
            }
            Msg::Target(t) => {
                // (frames on their way go to the new section if they fit it; finish_reads looks)
                self.target = t;
                false
            }
            Msg::Lose => {
                self.lose();
                false
            }
            Msg::Restore(qid) => {
                let mut ok = self.ctx.is_some();
                if self.ctx.is_none() {
                    let mut a = self.wg;
                    a.fail_if_major_performance_caveat = 0;
                    a.allow_software = 1;
                    let init = make_device(&a, false); // (this message has the turn, or does not need it)
                    if let Ok((_, device, queue, adapter2)) = init.result {
                        if let Ok(c) = make_ctx(device, queue, &adapter2, self.attrs, self.flags.clone()) {
                            self.ctx = Some(c);
                            self.lost = false;
                            ok = true;
                        }
                    }
                }
                let mut body = Words::default();
                body.u32(ok as u32);
                self.out.send(ToParent::Restored, self.id, qid, &[&body.0]);
                false
            }
            Msg::Quit => false,
            Msg::TestHang => loop {
                std::thread::sleep(TEST_HANG_NAP);
            },
        }
    }

    fn answer(&self, qid: u64, reply: Reply) {
        let mut head = Words::default();
        let (has, first, row, stride) = match reply.rows {
            Some((f, r, s)) => (1, f as u64, r as u64, s as u64),
            None => (0, 0, 0, 0),
        };
        head.u32(has).u32(0).u64(first).u64(row).u64(stride);
        self.out.send(ToParent::Reply, self.id, qid, &[&head.0, &reply.data]);
    }

    /// Frames whose mapping finished go to the section, in order.
    fn finish_reads(&mut self) {
        while let Some(fr) = self.reading.front() {
            if fr.failed.load(Ordering::SeqCst) {
                self.reading.pop_front();
                self.out.send(ToParent::FrameDropped, self.id, 0, &[]);
                continue;
            }
            if !fr.mapped.load(Ordering::SeqCst) {
                return;
            }
            let Some(fr) = self.reading.pop_front() else { return };
            let delivered = self.deliver(&fr);
            fr.buffer.unmap();
            if let Some(c) = self.ctx.as_mut() {
                if c.frames_free.len() < gl::FRAME_POOL {
                    c.frames_free.push(fr.buffer);
                }
            }
            self.out.send(if delivered { ToParent::Frame } else { ToParent::FrameDropped }, self.id, 0, &[]);
        }
    }

    /// The frame's pixels, premultiplied, top row first, into the section.
    fn deliver(&mut self, fr: &FrameRead) -> bool {
        let Ok(view) = fr.buffer.slice(..).get_mapped_range() else { return false };
        let Some(target) = self.target.as_mut() else { return false };
        let Some(dst) = target.view.fill(fr.w, fr.h) else { return false };
        let (w, h, bpr) = (fr.w as usize, fr.h as usize, fr.bpr as usize);
        let row = w * 4;
        let premultiply = !self.attrs.premultiplied && self.attrs.alpha;
        let mut all_opaque = true;
        for y in 0..h {
            // the drawing buffer holds its bottom row first
            let from = &view[(h - 1 - y) * bpr..(h - 1 - y) * bpr + row];
            let to = unsafe { dst.add(y * row) };
            // (the section's memory is only ours to write: the parent reads it after the publish)
            let out = unsafe { std::slice::from_raw_parts_mut(to, row) };
            out.copy_from_slice(from);
            if premultiply {
                for p in out.chunks_exact_mut(4) {
                    let a = p[3] as u32;
                    if a != 255 {
                        p[0] = ((p[0] as u32 * a + 127) / 255) as u8;
                        p[1] = ((p[1] as u32 * a + 127) / 255) as u8;
                        p[2] = ((p[2] as u32 * a + 127) / 255) as u8;
                    }
                }
            }
            if self.attrs.alpha && all_opaque {
                all_opaque = out.chunks_exact(4).all(|p| p[3] == 255);
            }
        }
        target.view.publish(fr.w, fr.h, all_opaque);
        true
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
