//! Wren's built-in image decoders, behind a C ABI for package `images` (src/images/native.odin).
//!
//! Formats that must work whatever the Windows installation holds: SVG (resvg), WebP (image-webp), AVIF (zenavif-parse +
//! rav1d), plus colour management (qcms) for every format. Everything here runs on the browser's decoding threads, never
//! on the interface thread; nothing keeps global state except the lazily loaded system font database.
//!
//! Output pixels are always RGBA8, straight (non-premultiplied) alpha, sRGB, rows top-down, tightly packed. Pixel memory
//! is the caller's: frames are written into buffers the caller hands out through a callback (`FrameSink`), after every
//! limit was checked from the headers.
//!
//! Contents are hostile: every entry point catches panics (a decoder bug is a broken image, not a dead browser), sizes
//! are checked before allocating, and SVG documents go through limits of nodes, depth, entity and `<use>` expansion and
//! rendering cost before a pixel is drawn.

use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};

mod av1video;
mod avif;
mod color;
mod raster;
mod scale;
mod svg;
mod webp;
mod woff2;

/// Status codes, the same numbers as `images.Error` on the Odin side.
pub const OK: i32 = 0;
pub const ERR_EMPTY: i32 = 1;
pub const ERR_UNKNOWN_FORMAT: i32 = 2;
pub const ERR_UNSUPPORTED: i32 = 3;
pub const ERR_TOO_LARGE_DIMENSION: i32 = 6;
pub const ERR_TOO_MANY_PIXELS: i32 = 7;
pub const ERR_TOO_MANY_FRAMES: i32 = 8;
pub const ERR_TOO_MUCH_MEMORY: i32 = 9;
pub const ERR_CORRUPT: i32 = 10;
pub const ERR_CANCELLED: i32 = 12;
pub const ERR_TOO_COMPLEX: i32 = 13;
pub const ERR_INTERNAL: i32 = 14;

/// Every bound a decode respects (filled from the `images.*` preferences).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub max_dimension: u32,
    pub max_frames: u32,
    pub max_pixels: u64,
    pub max_image_bytes: u64,
    pub min_delay_ms: u32,
    pub default_delay_ms: u32,
    pub first_frame_only: u8,
    pub color_manage: u8,
    pub svg_text: u8,
    pub svg_data_images: u8,
    pub svg_max_nodes: u32,
    pub svg_max_depth: u32,
    pub svg_max_expansion: u64,
    pub svg_max_render_cost: u64,
    pub target_w: u32,     // the size the image will be shown at (0: unknown): an ICO's entry is chosen by it
    pub target_h: u32,
}

/// What the headers say.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct Info {
    pub width: u32,
    pub height: u32,
    pub frames: u32,
    pub plays: u32,        // animated: total plays, 0 = forever
    pub animated: u8,
    pub has_alpha: u8,
    pub bit_depth: u8,
    pub color: u8,         // 0 untagged / sRGB, 1 ICC profile, 2 CICP (nclx), 3 Adobe RGB
    // SVG: natural size in CSS px when the document gives one, and the natural ratio (0 = none)
    pub svg_has_w: u8,
    pub svg_has_h: u8,
    pub orientation: u8,   // raster: the EXIF orientation applied (1..8; 0 = none known)
    pub _pad: u8,
    pub svg_w: f32,
    pub svg_h: f32,
    pub svg_ratio: f32,
}

/// Hands out the buffer of frame `index` (w x h x 4 bytes), or null to stop (out of memory, cancelled).
pub type FrameFn = extern "C" fn(user: *mut c_void, index: u32, w: u32, h: u32, delay_ms: u32) -> *mut u8;

#[repr(C)]
pub struct FrameSink {
    pub user: *mut c_void,
    pub frame: FrameFn,
}

impl FrameSink {
    fn frame(&self, index: u32, w: u32, h: u32, delay_ms: u32) -> Result<&mut [u8], i32> {
        let p = (self.frame)(self.user, index, w, h, delay_ms);
        if p.is_null() {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
        // SAFETY: the callback contract: a buffer of exactly w*h*4 bytes, owned by the caller, alive for this call.
        Ok(unsafe { std::slice::from_raw_parts_mut(p, w as usize * h as usize * 4) })
    }
}

pub(crate) fn check_size(w: u64, h: u64, l: &Limits) -> Result<(), i32> {
    if w == 0 || h == 0 {
        return Err(ERR_CORRUPT);
    }
    if w > l.max_dimension as u64 || h > l.max_dimension as u64 {
        return Err(ERR_TOO_LARGE_DIMENSION);
    }
    if w * h > l.max_pixels {
        return Err(ERR_TOO_MANY_PIXELS);
    }
    if w * h * 4 > l.max_image_bytes {
        return Err(ERR_TOO_MUCH_MEMORY);
    }
    Ok(())
}

/// Frame delays as browsers treat them: very short ones (0, 10 ms) mean "as fast as reasonable".
pub(crate) fn frame_delay(ms: u32, l: &Limits) -> u32 {
    let d = if ms < l.min_delay_ms { l.default_delay_ms } else { ms };
    d.max(1)
}

/// A Vec of `n` zero bytes, or the error when the allocator refuses.
pub(crate) fn try_vec(n: usize) -> Result<Vec<u8>, i32> {
    let mut v = Vec::new();
    v.try_reserve_exact(n).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
    v.resize(n, 0);
    Ok(v)
}

fn guard(f: impl FnOnce() -> Result<(), i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => OK,
        Ok(Err(e)) => e,
        Err(_) => ERR_INTERNAL,
    }
}

/// # Safety
/// `data` points at `len` readable bytes (or len = 0); `limits` and `info` are valid.
unsafe fn args<'a>(data: *const u8, len: usize, limits: *const Limits, info: *mut Info) -> Result<(&'a [u8], Limits, &'a mut Info), i32> {
    if limits.is_null() || info.is_null() {
        return Err(ERR_INTERNAL);
    }
    let bytes = if len == 0 || data.is_null() { &[][..] } else { std::slice::from_raw_parts(data, len) };
    if bytes.is_empty() {
        return Err(ERR_EMPTY);
    }
    Ok((bytes, *limits, &mut *info))
}

////////////////////////////////
// WebP

/// # Safety
/// See `args`.
#[no_mangle]
pub unsafe extern "C" fn wm_webp_probe(data: *const u8, len: usize, limits: *const Limits, info: *mut Info) -> i32 {
    guard(|| {
        let (bytes, l, info) = args(data, len, limits, info)?;
        *info = webp::probe(bytes, &l)?;
        Ok(())
    })
}

/// Decodes every frame (or the first) at the natural size, or the still image reduced to `out_w` x `out_h` (0 = natural).
/// # Safety
/// See `args`; `sink` is valid.
#[no_mangle]
pub unsafe extern "C" fn wm_webp_decode(data: *const u8, len: usize, limits: *const Limits, out_w: u32, out_h: u32, sink: *const FrameSink, info: *mut Info) -> i32 {
    guard(|| {
        let (bytes, l, info) = args(data, len, limits, info)?;
        if sink.is_null() {
            return Err(ERR_INTERNAL);
        }
        webp::decode(bytes, &l, out_w, out_h, &*sink, info)
    })
}

////////////////////////////////
// AVIF

/// # Safety
/// See `args`.
#[no_mangle]
pub unsafe extern "C" fn wm_avif_probe(data: *const u8, len: usize, limits: *const Limits, info: *mut Info) -> i32 {
    guard(|| {
        let (bytes, l, info) = args(data, len, limits, info)?;
        *info = avif::probe(bytes, &l)?;
        Ok(())
    })
}

/// # Safety
/// See `args`; `sink` is valid.
#[no_mangle]
pub unsafe extern "C" fn wm_avif_decode(data: *const u8, len: usize, limits: *const Limits, out_w: u32, out_h: u32, sink: *const FrameSink, info: *mut Info) -> i32 {
    guard(|| {
        let (bytes, l, info) = args(data, len, limits, info)?;
        if sink.is_null() {
            return Err(ERR_INTERNAL);
        }
        avif::decode(bytes, &l, out_w, out_h, &*sink, info)
    })
}

////////////////////////////////
// SVG

/// Parses a document (every limit but the rendering cost is checked here). `*doc` receives a handle to render it at any
/// size, from any thread, until `wm_svg_free`.
/// # Safety
/// See `args`; `doc` is valid.
#[no_mangle]
pub unsafe extern "C" fn wm_svg_parse(data: *const u8, len: usize, limits: *const Limits, info: *mut Info, doc: *mut *mut c_void) -> i32 {
    if doc.is_null() {
        return ERR_INTERNAL;
    }
    *doc = std::ptr::null_mut();
    guard(|| {
        let (bytes, l, info) = args(data, len, limits, info)?;
        let d = svg::parse(bytes, &l, info)?;
        *doc = Box::into_raw(Box::new(d)) as *mut c_void;
        Ok(())
    })
}

/// Renders the whole document into `w` x `h` pixels (its viewBox fitted by preserveAspectRatio), RGBA straight alpha.
/// # Safety
/// `doc` comes from `wm_svg_parse`; `pixels` holds w*h*4 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn wm_svg_render(doc: *const c_void, limits: *const Limits, w: u32, h: u32, pixels: *mut u8) -> i32 {
    if doc.is_null() || pixels.is_null() || limits.is_null() {
        return ERR_INTERNAL;
    }
    guard(|| {
        let d = &*(doc as *const svg::Doc);
        let buf = std::slice::from_raw_parts_mut(pixels, w as usize * h as usize * 4);
        svg::render(d, &*limits, w, h, buf)
    })
}

/// # Safety
/// `doc` comes from `wm_svg_parse` and is not used afterwards.
#[no_mangle]
pub unsafe extern "C" fn wm_svg_free(doc: *mut c_void) {
    if doc.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(doc as *mut svg::Doc))));
}

////////////////////////////////
// Colour

/// Converts `n` RGBA pixels in place from the colour space of an ICC profile to sRGB. ERR_UNSUPPORTED: the profile is
/// not usable (the pixels are left as they are, as browsers do).
/// # Safety
/// `icc` points at `icc_len` bytes, `pixels` at n*4 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn wm_color_icc_to_srgb(icc: *const u8, icc_len: usize, pixels: *mut u8, n: usize) -> i32 {
    if icc.is_null() || pixels.is_null() {
        return ERR_INTERNAL;
    }
    guard(|| {
        let profile = std::slice::from_raw_parts(icc, icc_len);
        let px = std::slice::from_raw_parts_mut(pixels, n * 4);
        color::icc_to_srgb(profile, px)
    })
}

/// Same for the Adobe RGB (1998) space EXIF names without a profile (ExifColorSpace 2).
/// # Safety
/// `pixels` points at n*4 writable bytes.
#[no_mangle]
pub unsafe extern "C" fn wm_color_adobe_to_srgb(pixels: *mut u8, n: usize) -> i32 {
    if pixels.is_null() {
        return ERR_INTERNAL;
    }
    guard(|| color::adobe_to_srgb(std::slice::from_raw_parts_mut(pixels, n * 4)))
}

////////////////////////////////
// Fonts

/// Hands out a buffer of `len` bytes for a decoded font, or null to give up (out of memory).
pub type BytesFn = extern "C" fn(user: *mut c_void, len: usize) -> *mut u8;

#[repr(C)]
pub struct ByteSink {
    pub user: *mut c_void,
    pub alloc: BytesFn,
}

/// Decodes a WOFF2 file into an sfnt (or a TrueType Collection, for a WOFF2 of a collection), at most `max_bytes` bytes
/// of decompressed tables and of output. The result is copied into one buffer from `sink`.
/// # Safety
/// `data` points at `len` readable bytes; `sink` is valid.
#[no_mangle]
pub unsafe extern "C" fn wm_woff2_decode(data: *const u8, len: usize, max_bytes: u64, sink: *const ByteSink) -> i32 {
    if sink.is_null() {
        return ERR_INTERNAL;
    }
    guard(|| {
        if data.is_null() || len == 0 {
            return Err(ERR_EMPTY);
        }
        let bytes = std::slice::from_raw_parts(data, len);
        let max = usize::try_from(max_bytes).unwrap_or(usize::MAX);
        let font = woff2::decode(bytes, max)?;
        let sink = &*sink;
        let p = (sink.alloc)(sink.user, font.len());
        if p.is_null() {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
        // SAFETY: the callback contract: a buffer of exactly font.len() bytes, owned by the caller.
        std::ptr::copy_nonoverlapping(font.as_ptr(), p, font.len());
        Ok(())
    })
}

////////////////////////////////
// PNG, JPEG, GIF, BMP, ICO, TIFF (raster.rs: the format codes raster::PNG...)

/// # Safety
/// See `args`.
#[no_mangle]
pub unsafe extern "C" fn wm_raster_probe(format: u32, data: *const u8, len: usize, limits: *const Limits, info: *mut Info) -> i32 {
    guard(|| {
        let (bytes, l, info) = args(data, len, limits, info)?;
        *info = raster::probe(format, bytes, &l)?;
        Ok(())
    })
}

/// Decodes every frame (or the first) at the natural size (oriented), or the still image reduced to `out_w` x `out_h`.
/// # Safety
/// See `args`; `sink` is valid.
#[no_mangle]
pub unsafe extern "C" fn wm_raster_decode(format: u32, data: *const u8, len: usize, limits: *const Limits, out_w: u32, out_h: u32, sink: *const FrameSink, info: *mut Info) -> i32 {
    guard(|| {
        let (bytes, l, info) = args(data, len, limits, info)?;
        if sink.is_null() {
            return Err(ERR_INTERNAL);
        }
        raster::decode(format, bytes, &l, out_w, out_h, &*sink, info)
    })
}

/// Encodes w x h RGBA8 pixels as PNG (format 1) or JPEG (format 2) into one buffer from `sink`.
/// # Safety
/// `rgba` points at w*h*4 readable bytes; `sink` is valid.
#[no_mangle]
pub unsafe extern "C" fn wm_raster_encode(format: u32, rgba: *const u8, w: u32, h: u32, quality: f32, premultiplied: u8, sink: *const ByteSink) -> i32 {
    if sink.is_null() || rgba.is_null() {
        return ERR_INTERNAL;
    }
    guard(|| {
        let px = std::slice::from_raw_parts(rgba, w as usize * h as usize * 4);
        raster::encode(format, px, w, h, quality, premultiplied != 0, &*sink)
    })
}

////////////////////////////////
// AV1 video (the media player: src/media/av1_soft.odin)

fn guard_value(f: impl FnOnce() -> Result<i32, i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => e,
        Err(_) => ERR_INTERNAL,
    }
}

/// # Safety
/// `out` is a valid slot.
#[no_mangle]
pub unsafe extern "C" fn wm_av1_open(threads: u32, max_pixels: u64, out: *mut *mut c_void) -> i32 {
    guard(|| {
        *out = Box::into_raw(av1video::Decoder::open(threads, max_pixels)?) as *mut c_void;
        Ok(())
    })
}

/// 0 taken, 1 refused (take pictures first), else an error.
/// # Safety
/// `d` comes from wm_av1_open; `data` points at `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn wm_av1_send(d: *mut c_void, data: *const u8, len: usize, pts: i64) -> i32 {
    guard_value(|| {
        let bytes = if len == 0 || data.is_null() { &[][..] } else { std::slice::from_raw_parts(data, len) };
        (*(d as *mut av1video::Decoder)).send(bytes, pts)
    })
}

/// 0 a picture in `pic`, 1 none yet (more input), else an error.
/// # Safety
/// `d` comes from wm_av1_open; `pic` is valid.
#[no_mangle]
pub unsafe extern "C" fn wm_av1_get(d: *mut c_void, pic: *mut av1video::Picture) -> i32 {
    guard_value(|| (*(d as *mut av1video::Decoder)).get(&mut *pic))
}

/// # Safety
/// `handle` is a picture's, released once.
#[no_mangle]
pub unsafe extern "C" fn wm_av1_release(handle: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| av1video::release(handle)));
}

/// # Safety
/// `d` comes from wm_av1_open.
#[no_mangle]
pub unsafe extern "C" fn wm_av1_flush(d: *mut c_void) {
    let _ = catch_unwind(AssertUnwindSafe(|| (*(d as *mut av1video::Decoder)).flush()));
}

/// # Safety
/// `d` comes from wm_av1_open; closed once, after every picture was released.
#[no_mangle]
pub unsafe extern "C" fn wm_av1_close(d: *mut c_void) {
    if d.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(Box::from_raw(d as *mut av1video::Decoder))));
}

/// Versions of the libraries, for about: pages ("resvg 0.48.1, ..."), NUL-terminated, static.
#[no_mangle]
pub extern "C" fn wm_versions() -> *const u8 {
    b"resvg 0.48.1, image-webp 0.2.4, zenavif-parse 0.6.2, rav1d 1.1.0, qcms 0.3.0, brotli-decompressor 6.1.0, image 0.25.10 (png 0.18.1, zune-jpeg 0.5.15, gif 0.14.2, tiff)\0".as_ptr()
}
