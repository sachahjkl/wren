//! AV1 video decoding for the media player (src/media/av1_soft.odin): rav1d (the Rust port of dav1d, the decoder the
//! AVIF images already use) behind a push / pull interface. Pictures stay rav1d's (reference counted) until the player
//! releases them: no copy of the planes.

use std::ffi::c_void;
use std::mem::MaybeUninit;
use std::ptr::NonNull;

use rav1d::include::dav1d::data::Dav1dData;
use rav1d::include::dav1d::dav1d::{Dav1dContext, Dav1dSettings};
use rav1d::include::dav1d::headers::{DAV1D_PIXEL_LAYOUT_I400, DAV1D_PIXEL_LAYOUT_I420, DAV1D_PIXEL_LAYOUT_I422};
use rav1d::include::dav1d::picture::Dav1dPicture;
use rav1d::src::lib::{dav1d_close, dav1d_data_create, dav1d_data_unref, dav1d_default_settings, dav1d_flush, dav1d_get_picture, dav1d_open, dav1d_picture_unref, dav1d_send_data};

use crate::{ERR_CORRUPT, ERR_TOO_MUCH_MEMORY};

pub const AGAIN: i32 = 1;
const EAGAIN: i32 = 11;

pub struct Decoder {
    ctx: Option<Dav1dContext>,
    pending: Dav1dData, // a sample taken but not yet all sent (the decoder wanted its output taken first)
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // SAFETY: pending holds a reference or is empty; ctx comes from dav1d_open.
        unsafe {
            if self.pending.sz != 0 {
                dav1d_data_unref(NonNull::new(&mut self.pending));
            }
            dav1d_close(NonNull::new(&mut self.ctx));
        }
    }
}

/// What the player reads of a picture. `handle` is released with `release`.
#[repr(C)]
pub struct Picture {
    pub width: u32,
    pub height: u32,
    pub bits: u32,     // 8 or 10 (12 is decoded but shown as 10)
    pub layout: u32,   // 0 4:2:0, 1 4:2:2, 2 4:4:4, 3 monochrome
    pub planes: [*const u8; 3],
    pub strides: [isize; 3],
    pub pts: i64,
    pub primaries: u16,
    pub transfer: u16,
    pub matrix: u16,
    pub full_range: u8,
    pub handle: *mut c_void,
}

fn err_of(r: i32) -> i32 {
    if r == -12 {
        ERR_TOO_MUCH_MEMORY
    } else {
        ERR_CORRUPT
    }
}

impl Decoder {
    pub fn open(threads: u32, max_pixels: u64) -> Result<Box<Decoder>, i32> {
        let mut s = MaybeUninit::<Dav1dSettings>::uninit();
        // SAFETY: dav1d_default_settings fills the whole struct.
        let mut s = unsafe {
            dav1d_default_settings(NonNull::new(s.as_mut_ptr()).unwrap());
            s.assume_init()
        };
        s.n_threads = threads.clamp(1, 64) as i32;
        s.max_frame_delay = 0; // (the library's choice for its thread count)
        s.apply_grain = 1;
        s.all_layers = 0;
        s.frame_size_limit = max_pixels.min(u32::MAX as u64) as u32;
        let mut ctx: Option<Dav1dContext> = None;
        // SAFETY: valid pointers to a settings struct and an output slot.
        let r = unsafe { dav1d_open(NonNull::new(&mut ctx), NonNull::new(&mut s)) };
        if r.0 != 0 || ctx.is_none() {
            return Err(err_of(r.0));
        }
        Ok(Box::new(Decoder { ctx, pending: Dav1dData::default() }))
    }

    fn send_pending(&mut self) -> Result<(), i32> {
        while self.pending.sz != 0 {
            // SAFETY: ctx is open; pending is valid.
            let r = unsafe { dav1d_send_data(self.ctx, NonNull::new(&mut self.pending)) };
            if r.0 == -EAGAIN {
                return Ok(()); // output first
            }
            if r.0 != 0 {
                // SAFETY: the data is dropped with the error.
                unsafe { dav1d_data_unref(NonNull::new(&mut self.pending)) };
                return Err(err_of(r.0));
            }
        }
        Ok(())
    }

    /// Takes one temporal unit. AGAIN: refused (the previous one is still being sent: take pictures first).
    pub fn send(&mut self, obu: &[u8], pts: i64) -> Result<i32, i32> {
        if self.pending.sz != 0 {
            self.send_pending()?;
            if self.pending.sz != 0 {
                return Ok(AGAIN);
            }
        }
        if obu.is_empty() {
            return Ok(0);
        }
        // SAFETY: dav1d_data_create allocates `len` bytes owned by `pending`; we fill them.
        unsafe {
            let p = dav1d_data_create(NonNull::new(&mut self.pending), obu.len());
            if p.is_null() {
                return Err(ERR_TOO_MUCH_MEMORY);
            }
            std::ptr::copy_nonoverlapping(obu.as_ptr(), p, obu.len());
        }
        self.pending.m.timestamp = pts;
        self.send_pending()?;
        Ok(0)
    }

    /// The next picture, or AGAIN when the decoder needs more input.
    pub fn get(&mut self, out: &mut Picture) -> Result<i32, i32> {
        self.send_pending()?;
        let mut pic = Box::new(Dav1dPicture::default());
        // SAFETY: ctx is open; pic is a valid slot.
        let g = unsafe { dav1d_get_picture(self.ctx, NonNull::new(&mut *pic)) };
        if g.0 == -EAGAIN {
            return Ok(AGAIN);
        }
        if g.0 != 0 {
            return Err(err_of(g.0));
        }
        let p = &pic.p;
        out.width = p.w as u32;
        out.height = p.h as u32;
        out.bits = (p.bpc as u32).min(10);
        out.layout = match p.layout {
            DAV1D_PIXEL_LAYOUT_I420 => 0,
            DAV1D_PIXEL_LAYOUT_I422 => 1,
            DAV1D_PIXEL_LAYOUT_I400 => 3,
            _ => 2,
        };
        for i in 0..3 {
            out.planes[i] = pic.data[i].map_or(std::ptr::null(), |d| d.as_ptr() as *const u8);
        }
        out.strides = [pic.stride[0], pic.stride[1], pic.stride[1]];
        out.pts = pic.m.timestamp;
        out.primaries = 2;
        out.transfer = 2;
        out.matrix = 2;
        out.full_range = 0;
        if let Some(seq) = pic.seq_hdr {
            // SAFETY: the sequence header lives as long as the picture.
            let s = unsafe { seq.as_ref() };
            out.primaries = s.pri as u16;
            out.transfer = s.trc as u16;
            out.matrix = s.mtrx as u16;
            out.full_range = (s.color_range != 0) as u8;
        }
        out.handle = Box::into_raw(pic) as *mut c_void;
        Ok(0)
    }

    /// Drops everything in flight (a seek).
    pub fn flush(&mut self) {
        // SAFETY: as in Drop; ctx is open.
        unsafe {
            if self.pending.sz != 0 {
                dav1d_data_unref(NonNull::new(&mut self.pending));
            }
            if let Some(c) = self.ctx {
                dav1d_flush(c);
            }
        }
    }
}

/// # Safety
/// `handle` comes from `Decoder::get` and is released once.
pub unsafe fn release(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let mut pic = Box::from_raw(handle as *mut Dav1dPicture);
    dav1d_picture_unref(NonNull::new(&mut *pic));
}
