//! PNG (and APNG), JPEG, GIF, BMP, ICO and TIFF with the `image` crate's decoders (png, zune-jpeg, gif, tiff: safe
//! Rust), and PNG / JPEG encoding for the canvas: what Windows Imaging Component did, the same on every system.
//!
//! Like the other decoders: limits checked from the headers before a pixel is allocated, frames written into the
//! caller's buffers, RGBA8 straight alpha in sRGB (ICC profiles through qcms), EXIF orientation applied (Info.width and
//! height are the oriented size; Info.orientation the tag that was applied), animations composed onto the canvas by the
//! decoder (GIF disposal, APNG blend / dispose).

use crate::{check_size, color, frame_delay, scale, try_vec, ByteSink, FrameSink, Info, Limits, ERR_CORRUPT, ERR_TOO_LARGE_DIMENSION, ERR_TOO_MANY_FRAMES, ERR_TOO_MUCH_MEMORY, ERR_UNSUPPORTED};
use image::codecs::{bmp::BmpDecoder, gif::GifDecoder, ico::IcoDecoder, jpeg::JpegDecoder, png::PngDecoder, tiff::TiffDecoder};
use image::error::{ImageError, LimitErrorKind};
use image::metadata::Orientation;
use image::{AnimationDecoder, DynamicImage, ImageDecoder};
use std::io::Cursor;

/// The format codes of `wm_raster_*` (images.Format's raster formats on the Odin side).
pub const PNG: u32 = 1;
pub const JPEG: u32 = 2;
pub const GIF: u32 = 3;
pub const BMP: u32 = 4;
pub const ICO: u32 = 5;
pub const TIFF: u32 = 6;

fn map_err(e: ImageError) -> i32 {
    match e {
        ImageError::Limits(l) => match l.kind() {
            LimitErrorKind::DimensionError => ERR_TOO_LARGE_DIMENSION,
            _ => ERR_TOO_MUCH_MEMORY,
        },
        ImageError::Unsupported(_) => ERR_UNSUPPORTED,
        _ => ERR_CORRUPT,
    }
}

fn image_limits(l: &Limits) -> image::Limits {
    let mut il = image::Limits::default();
    il.max_image_width = Some(l.max_dimension);
    il.max_image_height = Some(l.max_dimension);
    // the decoders' own buffers (a 16-bit TIFF, a GIF's canvas) count too: twice the RGBA8 budget
    il.max_alloc = Some(l.max_image_bytes.saturating_mul(2));
    il
}

/// The entries of an ICO / CUR directory: (width, height, offset, size); 0 in the file means 256.
fn ico_entries(data: &[u8]) -> Vec<(u32, u32, usize, usize)> {
    let mut out = Vec::new();
    if data.len() < 6 || data[0] != 0 || data[1] != 0 || !(data[2] == 1 || data[2] == 2) || data[3] != 0 {
        return out;
    }
    let n = u16::from_le_bytes([data[4], data[5]]) as usize;
    for i in 0..n {
        let e = 6 + i * 16;
        if e + 16 > data.len() {
            break;
        }
        let w = if data[e] == 0 { 256 } else { data[e] as u32 };
        let h = if data[e + 1] == 0 { 256 } else { data[e + 1] as u32 };
        let size = u32::from_le_bytes(data[e + 8..e + 12].try_into().unwrap()) as usize;
        let off = u32::from_le_bytes(data[e + 12..e + 16].try_into().unwrap()) as usize;
        if off.checked_add(size).map_or(true, |end| end > data.len()) || size == 0 {
            continue;
        }
        out.push((w, h, off, size));
    }
    out
}

/// The icon to show (what the WIC path chose): the smallest at least as large as the target, else the largest. The
/// result is a one-entry ICO of it, so that the decoder (which takes the largest) decodes that one.
fn ico_pick(data: &[u8], l: &Limits) -> Option<Vec<u8>> {
    let entries = ico_entries(data);
    if entries.len() < 2 {
        return None;
    }
    let mut best = 0;
    let mut fit: Option<usize> = None;
    for (i, &(w, h, _, _)) in entries.iter().enumerate() {
        let a = w as u64 * h as u64;
        let (bw, bh, _, _) = entries[best];
        if a > bw as u64 * bh as u64 {
            best = i;
        }
        if l.target_w > 0 && l.target_h > 0 && w >= l.target_w && h >= l.target_h {
            if fit.map_or(true, |f| a < entries[f].0 as u64 * entries[f].1 as u64) {
                fit = Some(i);
            }
        }
    }
    let i = fit.unwrap_or(best);
    let (_, _, off, size) = entries[i];
    let mut one = Vec::with_capacity(22 + size);
    one.extend_from_slice(&data[..6]);
    one[4] = 1;
    one[5] = 0;
    let e = 6 + i * 16;
    one.extend_from_slice(&data[e..e + 12]);
    one.extend_from_slice(&22u32.to_le_bytes());
    one.extend_from_slice(&data[off..off + size]);
    Some(one)
}

/// A decoder of the format, with the limits set.
fn open<'a>(format: u32, data: &'a [u8], l: &Limits) -> Result<Box<dyn ImageDecoder + 'a>, i32> {
    let c = Cursor::new(data);
    let mut d: Box<dyn ImageDecoder + 'a> = match format {
        PNG => Box::new(PngDecoder::new(c).map_err(map_err)?),
        JPEG => Box::new(JpegDecoder::new(c).map_err(map_err)?),
        GIF => Box::new(GifDecoder::new(c).map_err(map_err)?),
        BMP => Box::new(BmpDecoder::new(c).map_err(map_err)?),
        ICO => Box::new(IcoDecoder::new(c).map_err(map_err)?),
        TIFF => Box::new(TiffDecoder::new(c).map_err(map_err)?),
        _ => return Err(ERR_UNSUPPORTED),
    };
    d.set_limits(image_limits(l)).map_err(map_err)?;
    Ok(d)
}

fn exif_of(o: Orientation) -> u8 {
    match o {
        Orientation::NoTransforms => 1,
        Orientation::FlipHorizontal => 2,
        Orientation::Rotate180 => 3,
        Orientation::FlipVertical => 4,
        Orientation::Rotate90FlipH => 5,
        Orientation::Rotate90 => 6,
        Orientation::Rotate270FlipH => 7,
        Orientation::Rotate270 => 8,
    }
}

/// GIF: frames and plays from the blocks (no pixel decoded). plays: 0 = forever (NETSCAPE2.0 loop count 0), else the
/// loop count + 1; no loop extension: once.
fn gif_frames(data: &[u8]) -> Result<(u32, u32), i32> {
    let mut o = gif::DecodeOptions::new();
    o.skip_frame_decoding(true);
    let mut r = o.read_info(Cursor::new(data)).map_err(|_| ERR_CORRUPT)?;
    let mut n = 0u32;
    loop {
        match r.read_next_frame() {
            Ok(Some(_)) => n += 1,
            Ok(None) => break,
            Err(_) if n > 0 => break,   // a truncated animation shows the frames that arrived
            Err(_) => return Err(ERR_CORRUPT),
        }
    }
    let plays = match r.repeat() {
        gif::Repeat::Infinite => 0,
        gif::Repeat::Finite(0) => 1,
        gif::Repeat::Finite(k) => k as u32 + 1,
    };
    Ok((n.max(1), plays))
}

/// APNG: (frames, plays) from acTL when it comes before the first IDAT (else a still PNG).
fn apng_frames(data: &[u8]) -> Option<(u32, u32)> {
    let mut p = 8usize;
    while p + 8 <= data.len() {
        let len = u32::from_be_bytes(data[p..p + 4].try_into().ok()?) as usize;
        let kind = &data[p + 4..p + 8];
        if kind == b"IDAT" {
            return None;
        }
        if kind == b"acTL" && len >= 8 && p + 16 <= data.len() {
            let frames = u32::from_be_bytes(data[p + 8..p + 12].try_into().ok()?);
            let plays = u32::from_be_bytes(data[p + 12..p + 16].try_into().ok()?);
            return Some((frames.max(1), plays));
        }
        p = p.checked_add(12 + len)?;
    }
    None
}

pub fn probe(format: u32, data: &[u8], l: &Limits) -> Result<Info, i32> {
    let mut d = open(format, data, l)?;
    let (w, h) = d.dimensions();
    let o = d.orientation().unwrap_or(Orientation::NoTransforms);
    let (ow, oh) = match o {
        Orientation::Rotate90 | Orientation::Rotate270 | Orientation::Rotate90FlipH | Orientation::Rotate270FlipH => (h, w),
        _ => (w, h),
    };
    check_size(ow as u64, oh as u64, l)?;
    let ct = d.color_type();
    let mut info = Info {
        width: ow,
        height: oh,
        frames: 1,
        plays: 1,
        has_alpha: ct.has_alpha() as u8,
        bit_depth: (ct.bits_per_pixel() / ct.channel_count() as u16) as u8,
        orientation: exif_of(o),
        ..Default::default()
    };
    if l.color_manage != 0 && d.icc_profile().ok().flatten().is_some() {
        info.color = 1;
    }
    let anim = match format {
        GIF => Some(gif_frames(data)?),
        PNG => apng_frames(data),
        _ => None,
    };
    if let Some((frames, plays)) = anim {
        info.frames = frames;
        info.plays = plays;
        info.animated = (frames > 1) as u8;
    }
    if format == ICO {
        info.frames = ico_entries(data).len().max(1) as u32;   // the sizes it holds (one is shown)
    }
    Ok(info)
}

pub fn decode(format: u32, data: &[u8], l: &Limits, out_w: u32, out_h: u32, sink: &FrameSink, info: &mut Info) -> Result<(), i32> {
    *info = probe(format, data, l)?;
    let manage = |icc: &Option<Vec<u8>>, px: &mut [u8]| {
        if let Some(p) = icc {
            let _ = color::icc_to_srgb(p, px);   // an unusable profile leaves the pixels as they are
        }
    };

    if info.animated != 0 && l.first_frame_only == 0 {
        if info.frames > l.max_frames {
            return Err(ERR_TOO_MANY_FRAMES);
        }
        let (w, h) = (info.width as usize, info.height as usize);
        if (w * h * 4) as u64 * info.frames as u64 > l.max_image_bytes {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
        let c = Cursor::new(data);
        let icc = if l.color_manage != 0 { open(format, data, l)?.icc_profile().ok().flatten() } else { None };
        let frames = match format {
            GIF => {
                let mut d = GifDecoder::new(c).map_err(map_err)?;
                d.set_limits(image_limits(l)).map_err(map_err)?;
                d.into_frames()
            }
            _ => {
                let mut d = PngDecoder::new(c).map_err(map_err)?;
                d.set_limits(image_limits(l)).map_err(map_err)?;
                d.apng().map_err(map_err)?.into_frames()
            }
        };
        let mut i = 0u32;
        for f in frames {
            let f = match f {
                Ok(f) => f,
                Err(e) if i == 0 => return Err(map_err(e)),
                Err(_) => break,   // a truncated animation shows the frames that arrived
            };
            if i >= info.frames {
                break;
            }
            let (num, den) = f.delay().numer_denom_ms();
            let ms = if den == 0 { 0 } else { num / den };
            let buf = f.into_buffer();
            if buf.width() as usize != w || buf.height() as usize != h {
                return Err(ERR_CORRUPT);
            }
            let out = sink.frame(i, w as u32, h as u32, frame_delay(ms, l))?;
            out.copy_from_slice(buf.as_raw());
            manage(&icc, out);
            i += 1;
        }
        if i == 0 {
            return Err(ERR_CORRUPT);
        }
        return Ok(());
    }

    let picked = if format == ICO { ico_pick(data, l) } else { None };
    let mut d = open(format, picked.as_deref().unwrap_or(data), l)?;
    let icc = if l.color_manage != 0 { d.icc_profile().ok().flatten() } else { None };
    let o = d.orientation().unwrap_or(Orientation::NoTransforms);
    let mut img = DynamicImage::from_decoder(d).map_err(map_err)?;
    img.apply_orientation(o);
    let rgba = img.into_rgba8();
    let (w, h) = (rgba.width() as usize, rgba.height() as usize);
    info.animated = 0;
    let mut full = rgba.into_raw();
    manage(&icc, &mut full);
    let (tw, th) = scale::target(w, h, out_w, out_h);
    let out = sink.frame(0, tw as u32, th as u32, 0)?;
    if (tw, th) == (w, h) {
        out.copy_from_slice(&full);
    } else {
        scale::reduce(&full, w, h, out, tw, th);
    }
    Ok(())
}

/// PNG (straight alpha) or JPEG (`quality` 0 to 1, no alpha: transparent areas over black) of a w x h RGBA8 image.
/// `premultiplied`: the pixels are premultiplied (a canvas's): PNG gets them divided by alpha, JPEG as they are (a
/// colour premultiplied by its alpha is that colour over black).
pub fn encode(format: u32, rgba: &[u8], w: u32, h: u32, quality: f32, premultiplied: bool, sink: &ByteSink) -> Result<(), i32> {
    use image::ImageEncoder;
    let n = w as usize * h as usize * 4;
    if w == 0 || h == 0 || rgba.len() < n {
        return Err(ERR_CORRUPT);
    }
    let mut out: Vec<u8> = Vec::new();
    match format {
        PNG => {
            let px: std::borrow::Cow<[u8]> = if premultiplied {
                let mut v = try_vec(n)?;
                v.copy_from_slice(&rgba[..n]);
                scale::unpremultiply(&mut v);
                v.into()
            } else {
                (&rgba[..n]).into()
            };
            image::codecs::png::PngEncoder::new(&mut out).write_image(&px, w, h, image::ExtendedColorType::Rgba8).map_err(map_err)?;
        }
        JPEG => {
            let mut rgb = try_vec(w as usize * h as usize * 3)?;
            for (o, i) in rgb.chunks_exact_mut(3).zip(rgba[..n].chunks_exact(4)) {
                if premultiplied {
                    o.copy_from_slice(&i[..3]);
                } else {
                    let a = i[3] as u32;
                    for k in 0..3 {
                        o[k] = ((i[k] as u32 * a + 127) / 255) as u8;
                    }
                }
            }
            let q = (quality.clamp(0.0, 1.0) * 100.0).round().clamp(1.0, 100.0) as u8;
            image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, q).write_image(&rgb, w, h, image::ExtendedColorType::Rgb8).map_err(map_err)?;
        }
        _ => return Err(ERR_UNSUPPORTED),
    }
    let p = (sink.alloc)(sink.user, out.len());
    if p.is_null() {
        return Err(ERR_TOO_MUCH_MEMORY);
    }
    // SAFETY: the callback contract: a buffer of exactly out.len() bytes, owned by the caller.
    unsafe { std::ptr::copy_nonoverlapping(out.as_ptr(), p, out.len()) };
    Ok(())
}
