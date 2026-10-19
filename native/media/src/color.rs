//! Colour management with qcms (Firefox's): the browser composes in sRGB, so pixels tagged with another space (an ICC
//! profile, CICP code points, EXIF's Adobe RGB) are converted to sRGB once, when decoded.

use crate::ERR_UNSUPPORTED;
use qcms::{DataType, Intent, Profile, Transform};

fn apply(input: &Profile, px: &mut [u8]) -> Result<(), i32> {
    if input.is_sRGB() {
        return Ok(());
    }
    let mut out = Profile::new_sRGB();
    out.precache_output_transform();
    let t = Transform::new(input, &out, DataType::RGBA8, Intent::Perceptual).ok_or(ERR_UNSUPPORTED)?;
    t.apply(px);
    Ok(())
}

/// ICC profile -> sRGB. Grey and CMYK profiles are not for RGBA pixels: refused (left as is).
pub fn icc_to_srgb(icc: &[u8], px: &mut [u8]) -> Result<(), i32> {
    if icc.len() < 132 {
        return Err(ERR_UNSUPPORTED);
    }
    let p = Profile::new_from_slice(icc, false).ok_or(ERR_UNSUPPORTED)?;
    apply(&p, px)
}

/// CICP (ITU-T H.273) primaries and transfer -> sRGB. The code points that are sRGB for every practical purpose (BT.709
/// primaries or unspecified, with the sRGB, BT.709 / BT.601 / BT.2020 curves or unspecified: browsers show those as
/// sRGB) are left alone; HDR transfers (PQ, HLG) qcms cannot build are left as they are.
pub fn cicp_to_srgb(primaries: u16, transfer: u16, px: &mut [u8]) -> Result<(), i32> {
    if is_srgb_like(primaries, transfer) {
        return Ok(());
    }
    let cp = if primaries == 2 { 1 } else { primaries.min(255) as u8 };
    let tc = match transfer {
        2 => 13,
        t => t.min(255) as u8,
    };
    let p = Profile::new_cicp(cp.into(), tc.into()).ok_or(ERR_UNSUPPORTED)?;
    apply(&p, px)
}

pub fn is_srgb_like(primaries: u16, transfer: u16) -> bool {
    matches!(primaries, 1 | 2) && matches!(transfer, 1 | 2 | 6 | 13 | 14 | 15)
}

/// Adobe RGB (1998): its primaries, D65, gamma 563/256.
pub fn adobe_to_srgb(px: &mut [u8]) -> Result<(), i32> {
    let white = qcms::CIE_xyY { x: 0.3127, y: 0.3290, Y: 1.0 };
    let prim = qcms::CIE_xyYTRIPLE {
        red: qcms::CIE_xyY { x: 0.64, y: 0.33, Y: 1.0 },
        green: qcms::CIE_xyY { x: 0.21, y: 0.71, Y: 1.0 },
        blue: qcms::CIE_xyY { x: 0.15, y: 0.06, Y: 1.0 },
    };
    let g = 563.0 / 256.0;
    let p = Profile::new_rgb_with_gamma_set(white, prim, g, g, g).ok_or(ERR_UNSUPPORTED)?;
    apply(&p, px)
}
