//! WebGL's device side, behind a C ABI for the browser (src/page/bindings_webgl.odin). A context's device is in the GPU process,
//! the program started again with a role argument, on a thread of its own there (host.rs): a crash in a driver or a hung shader
//! costs contexts, never the browser. This side (parent.rs) sends command buffers through shared memory and waits only for what a
//! page must wait for (getError, readPixels, getShaderParameter), always with a deadline. Nothing here starts before the first
//! getContext of the browser.
//!
//! How a canvas gets to the screen: `wg_present` asks for the drawing buffer; the context's thread copies it to a staging buffer
//! and, once mapped, the pixels (premultiplied, top row first) go into the shared section of that canvas, for `wg_take_frame`,
//! which the browser calls once per frame into the canvas's bitmap. It is a copy through the CPU, the same path a 2D canvas takes:
//! the toolkit draws with Direct3D 11 on Windows and shares no textures with this device (docs/js/webgl.md).

pub mod capture;
pub mod child;
pub mod draw;
pub mod formats;
pub mod gl;
pub mod host;
pub mod ipc;
pub mod ops;
pub mod parent;
pub mod query;
pub mod translate;

use parent::{Gpu, Handle};
use std::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::Ordering;

/// The thread of a context has this much stack (reserved, committed as used): naga's parser and lowering recurse; the translator
/// bounds nesting and statement length so that this is enough.
pub(crate) const THREAD_STACK_BYTES: usize = 256 << 20;

pub const FRAME_NONE: i32 = 0;
pub const FRAME_NEW: i32 = 1;
pub const FRAME_OPAQUE: i32 = 2;

pub const BACKEND_AUTO: i32 = 0;
pub const BACKEND_DX12: i32 = 1;
pub const BACKEND_VULKAN: i32 = 2;

/// What a page asks of a context, in the C ABI, and what the preferences say of the process.
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
    /// webgl.gpu_hang_ms, webgl.gpu_max_restarts, webgl.gpu_restart_window_s and webgl.gpu_idle_exit_s, in milliseconds.
    pub hang_ms: u32,
    pub max_restarts: u32,
    pub restart_window_ms: u32,
    pub idle_exit_ms: u32,
    /// webgl.gpu_keep_rights: the process gives up nothing (a driver that needs what it gave up).
    pub keep_rights: i32,
    /// Called (on a thread of the browser's) when a frame is ready or the context was lost. Not after wg_destroy returns.
    pub notify: Option<extern "C" fn(*mut std::ffi::c_void)>,
    pub notify_user: *mut std::ffi::c_void,
}

// (the pointer is the browser's, for the browser's callback)
unsafe impl Send for WgAttrs {}

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

/// The browser's one process.
static BROWSER_GPU: Gpu = Gpu::new();

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

/// When the program was started as a GPU process, this runs it and does not return. Anything else: it returns at once.
#[no_mangle]
pub extern "C" fn wg_process_role() {
    let _ = catch_unwind(child::entry_if_role);
}

/// A context, or null with an explanation in `err` (at most `err_cap` bytes, not terminated; `err_len` its length).
#[no_mangle]
pub unsafe extern "C" fn wg_create(attrs: *const WgAttrs, info: *mut WgInfo, err: *mut c_char, err_cap: usize, err_len: *mut usize) -> *mut Handle {
    create_on(&BROWSER_GPU, attrs, info, err, err_cap, err_len)
}

pub(crate) unsafe fn create_on(gpu: &'static Gpu, attrs: *const WgAttrs, info: *mut WgInfo, err: *mut c_char, err_cap: usize, err_len: *mut usize) -> *mut Handle {
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
    match catch_unwind(AssertUnwindSafe(|| Handle::create(gpu, &a))) {
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
    guard((), || b.destroy());
}

/// Sends commands: a header and a body (either may be empty). They are copied.
#[no_mangle]
pub unsafe extern "C" fn wg_submit(h: *const Handle, a: *const u8, an: usize, b: *const u8, bn: usize) {
    let Some(h) = h.as_ref() else { return };
    guard((), || h.submit(slice(a, an), slice(b, bn)))
}

/// Waits for an answer. It goes into (out, cap): its length, or the length needed when it does not fit (nothing is written);
/// -1: the deadline passed or the context is gone (the context is then lost). When the answer is rows of pixels, they land
/// at their offsets and what is outside stays.
#[no_mangle]
pub unsafe extern "C" fn wg_query(h: *const Handle, req: *const u8, n: usize, out: *mut u8, cap: usize) -> i64 {
    let Some(h) = h.as_ref() else { return -1 };
    guard(-1, || h.query(slice(req, n), out, cap))
}

/// Asks for the drawing buffer as the canvas's next frame. A page drawing faster than the GPU waits here, a little.
#[no_mangle]
pub unsafe extern "C" fn wg_present(h: *const Handle) {
    let Some(h) = h.as_ref() else { return };
    guard((), || h.present())
}

/// The drawing buffer now, for toDataURL, drawImage and the like: waits. Does not count as a presented frame.
#[no_mangle]
pub unsafe extern "C" fn wg_snapshot(h: *const Handle) -> i32 {
    let Some(h) = h.as_ref() else { return 0 };
    guard(0, || h.snapshot(false) as i32)
}

/// The same, and the frame ends: the drawing buffer starts again as after a present (transferToImageBitmap).
#[no_mangle]
pub unsafe extern "C" fn wg_commit(h: *const Handle) -> i32 {
    let Some(h) = h.as_ref() else { return 0 };
    guard(0, || h.snapshot(true) as i32)
}

/// Copies the latest frame into a bitmap of this size (premultiplied RGBA8, top row first) if a new one came since the last
/// call: FRAME_NONE, FRAME_NEW or FRAME_OPAQUE.
#[no_mangle]
pub unsafe extern "C" fn wg_take_frame(h: *const Handle, dst: *mut u8, w: u32, height: u32, stride: u32) -> i32 {
    let Some(h) = h.as_ref() else { return 0 };
    guard(0, || h.take_frame(dst, w, height, stride))
}

/// Frames on their way: the browser's loop stays awake for them.
#[no_mangle]
pub unsafe extern "C" fn wg_busy(h: *const Handle) -> i32 {
    match h.as_ref() {
        Some(h) => (h.shared().in_flight.load(Ordering::SeqCst) > 0) as i32,
        None => 0,
    }
}

#[no_mangle]
pub unsafe extern "C" fn wg_resize(h: *const Handle, w: u32, height: u32) {
    if let Some(h) = h.as_ref() {
        guard((), || h.resize(w, height));
    }
}

#[no_mangle]
pub unsafe extern "C" fn wg_is_lost(h: *const Handle) -> i32 {
    match h.as_ref() {
        Some(h) => h.shared().lost.load(Ordering::SeqCst) as i32,
        None => 1,
    }
}

/// WEBGL_lose_context.loseContext.
#[no_mangle]
pub unsafe extern "C" fn wg_lose(h: *const Handle) {
    if let Some(h) = h.as_ref() {
        guard((), || h.lose());
    }
}

/// Makes a new device for a lost context, in a new GPU process when its own has ended. Its objects are gone; the page builds them
/// again.
#[no_mangle]
pub unsafe extern "C" fn wg_restore(h: *const Handle) -> i32 {
    let Some(h) = h.as_ref() else { return 0 };
    guard(0, || h.restore() as i32)
}

/// A message for the page's console, or 0.
#[no_mangle]
pub unsafe extern "C" fn wg_console(h: *const Handle, out: *mut u8, cap: usize) -> usize {
    let Some(h) = h.as_ref() else { return 0 };
    guard(0, || {
        let Some(m) = h.shared().take_console() else { return 0 };
        let mut n = m.len().min(cap);
        while n > 0 && !m.is_char_boundary(n) {
            n -= 1;
        }
        std::ptr::copy_nonoverlapping(m.as_ptr(), out, n);
        n
    })
}

/// The GPU process's id, 0 when there is none.
#[no_mangle]
pub extern "C" fn wg_process_id() -> u64 {
    BROWSER_GPU.current().map_or(0, |p| p.pid() as u64)
}

/// How many GPU processes this browser has started.
#[no_mangle]
pub extern "C" fn wg_process_starts() -> u64 {
    BROWSER_GPU.starts()
}

#[cfg(test)]
mod ipc_tests;
#[cfg(test)]
pub(crate) mod tests;
