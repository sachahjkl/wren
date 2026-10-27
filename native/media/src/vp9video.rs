//! VP9 video decoding for the media player (src/media/vp9_soft.odin): vp9dec (a from-scratch, clean-room pure-Rust VP9
//! decoder, no C or FFI) behind the same push / pull interface the AV1 decoder uses (av1video.rs). YouTube serves VP9
//! for the high resolutions a machine without the system's VP9 decoder (no Store extension) cannot otherwise play.
//!
//! vp9dec is chunk-in, frames-out: `decode_frame(chunk)` returns the pictures of one container chunk (a superframe may
//! hold several) in bitstream order, each owning its Y/U/V planes. The player feeds one coded sample at a time and
//! pulls pictures one at a time, so the decoded pictures are buffered here in a queue and handed out in turn. A picture
//! stays alive (its planes are the player's to read) until the player releases it; the planes are copied out of
//! vp9dec's Frame into a boxed buffer so the Decoder can move on without keeping every shown picture.

use std::collections::VecDeque;
use std::ffi::c_void;

use vp9dec::{Decoder as Vp9Decoder, Frame, PlaneData};

use crate::{ERR_CORRUPT, ERR_TOO_MUCH_MEMORY};

pub const AGAIN: i32 = 1;

/// A picture pulled out of the decoder, with its planes owned here until `release`. 4:2:0 8-bit (I420) or 10/12-bit
/// (I420_10, samples widened to 16-bit words) is handed over; other chroma layouts are dropped by the caller.
pub struct Held {
    planes: [Vec<u8>; 3],
    strides: [usize; 3],
    width: u32,
    height: u32,
    bits: u32,  // 8, or 16 for a 10/12-bit stream (samples in the low bits of 16-bit words)
    layout: u32, // 0 4:2:0, 1 4:2:2, 2 4:4:4, 3 monochrome (only 0 is handed to the renderer)
    pts: i64,
}

/// What the player reads of a picture. `handle` is released with `release`.
#[repr(C)]
pub struct Picture {
    pub width: u32,
    pub height: u32,
    pub bits: u32,  // 8 or 10 (as the player's Pixel_Format: 8 -> I420, else I420_10)
    pub layout: u32,
    pub planes: [*const u8; 3],
    pub strides: [isize; 3],
    pub pts: i64,
    pub handle: *mut c_void,
}

pub struct Decoder {
    dec: Vp9Decoder,
    ready: VecDeque<Held>,  // pictures decoded, not yet pulled, in bitstream (display) order
    max_pixels: u64,
    pts: i64,               // the timestamp the next chunk carries (the container's, set by send)
}

impl Decoder {
    pub fn open(max_pixels: u64) -> Result<Box<Decoder>, i32> {
        Ok(Box::new(Decoder {
            dec: Vp9Decoder::new(),
            ready: VecDeque::new(),
            max_pixels,
            pts: 0,
        }))
    }

    /// Takes one coded chunk (one container sample: one VP9 superframe), decodes it and queues its pictures. AGAIN is
    /// never returned (vp9dec consumes the whole chunk at once), but the signature matches av1video for the Odin side.
    pub fn send(&mut self, chunk: &[u8], pts: i64) -> Result<i32, i32> {
        if chunk.is_empty() {
            return Ok(0);
        }
        self.pts = pts;
        let frames = self.dec.decode_frame(chunk).map_err(|_| ERR_CORRUPT)?;
        for df in frames {
            if let Some(f) = df.frame {
                self.queue(f)?;
            }
        }
        Ok(0)
    }

    fn queue(&mut self, f: Frame) -> Result<(), i32> {
        let w = f.width as u64;
        let h = f.height as u64;
        if w == 0 || h == 0 || w * h > self.max_pixels {
            // too large (or empty): drop it; the stream plays on without this picture
            return Ok(());
        }
        // chroma size per spec §8.9: (w + ssx) >> ssx  x  (h + ssy) >> ssy
        let cw = ((f.width + f.subsampling_x) >> f.subsampling_x) as usize;
        let ch = ((f.height + f.subsampling_y) >> f.subsampling_y) as usize;
        let layout = match (f.subsampling_x, f.subsampling_y) {
            (1, 1) => 0, // 4:2:0
            (1, 0) => 1, // 4:2:2
            (0, 0) => 2, // 4:4:4
            _ => 1,      // 4:4:0 and the rest: not drawn, dropped by the caller as "layout != 0"
        };
        let (bits, bpp) = if f.bit_depth > 8 { (16u32, 2usize) } else { (8u32, 1usize) };
        let yw = f.width as usize;
        let yh = f.height as usize;
        let mut held = Held {
            planes: [Vec::new(), Vec::new(), Vec::new()],
            strides: [yw * bpp, cw * bpp, cw * bpp],
            width: f.width,
            height: f.height,
            bits,
            layout,
            pts: self.pts,
        };
        held.planes[0] = copy_plane(&f.y, yw, yh, bpp)?;
        held.planes[1] = copy_plane(&f.u, cw, ch, bpp)?;
        held.planes[2] = copy_plane(&f.v, cw, ch, bpp)?;
        self.ready.push_back(held);
        Ok(())
    }

    /// The next picture, or AGAIN when the queue is empty (feed more input).
    pub fn get(&mut self, out: &mut Picture) -> Result<i32, i32> {
        let held = match self.ready.pop_front() {
            Some(h) => h,
            None => return Ok(AGAIN),
        };
        let boxed = Box::new(held);
        out.width = boxed.width;
        out.height = boxed.height;
        out.bits = if boxed.bits > 8 { 10 } else { 8 };
        out.layout = boxed.layout;
        for i in 0..3 {
            out.planes[i] = boxed.planes[i].as_ptr();
            out.strides[i] = boxed.strides[i] as isize;
        }
        out.pts = boxed.pts;
        out.handle = Box::into_raw(boxed) as *mut c_void;
        Ok(0)
    }

    /// Drops everything in flight (a seek). vp9dec keeps no separate flush; a new keyframe resets its reference frames,
    /// so dropping the queued pictures and making a fresh decoder is the safe reset.
    pub fn flush(&mut self) {
        self.ready.clear();
        self.dec = Vp9Decoder::new();
    }
}

/// Copies a cropped plane out of vp9dec's owned samples into a tightly packed buffer (stride = width * bpp). vp9dec
/// returns cropped, row-major planes, so the copy is a straight widen (U16) or move (U8).
fn copy_plane(p: &PlaneData, w: usize, h: usize, bpp: usize) -> Result<Vec<u8>, i32> {
    let mut v = Vec::new();
    v.try_reserve_exact(w * h * bpp).map_err(|_| ERR_TOO_MUCH_MEMORY)?;
    match p {
        PlaneData::U8(s) => {
            // bpp is 1 for an 8-bit stream
            let n = (w * h).min(s.len());
            v.extend_from_slice(&s[..n]);
            v.resize(w * h * bpp, 0);
        }
        PlaneData::U16(s) => {
            // 10/12-bit: samples go into 16-bit little-endian words (the renderer reads P010-style high/low)
            let n = (w * h).min(s.len());
            for &sample in &s[..n] {
                v.extend_from_slice(&sample.to_le_bytes());
            }
            v.resize(w * h * bpp, 0);
        }
    }
    Ok(v)
}

/// # Safety
/// `handle` comes from `Decoder::get` and is released once.
pub unsafe fn release(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    drop(Box::from_raw(handle as *mut Held));
}
