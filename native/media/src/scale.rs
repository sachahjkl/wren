//! Pixel geometry on tightly packed RGBA8 (straight alpha): area-average reduction, quarter turns, mirrors, crops.

use crate::{try_vec, ERR_CORRUPT};

/// Reduces `src` (sw x sh) to `dst` (dw x dh, each no larger): every destination pixel is the exact area average of the
/// source pixels it covers, weighted by alpha (so transparent pixels lend no colour to their neighbours).
pub fn reduce(src: &[u8], sw: usize, sh: usize, dst: &mut [u8], dw: usize, dh: usize) {
    if dw == 0 || dh == 0 || sw == 0 || sh == 0 {
        return;
    }
    let fx = sw as f64 / dw as f64;
    let fy = sh as f64 / dh as f64;
    // horizontal spans: for each destination column, the source columns with their coverage
    let spans = |n: usize, f: f64, limit: usize| -> Vec<(usize, Vec<f32>)> {
        (0..n)
            .map(|i| {
                let a = i as f64 * f;
                let b = ((i + 1) as f64 * f).min(limit as f64);
                let first = a.floor() as usize;
                let last = (b.ceil() as usize).min(limit).max(first + 1);
                let w = (first..last)
                    .map(|s| ((s as f64 + 1.0).min(b) - (s as f64).max(a)).max(0.0) as f32)
                    .collect();
                (first, w)
            })
            .collect()
    };
    let xs = spans(dw, fx, sw);
    let ys = spans(dh, fy, sh);
    let mut row = vec![[0f32; 4]; dw];
    for (dy, (y0, wy)) in ys.iter().enumerate() {
        for r in row.iter_mut() {
            *r = [0.0; 4];
        }
        for (k, &wyk) in wy.iter().enumerate() {
            let sy = y0 + k;
            let line = &src[sy * sw * 4..(sy + 1) * sw * 4];
            for (dx, (x0, wx)) in xs.iter().enumerate() {
                let acc = &mut row[dx];
                for (j, &wxj) in wx.iter().enumerate() {
                    let p = &line[(x0 + j) * 4..(x0 + j) * 4 + 4];
                    let w = wxj * wyk;
                    let a = p[3] as f32 * w;
                    acc[0] += p[0] as f32 * a;
                    acc[1] += p[1] as f32 * a;
                    acc[2] += p[2] as f32 * a;
                    acc[3] += a;
                }
            }
        }
        let area = (fx * fy) as f32;
        for (dx, acc) in row.iter().enumerate() {
            let o = (dy * dw + dx) * 4;
            let a = acc[3];
            if a <= 0.0 {
                dst[o..o + 4].copy_from_slice(&[0, 0, 0, 0]);
                continue;
            }
            dst[o] = (acc[0] / a + 0.5).min(255.0) as u8;
            dst[o + 1] = (acc[1] / a + 0.5).min(255.0) as u8;
            dst[o + 2] = (acc[2] / a + 0.5).min(255.0) as u8;
            dst[o + 3] = (a / area + 0.5).min(255.0) as u8;
        }
    }
}

/// Size to reduce to: `out_w` x `out_h` when given and smaller, else the natural size.
pub fn target(w: usize, h: usize, out_w: u32, out_h: u32) -> (usize, usize) {
    if out_w == 0 || out_h == 0 || (out_w as usize >= w && out_h as usize >= h) {
        return (w, h);
    }
    ((out_w as usize).clamp(1, w), (out_h as usize).clamp(1, h))
}

/// `src` (w x h) turned `quarters` x 90 degrees counter-clockwise; returns the new buffer and size.
pub fn rotate_ccw(src: &[u8], w: usize, h: usize, quarters: u32) -> Result<(Vec<u8>, usize, usize), i32> {
    let q = quarters % 4;
    let (dw, dh) = if q % 2 == 1 { (h, w) } else { (w, h) };
    let mut dst = try_vec(src.len())?;
    for y in 0..h {
        for x in 0..w {
            let (nx, ny) = match q {
                0 => (x, y),
                1 => (y, w - 1 - x),          // 90 CCW
                2 => (w - 1 - x, h - 1 - y),  // 180
                _ => (h - 1 - y, x),          // 270 CCW = 90 CW
            };
            let s = (y * w + x) * 4;
            let d = (ny * dw + nx) * 4;
            dst[d..d + 4].copy_from_slice(&src[s..s + 4]);
        }
    }
    Ok((dst, dw, dh))
}

/// Mirrors in place: `vertical` exchanges top and bottom, else left and right.
pub fn mirror(px: &mut [u8], w: usize, h: usize, vertical: bool) {
    if vertical {
        for y in 0..h / 2 {
            let (a, b) = px.split_at_mut((h - 1 - y) * w * 4);
            a[y * w * 4..(y + 1) * w * 4].swap_with_slice(&mut b[..w * 4]);
        }
    } else {
        for y in 0..h {
            let line = &mut px[y * w * 4..(y + 1) * w * 4];
            for x in 0..w / 2 {
                for c in 0..4 {
                    line.swap(x * 4 + c, (w - 1 - x) * 4 + c);
                }
            }
        }
    }
}

/// The rectangle (x, y, cw, ch) of `src` (w x h).
pub fn crop(src: &[u8], w: usize, h: usize, x: usize, y: usize, cw: usize, ch: usize) -> Result<Vec<u8>, i32> {
    if cw == 0 || ch == 0 || x + cw > w || y + ch > h {
        return Err(ERR_CORRUPT);
    }
    let mut dst = try_vec(cw * ch * 4)?;
    for r in 0..ch {
        let s = ((y + r) * w + x) * 4;
        dst[r * cw * 4..(r + 1) * cw * 4].copy_from_slice(&src[s..s + cw * 4]);
    }
    Ok(dst)
}

/// Premultiplied (tiny-skia) to straight alpha, in place.
pub fn unpremultiply(px: &mut [u8]) {
    for p in px.chunks_exact_mut(4) {
        let a = p[3] as u32;
        if a == 0 || a == 255 {
            continue;
        }
        for c in &mut p[..3] {
            *c = ((*c as u32 * 255 + a / 2) / a).min(255) as u8;
        }
    }
}
