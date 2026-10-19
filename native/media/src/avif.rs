//! AVIF: the container with zenavif-parse (items, alpha auxiliary image, grids, image sequences, colr / irot / imir / clap
//! properties; limits checked while parsing), AV1 with rav1d (dav1d's port: 8, 10 and 12 bits, every subsampling, film
//! grain), then YUV -> RGB here (matrix coefficients and range from the container's nclx, else from the AV1 sequence
//! header), colour to sRGB (nclx primaries / transfer or ICC, with qcms), the transformations in MIAF order: clean
//! aperture, rotation, mirror.

use crate::{check_size, color, frame_delay, scale, try_vec, FrameSink, Info, Limits};
use crate::{ERR_CORRUPT, ERR_TOO_MANY_FRAMES, ERR_TOO_MANY_PIXELS, ERR_TOO_MUCH_MEMORY, ERR_UNSUPPORTED};
use rav1d::include::dav1d::data::Dav1dData;
use rav1d::include::dav1d::dav1d::{Dav1dContext, Dav1dSettings};
use rav1d::include::dav1d::headers::{DAV1D_PIXEL_LAYOUT_I400, DAV1D_PIXEL_LAYOUT_I420, DAV1D_PIXEL_LAYOUT_I422};
use rav1d::include::dav1d::picture::Dav1dPicture;
use rav1d::src::lib::{dav1d_close, dav1d_data_create, dav1d_data_unref, dav1d_default_settings, dav1d_get_picture, dav1d_open, dav1d_picture_unref, dav1d_send_data};
use std::mem::MaybeUninit;
use std::ptr::NonNull;
use zenavif_parse::{AV1Metadata, AvifParser, ColorInformation, DecodeConfig, Error as AvifError};

const EAGAIN: i32 = 11;

fn map_parse(e: AvifError) -> i32 {
    match e {
        AvifError::OutOfMemory => ERR_TOO_MUCH_MEMORY,
        AvifError::ResourceLimitExceeded(s) if s.contains("frame") => ERR_TOO_MANY_FRAMES,
        AvifError::ResourceLimitExceeded(s) if s.contains("megapixel") => ERR_TOO_MANY_PIXELS,
        AvifError::ResourceLimitExceeded(_) => ERR_TOO_MUCH_MEMORY,
        AvifError::Unsupported(_) => ERR_UNSUPPORTED,
        _ => ERR_CORRUPT,
    }
}

fn parser<'a>(data: &'a [u8], l: &Limits, animate: bool) -> Result<AvifParser<'a>, i32> {
    let mp = ((l.max_pixels + 999_999) / 1_000_000).clamp(1, u32::MAX as u64) as u32;
    let mut cfg = DecodeConfig::default().with_peak_memory_limit(l.max_image_bytes.max(1 << 20)).with_total_megapixels_limit(mp);
    cfg = cfg.with_max_animation_frames(if animate { l.max_frames } else { u32::MAX });
    AvifParser::from_bytes_with_config(data, &cfg, &enough::Unstoppable).map_err(map_parse)
}

/// The clean aperture as a crop rectangle of a w x h picture, when it is valid and whole pixels (libavif's rules).
fn clap_rect(p: &AvifParser, w: u32, h: u32) -> Option<(usize, usize, usize, usize)> {
    let c = p.clean_aperture()?;
    if c.width_d == 0 || c.height_d == 0 || c.horiz_off_d == 0 || c.vert_off_d == 0 {
        return None;
    }
    let cw = c.width_n as f64 / c.width_d as f64;
    let ch = c.height_n as f64 / c.height_d as f64;
    let cx = c.horiz_off_n as f64 / c.horiz_off_d as f64 + (w as f64 - 1.0) / 2.0;
    let cy = c.vert_off_n as f64 / c.vert_off_d as f64 + (h as f64 - 1.0) / 2.0;
    let x0 = cx - (cw - 1.0) / 2.0;
    let y0 = cy - (ch - 1.0) / 2.0;
    let whole = |v: f64| v.fract() == 0.0;
    if !whole(cw) || !whole(ch) || !whole(x0) || !whole(y0) || cw < 1.0 || ch < 1.0 || x0 < 0.0 || y0 < 0.0 {
        return None;
    }
    let (x0, y0, cw, ch) = (x0 as usize, y0 as usize, cw as usize, ch as usize);
    if x0 + cw > w as usize || y0 + ch > h as usize {
        return None;
    }
    if (x0, y0, cw, ch) == (0, 0, w as usize, h as usize) {
        return None;
    }
    Some((x0, y0, cw, ch))
}

fn quarters(p: &AvifParser) -> u32 {
    p.rotation().map(|r| (r.angle as u32 / 90) % 4).unwrap_or(0)
}

/// Stored size of the picture (before clap / rotation): the grid's output, else the AV1 sequence header's.
fn coded_size(p: &AvifParser) -> Result<(u32, u32), i32> {
    if let Some(g) = p.grid_config() {
        return Ok((g.output_width, g.output_height));
    }
    let m: AV1Metadata = match p.primary_metadata() {
        Ok(m) => m,
        Err(_) => {
            // a sequence without a still primary item: the first frame
            let f = p.frame(0).map_err(map_parse)?;
            AV1Metadata::parse_av1_bitstream(&f.data).map_err(map_parse)?
        }
    };
    Ok((m.max_frame_width.get(), m.max_frame_height.get()))
}

fn shown_size(p: &AvifParser, w: u32, h: u32) -> (u32, u32) {
    let (w, h) = match clap_rect(p, w, h) {
        Some((_, _, cw, ch)) => (cw as u32, ch as u32),
        None => (w, h),
    };
    if quarters(p) % 2 == 1 { (h, w) } else { (w, h) }
}

pub fn probe(data: &[u8], l: &Limits) -> Result<Info, i32> {
    let p = parser(data, l, false)?;
    probe_parsed(&p, l)
}

////////////////////////////////
// rav1d

struct Av1 {
    ctx: Option<Dav1dContext>,
}

impl Drop for Av1 {
    fn drop(&mut self) {
        // SAFETY: ctx comes from dav1d_open (or is None).
        unsafe { dav1d_close(NonNull::new(&mut self.ctx)) };
    }
}

/// A decoded picture; unreferenced on drop.
struct Pic(Dav1dPicture);

impl Drop for Pic {
    fn drop(&mut self) {
        // SAFETY: the picture came from dav1d_get_picture.
        unsafe { dav1d_picture_unref(NonNull::new(&mut self.0)) };
    }
}

impl Av1 {
    fn open(l: &Limits, operating_point: u8) -> Result<Av1, i32> {
        let mut s = MaybeUninit::<Dav1dSettings>::uninit();
        // SAFETY: dav1d_default_settings fills the whole struct.
        let mut s = unsafe {
            dav1d_default_settings(NonNull::new(s.as_mut_ptr()).unwrap());
            s.assume_init()
        };
        s.n_threads = 1;            // the browser decodes several images at once on its own threads
        s.max_frame_delay = 1;
        s.apply_grain = 1;
        s.all_layers = 0;           // the highest spatial layer only
        s.operating_point = operating_point as i32;
        s.frame_size_limit = l.max_pixels.min(u32::MAX as u64) as u32;
        let mut ctx: Option<Dav1dContext> = None;
        // SAFETY: valid pointers to a settings struct and an output slot.
        let r = unsafe { dav1d_open(NonNull::new(&mut ctx), NonNull::new(&mut s)) };
        if r.0 != 0 || ctx.is_none() {
            return Err(if r.0 == -12 { ERR_TOO_MUCH_MEMORY } else { ERR_CORRUPT });
        }
        Ok(Av1 { ctx })
    }

    /// One temporal unit in, its picture out.
    fn decode(&mut self, obu: &[u8]) -> Result<Pic, i32> {
        if obu.is_empty() {
            return Err(ERR_CORRUPT);
        }
        let mut data = Dav1dData::default();
        // SAFETY: dav1d_data_create allocates `len` bytes owned by `data`; we fill them.
        unsafe {
            let p = dav1d_data_create(NonNull::new(&mut data), obu.len());
            if p.is_null() {
                return Err(ERR_TOO_MUCH_MEMORY);
            }
            std::ptr::copy_nonoverlapping(obu.as_ptr(), p, obu.len());
        }
        let mut pic = Pic(Dav1dPicture::default());
        let mut got = false;
        let mut result = Ok(());
        for _ in 0..64 {
            if data.sz == 0 {
                break;
            }
            // SAFETY: ctx is open; data is valid.
            let r = unsafe { dav1d_send_data(self.ctx, NonNull::new(&mut data)) };
            if r.0 == 0 {
                continue;
            }
            if r.0 != -EAGAIN {
                result = Err(if r.0 == -12 { ERR_TOO_MUCH_MEMORY } else { ERR_CORRUPT });
                break;
            }
            // the decoder wants its output taken first
            if !got {
                // SAFETY: as above.
                let g = unsafe { dav1d_get_picture(self.ctx, NonNull::new(&mut pic.0)) };
                if g.0 == 0 {
                    got = true;
                } else if g.0 != -EAGAIN {
                    result = Err(ERR_CORRUPT);
                    break;
                }
            } else {
                break;
            }
        }
        if data.sz != 0 {
            // SAFETY: data still holds a reference.
            unsafe { dav1d_data_unref(NonNull::new(&mut data)) };
        }
        result?;
        if !got {
            for _ in 0..4 {
                // SAFETY: as above.
                let g = unsafe { dav1d_get_picture(self.ctx, NonNull::new(&mut pic.0)) };
                if g.0 == 0 {
                    got = true;
                    break;
                }
                if g.0 != -EAGAIN {
                    return Err(if g.0 == -12 { ERR_TOO_MUCH_MEMORY } else { ERR_CORRUPT });
                }
            }
        }
        if !got || pic.0.p.w <= 0 || pic.0.p.h <= 0 {
            return Err(ERR_CORRUPT);
        }
        Ok(pic)
    }
}

////////////////////////////////
// YUV -> RGB

#[derive(Clone, Copy)]
struct Cicp {
    primaries: u16,
    transfer: u16,
    matrix: u16,
    full: bool,
}

fn cicp_of(pic: &Dav1dPicture, nclx: Option<Cicp>) -> Cicp {
    if let Some(c) = nclx {
        return c;
    }
    match pic.seq_hdr {
        // SAFETY: the sequence header lives as long as the picture.
        Some(sh) => unsafe {
            let s = sh.as_ref();
            Cicp { primaries: s.pri as u16, transfer: s.trc as u16, matrix: s.mtrx as u16, full: s.color_range != 0 }
        },
        None => Cicp { primaries: 2, transfer: 2, matrix: 2, full: false },
    }
}

/// Kr, Kb of a matrix (H.273 table 4); the chromaticity-derived ones from the primaries.
fn kr_kb(matrix: u16, primaries: u16) -> (f32, f32) {
    match matrix {
        1 => (0.2126, 0.0722),
        4 => (0.30, 0.11),
        7 => (0.212, 0.087),
        9 | 10 => (0.2627, 0.0593),
        12 | 13 => match primaries {
            1 | 2 => (0.2126, 0.0722),
            9 => (0.2627, 0.0593),
            12 => (0.2290, 0.0793),   // Display P3
            11 => (0.2095, 0.0689),   // DCI-P3
            _ => (0.299, 0.114),
        },
        14 => (0.2126, 0.0722),       // ICtCp: not supported, shown as BT.709
        _ => (0.299, 0.114),          // BT.601 (5, 6) and unspecified, as libavif and browsers
    }
}

/// Samples of a plane row as f32 code values.
#[inline]
fn sample(plane: *const u8, stride: isize, x: usize, y: usize, hbd: bool) -> f32 {
    // SAFETY: callers keep (x, y) inside the plane.
    unsafe {
        if hbd {
            *(plane.offset(y as isize * stride) as *const u16).add(x) as f32
        } else {
            *plane.offset(y as isize * stride + x as isize) as f32
        }
    }
}

/// Bilinear chroma sample positions for each luma coordinate: (i0, i1, weight of i1).
fn chroma_taps(n: usize, sub: bool, cn: usize) -> Vec<(usize, usize, f32)> {
    (0..n)
        .map(|i| {
            if !sub {
                let c = i.min(cn - 1);
                return (c, c, 0.0);
            }
            let p = ((i as f32 + 0.5) * 0.5 - 0.5).max(0.0);
            let i0 = (p.floor() as usize).min(cn - 1);
            let i1 = (i0 + 1).min(cn - 1);
            (i0, i1, p - p.floor())
        })
        .collect()
}

/// One row of a plane as normalised values: `lut[code]`, every `w` samples.
fn plane_row(plane: *const u8, stride: isize, y: usize, w: usize, hbd: bool, lut: &[f32], out: &mut [f32]) {
    // SAFETY: rows and columns stay inside the plane (callers pass its own dimensions).
    unsafe {
        let row = plane.offset(y as isize * stride);
        if hbd {
            let r = row as *const u16;
            for (x, o) in out[..w].iter_mut().enumerate() {
                *o = lut[(*r.add(x) as usize).min(lut.len() - 1)];
            }
        } else {
            for (x, o) in out[..w].iter_mut().enumerate() {
                *o = lut[*row.add(x) as usize];
            }
        }
    }
}

/// The picture as RGBA8 into `out` (w x h, alpha 255). Chroma is upsampled bilinearly (sample centres between luma
/// samples, as libavif's default); normalisation goes through lookup tables, chroma rows are made once and kept.
fn to_rgba(pic: &Dav1dPicture, cicp: Cicp, out: &mut [u8]) -> Result<(), i32> {
    let w = pic.p.w as usize;
    let h = pic.p.h as usize;
    let bpc = pic.p.bpc as u32;
    if !(8..=12).contains(&bpc) {
        return Err(ERR_UNSUPPORTED);
    }
    let hbd = bpc > 8;
    let layout = pic.p.layout;
    let (sx, sy) = match layout {
        DAV1D_PIXEL_LAYOUT_I420 => (true, true),
        DAV1D_PIXEL_LAYOUT_I422 => (true, false),
        _ => (false, false),
    };
    let mono = layout == DAV1D_PIXEL_LAYOUT_I400;
    let ydata = pic.data[0].ok_or(ERR_CORRUPT)?.as_ptr() as *const u8;
    let (udata, vdata) = if mono {
        (ydata, ydata)
    } else {
        (pic.data[1].ok_or(ERR_CORRUPT)?.as_ptr() as *const u8, pic.data[2].ok_or(ERR_CORRUPT)?.as_ptr() as *const u8)
    };
    let ys = pic.stride[0];
    let cs = pic.stride[1];
    let cw = if sx { (w + 1) / 2 } else { w };
    let chh = if sy { (h + 1) / 2 } else { h };
    let max = ((1u32 << bpc) - 1) as f32;
    let shift = (1u32 << (bpc - 8)) as f32;
    let identity = cicp.matrix == 0;
    let ycgco = cicp.matrix == 8;
    let (y_off, y_scale, c_off, c_scale) = if cicp.full {
        (0.0, 1.0 / max, (1u32 << (bpc - 1)) as f32, 1.0 / max)
    } else {
        (16.0 * shift, 1.0 / (219.0 * shift), 128.0 * shift, 1.0 / (224.0 * shift))
    };
    let n = 1usize << bpc;
    let ylut: Vec<f32> = (0..n).map(|c| (c as f32 - y_off) * y_scale).collect();
    // identity (GBR): the chroma planes hold B and R with the luma range
    let clut: Vec<f32> = if identity { ylut.clone() } else { (0..n).map(|c| (c as f32 - c_off) * c_scale).collect() };
    let (kr, kb) = kr_kb(cicp.matrix, cicp.primaries);
    let kg = 1.0 - kr - kb;
    let (cr_r, cb_b) = (2.0 * (1.0 - kr), 2.0 * (1.0 - kb));
    let (g_r, g_b, inv_kg) = (kr / kg, kb / kg, 1.0 / kg);
    let xt = chroma_taps(w, sx, cw);
    let yt = chroma_taps(h, sy, chh);
    // chroma rows upsampled horizontally, cached by chroma row index (two are needed at a time)
    let mut raw = vec![0f32; cw];
    let mut rows: [(usize, Vec<f32>, Vec<f32>); 2] = [(usize::MAX, vec![0f32; w], vec![0f32; w]), (usize::MAX, vec![0f32; w], vec![0f32; w])];
    let mut make_row = |cy: usize, slot: &mut (usize, Vec<f32>, Vec<f32>)| {
        if slot.0 == cy {
            return;
        }
        slot.0 = cy;
        for (plane, dst) in [(udata, &mut slot.1), (vdata, &mut slot.2)] {
            plane_row(plane, cs, cy, cw, hbd, &clut, &mut raw);
            for (x, d) in dst.iter_mut().enumerate() {
                let (c0, c1, f) = xt[x];
                *d = raw[c0] + (raw[c1] - raw[c0]) * f;
            }
        }
    };
    let mut yrow = vec![0f32; w];
    let to8 = |v: f32| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
    for y in 0..h {
        plane_row(ydata, ys, y, w, hbd, &ylut, &mut yrow);
        let row = &mut out[y * w * 4..(y + 1) * w * 4];
        if mono {
            for (x, &yy) in yrow.iter().enumerate() {
                let v = to8(yy);
                row[x * 4..x * 4 + 4].copy_from_slice(&[v, v, v, 255]);
            }
            continue;
        }
        let (cy0, cy1, fy) = yt[y];
        // keep the slot of cy0 if either slot has it, the other one for cy1
        let (a, b) = rows.split_at_mut(1);
        let (s0, s1) = if b[0].0 == cy0 { (&mut b[0], &mut a[0]) } else { (&mut a[0], &mut b[0]) };
        make_row(cy0, s0);
        make_row(cy1, s1);
        let (u0, v0, u1, v1) = (&s0.1, &s0.2, &s1.1, &s1.2);
        for x in 0..w {
            let u = u0[x] + (u1[x] - u0[x]) * fy;
            let v = v0[x] + (v1[x] - v0[x]) * fy;
            let yy = yrow[x];
            let (r, g, b) = if identity {
                (v, yy, u)
            } else if ycgco {
                let t = yy - u;
                (t + v, yy + u, t - v)
            } else {
                let r = yy + cr_r * v;
                let b = yy + cb_b * u;
                (r, yy * inv_kg - g_r * r - g_b * b, b)
            };
            let o = x * 4;
            row[o] = to8(r);
            row[o + 1] = to8(g);
            row[o + 2] = to8(b);
            row[o + 3] = 255;
        }
    }
    Ok(())
}
/// The alpha picture's luma into the alpha channel of `out` (same size), then straight alpha if it was premultiplied.
fn apply_alpha(pic: &Dav1dPicture, out: &mut [u8], w: usize, h: usize, premultiplied: bool) -> Result<(), i32> {
    if pic.p.w as usize != w || pic.p.h as usize != h {
        return Err(ERR_CORRUPT);
    }
    let bpc = pic.p.bpc as u32;
    let hbd = bpc > 8;
    let full = match pic.seq_hdr {
        // SAFETY: lives as long as the picture.
        Some(sh) => unsafe { sh.as_ref().color_range != 0 },
        None => true,
    };
    let max = ((1u32 << bpc) - 1) as f32;
    let shift = (1u32 << (bpc - 8)) as f32;
    let (off, sc) = if full { (0.0, 1.0 / max) } else { (16.0 * shift, 1.0 / (219.0 * shift)) };
    let ydata = pic.data[0].ok_or(ERR_CORRUPT)?.as_ptr() as *const u8;
    for y in 0..h {
        for x in 0..w {
            let a = ((sample(ydata, pic.stride[0], x, y, hbd) - off) * sc).clamp(0.0, 1.0);
            out[(y * w + x) * 4 + 3] = (a * 255.0 + 0.5) as u8;
        }
    }
    if premultiplied {
        scale::unpremultiply(out);
    }
    Ok(())
}

fn nclx_of(p: &AvifParser) -> Option<Cicp> {
    match p.color_info() {
        Some(ColorInformation::Nclx { color_primaries, transfer_characteristics, matrix_coefficients, full_range }) => Some(Cicp {
            primaries: *color_primaries,
            transfer: *transfer_characteristics,
            matrix: *matrix_coefficients,
            full: *full_range,
        }),
        _ => None,
    }
}

/// Colour, clean aperture, rotation, mirror: the picture as the file means it to be shown.
fn finish(p: &AvifParser, l: &Limits, mut px: Vec<u8>, mut w: usize, mut h: usize, cicp: Cicp) -> Result<(Vec<u8>, usize, usize), i32> {
    if l.color_manage != 0 {
        match p.color_info() {
            Some(ColorInformation::IccProfile(icc)) => {
                let _ = color::icc_to_srgb(icc, &mut px);
            }
            _ => {
                let _ = color::cicp_to_srgb(cicp.primaries, cicp.transfer, &mut px);
            }
        }
    }
    if let Some((x, y, cw, ch)) = clap_rect(p, w as u32, h as u32) {
        px = scale::crop(&px, w, h, x, y, cw, ch)?;
        w = cw;
        h = ch;
    }
    let q = quarters(p);
    if q != 0 {
        let (r, rw, rh) = scale::rotate_ccw(&px, w, h, q)?;
        px = r;
        w = rw;
        h = rh;
    }
    if let Some(m) = p.mirror() {
        // ISO/IEC 23008-12:2022: axis 0 exchanges top and bottom, 1 left and right
        scale::mirror(&mut px, w, h, m.axis == 0);
    }
    Ok((px, w, h))
}

/// The still image (primary item, or grid of tiles) as RGBA at its coded size.
fn decode_still(p: &AvifParser, l: &Limits, op: u8) -> Result<(Vec<u8>, usize, usize, Cicp), i32> {
    let nclx = nclx_of(p);
    let mut dec = Av1::open(l, op)?;
    let (mut px, w, h, cicp) = if let Some(g) = p.grid_config().cloned() {
        let (ow, oh) = (g.output_width as usize, g.output_height as usize);
        check_size(ow as u64, oh as u64, l)?;
        let n = p.grid_tile_count();
        if n == 0 || n != g.rows as usize * g.columns as usize {
            return Err(ERR_CORRUPT);
        }
        let mut canvas = try_vec(ow * oh * 4)?;
        let mut cicp = nclx.unwrap_or(Cicp { primaries: 2, transfer: 2, matrix: 2, full: false });
        let mut tile_w = 0usize;
        let mut tile_h = 0usize;
        for i in 0..n {
            let data = p.tile_data(i).map_err(map_parse)?;
            let pic = dec.decode(&data)?;
            let (tw, th) = (pic.0.p.w as usize, pic.0.p.h as usize);
            if i == 0 {
                tile_w = tw;
                tile_h = th;
                cicp = cicp_of(&pic.0, nclx);
            } else if (tw, th) != (tile_w, tile_h) {
                return Err(ERR_CORRUPT);
            }
            check_size(tw as u64, th as u64, l)?;
            let mut tile = try_vec(tw * th * 4)?;
            to_rgba(&pic.0, cicp, &mut tile)?;
            let (gx, gy) = ((i % g.columns as usize) * tw, (i / g.columns as usize) * th);
            for r in 0..th {
                let y = gy + r;
                if y >= oh || gx >= ow {
                    continue;
                }
                let n = tw.min(ow - gx);
                canvas[(y * ow + gx) * 4..(y * ow + gx + n) * 4].copy_from_slice(&tile[r * tw * 4..(r * tw + n) * 4]);
            }
        }
        (canvas, ow, oh, cicp)
    } else {
        let data = p.primary_data().map_err(map_parse)?;
        let pic = dec.decode(&data)?;
        let (w, h) = (pic.0.p.w as usize, pic.0.p.h as usize);
        check_size(w as u64, h as u64, l)?;
        let cicp = cicp_of(&pic.0, nclx);
        let mut px = try_vec(w * h * 4)?;
        to_rgba(&pic.0, cicp, &mut px)?;
        (px, w, h, cicp)
    };
    if let Some(alpha) = p.alpha_data() {
        if let Ok(a) = alpha {
            let mut adec = Av1::open(l, op)?;
            if let Ok(apic) = adec.decode(&a) {
                // an alpha plane of another size (a grid's alpha grid) is not applied: the image stays opaque
                let _ = apply_alpha(&apic.0, &mut px, w, h, p.premultiplied_alpha());
            }
        }
    }
    Ok((px, w, h, cicp))
}

pub fn decode(data: &[u8], l: &Limits, out_w: u32, out_h: u32, sink: &FrameSink, info: &mut Info) -> Result<(), i32> {
    let animate = l.first_frame_only == 0;
    let p = parser(data, l, animate)?;
    *info = probe_parsed(&p, l)?;
    let op = p.operating_point().map(|o| o.op_index).unwrap_or(0);

    if animate && info.animated != 0 {
        let n = info.frames as u64;
        if n > l.max_frames as u64 {
            return Err(ERR_TOO_MANY_FRAMES);
        }
        let (cw, ch) = coded_size(&p)?;
        let (sw, sh) = shown_size(&p, cw, ch);
        if sw as u64 * sh as u64 * 4 * n > l.max_image_bytes {
            return Err(ERR_TOO_MUCH_MEMORY);
        }
        let nclx = nclx_of(&p);
        let mut dec = Av1::open(l, op)?;
        let mut adec: Option<Av1> = None;
        let mut size: Option<(usize, usize)> = None;
        for i in 0..info.frames {
            let f = match p.frame(i as usize) {
                Ok(f) => f,
                Err(e) if i == 0 => return Err(map_parse(e)),
                Err(_) => break,
            };
            let pic = match dec.decode(&f.data) {
                Ok(pic) => pic,
                Err(e) if i == 0 => return Err(e),
                Err(_) => break,   // a damaged frame ends the animation there
            };
            let (w, h) = (pic.0.p.w as usize, pic.0.p.h as usize);
            if *size.get_or_insert((w, h)) != (w, h) {
                break;
            }
            check_size(w as u64, h as u64, l)?;
            let cicp = cicp_of(&pic.0, nclx);
            let mut px = try_vec(w * h * 4)?;
            to_rgba(&pic.0, cicp, &mut px)?;
            drop(pic);
            if let Some(a) = &f.alpha_data {
                if adec.is_none() {
                    adec = Some(Av1::open(l, op)?);
                }
                if let Some(ad) = adec.as_mut() {
                    if let Ok(apic) = ad.decode(a) {
                        let _ = apply_alpha(&apic.0, &mut px, w, h, p.premultiplied_alpha());
                    }
                }
            }
            let (px, fw, fh) = finish(&p, l, px, w, h, cicp)?;
            let out = sink.frame(i, fw as u32, fh as u32, frame_delay(f.duration_ms, l))?;
            if out.len() != px.len() {
                return Err(ERR_CORRUPT);
            }
            out.copy_from_slice(&px);
        }
        return Ok(());
    }

    info.animated = 0;
    let (px, w, h, cicp) = match decode_still(&p, l, op) {
        Ok(v) => v,
        Err(e) => {
            // an image sequence without a still primary item: its first frame
            if p.animation_info().is_none() {
                return Err(e);
            }
            let f = p.frame(0).map_err(map_parse)?;
            let mut dec = Av1::open(l, op)?;
            let pic = dec.decode(&f.data)?;
            let (w, h) = (pic.0.p.w as usize, pic.0.p.h as usize);
            check_size(w as u64, h as u64, l)?;
            let cicp = cicp_of(&pic.0, nclx_of(&p));
            let mut px = try_vec(w * h * 4)?;
            to_rgba(&pic.0, cicp, &mut px)?;
            (px, w, h, cicp)
        }
    };
    let (px, w, h) = finish(&p, l, px, w, h, cicp)?;
    let (tw, th) = scale::target(w, h, out_w, out_h);
    let out = sink.frame(0, tw as u32, th as u32, 0)?;
    if (tw, th) == (w, h) {
        out.copy_from_slice(&px);
    } else {
        scale::reduce(&px, w, h, out, tw, th);
    }
    Ok(())
}

fn probe_parsed(p: &AvifParser, l: &Limits) -> Result<Info, i32> {
    let (cw, ch) = coded_size(p)?;
    check_size(cw as u64, ch as u64, l)?;
    let (w, h) = shown_size(p, cw, ch);
    let mut info = Info { width: w, height: h, frames: 1, plays: 1, ..Default::default() };
    info.has_alpha = p.alpha_data().is_some() as u8;
    info.bit_depth = p.av1_config().map(|c| c.bit_depth).unwrap_or(8);
    info.color = match p.color_info() {
        Some(ColorInformation::IccProfile(_)) => 1,
        Some(ColorInformation::Nclx { .. }) => 2,
        None => 0,
    };
    if let Some(a) = p.animation_info() {
        info.frames = a.frame_count as u32;
        info.animated = (a.frame_count > 1) as u8;
        info.plays = a.loop_count;
        info.has_alpha |= a.has_alpha as u8;
    }
    Ok(info)
}
