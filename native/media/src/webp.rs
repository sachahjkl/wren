//! WebP with image-webp (pure, safe Rust): lossy (VP8), lossless (VP8L), alpha (ALPH), animation (ANIM / ANMF, frames
//! composed onto the canvas by the decoder), ICC profile (ICCP).

use crate::{check_size, color, frame_delay, scale, try_vec, FrameSink, Info, Limits, ERR_CORRUPT, ERR_TOO_MANY_FRAMES, ERR_TOO_MUCH_MEMORY};
use image_webp::{DecodingError, LoopCount, WebPDecoder};
use std::io::Cursor;

fn map_err(e: DecodingError) -> i32 {
    match e {
        DecodingError::MemoryLimitExceeded => ERR_TOO_MUCH_MEMORY,
        _ => ERR_CORRUPT,
    }
}

fn open<'a>(data: &'a [u8], l: &Limits) -> Result<(WebPDecoder<Cursor<&'a [u8]>>, Info), i32> {
    let mut d = WebPDecoder::new(Cursor::new(data)).map_err(map_err)?;
    d.set_memory_limit(l.max_image_bytes.min(usize::MAX as u64) as usize);
    let (w, h) = d.dimensions();
    check_size(w as u64, h as u64, l)?;
    let mut info = Info { width: w, height: h, frames: 1, plays: 1, bit_depth: 8, has_alpha: d.has_alpha() as u8, ..Default::default() };
    if d.is_animated() {
        info.frames = d.num_frames();
        info.animated = (info.frames > 1) as u8;
        info.plays = match d.loop_count() {
            LoopCount::Forever => 0,
            LoopCount::Times(n) => n.get() as u32,
        };
    }
    Ok((d, info))
}

pub fn probe(data: &[u8], l: &Limits) -> Result<Info, i32> {
    let (_, info) = open(data, l)?;
    Ok(info)
}

pub fn decode(data: &[u8], l: &Limits, out_w: u32, out_h: u32, sink: &FrameSink, info: &mut Info) -> Result<(), i32> {
    let (mut d, inf) = open(data, l)?;
    *info = inf;
    let (w, h) = (inf.width as usize, inf.height as usize);
    let icc = if l.color_manage != 0 { d.icc_profile().ok().flatten() } else { None };
    if icc.is_some() {
        info.color = 1;
    }
    let bpp = if d.has_alpha() { 4 } else { 3 };
    let mut raw = try_vec(w * h * bpp)?;
    let to_rgba = |raw: &[u8], out: &mut [u8]| {
        if bpp == 4 {
            out.copy_from_slice(raw);
        } else {
            for (o, i) in out.chunks_exact_mut(4).zip(raw.chunks_exact(3)) {
                o[..3].copy_from_slice(i);
                o[3] = 255;
            }
        }
    };
    let manage = |px: &mut [u8]| {
        if let Some(p) = &icc {
            let _ = color::icc_to_srgb(p, px);   // an unusable profile leaves the pixels as they are
        }
    };

    if info.animated != 0 && l.first_frame_only == 0 {
        let n = info.frames as u64;
        if n > l.max_frames as u64 {
            return Err(ERR_TOO_MANY_FRAMES);
        }
        if (w * h * 4) as u64 * n > l.max_image_bytes {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
        let _ = d.set_background_color([0, 0, 0, 0]);   // browsers ignore the ANIM background colour
        for i in 0..info.frames {
            let ms = match d.read_frame(&mut raw) {
                Ok(ms) => ms,
                Err(DecodingError::NoMoreFrames) => break,
                Err(e) if i == 0 => return Err(map_err(e)),
                Err(_) => break,   // a truncated animation shows the frames that arrived
            };
            let out = sink.frame(i, w as u32, h as u32, frame_delay(ms, l))?;
            to_rgba(&raw, out);
            manage(out);
        }
        return Ok(());
    }
    if d.is_animated() {
        d.read_frame(&mut raw).map_err(map_err)?;
    } else {
        d.read_image(&mut raw).map_err(map_err)?;
    }
    info.animated = 0;
    let (tw, th) = scale::target(w, h, out_w, out_h);
    if (tw, th) == (w, h) {
        let out = sink.frame(0, w as u32, h as u32, 0)?;
        to_rgba(&raw, out);
        manage(out);
    } else {
        let mut full = try_vec(w * h * 4)?;
        to_rgba(&raw, &mut full);
        drop(raw);
        manage(&mut full);
        let out = sink.frame(0, tw as u32, th as u32, 0)?;
        scale::reduce(&full, w, h, out, tw, th);
    }
    Ok(())
}
