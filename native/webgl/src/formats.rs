//! Texture and renderbuffer formats: GL's triples (internal format, format, type) to wgpu's formats, and pixels from what a
//! page gives to what the texture holds. wgpu has no RGB formats, no luminance and no swizzle: RGB and LUMINANCE become RGBA
//! on upload.

use wgpu::TextureFormat as F;

pub const RGBA: u32 = 0x1908;
pub const RGB: u32 = 0x1907;
pub const ALPHA: u32 = 0x1906;
pub const LUMINANCE: u32 = 0x1909;
pub const LUMINANCE_ALPHA: u32 = 0x190A;
pub const RED: u32 = 0x1903;
pub const RG: u32 = 0x8227;
pub const RED_INTEGER: u32 = 0x8D94;
pub const RG_INTEGER: u32 = 0x8228;
pub const RGB_INTEGER: u32 = 0x8D98;
pub const RGBA_INTEGER: u32 = 0x8D99;
pub const DEPTH_COMPONENT: u32 = 0x1902;
pub const DEPTH_STENCIL: u32 = 0x84F9;
pub const SRGB_EXT: u32 = 0x8C40;
pub const SRGB_ALPHA_EXT: u32 = 0x8C42;

pub const BYTE: u32 = 0x1400;
pub const UNSIGNED_BYTE: u32 = 0x1401;
pub const SHORT: u32 = 0x1402;
pub const UNSIGNED_SHORT: u32 = 0x1403;
pub const INT: u32 = 0x1404;
pub const UNSIGNED_INT: u32 = 0x1405;
pub const FLOAT: u32 = 0x1406;
pub const HALF_FLOAT: u32 = 0x140B;
pub const HALF_FLOAT_OES: u32 = 0x8D61;
pub const UNSIGNED_SHORT_4_4_4_4: u32 = 0x8033;
pub const UNSIGNED_SHORT_5_5_5_1: u32 = 0x8034;
pub const UNSIGNED_SHORT_5_6_5: u32 = 0x8363;
pub const UNSIGNED_INT_2_10_10_10_REV: u32 = 0x8368;
pub const UNSIGNED_INT_10F_11F_11F_REV: u32 = 0x8C3B;
pub const UNSIGNED_INT_5_9_9_9_REV: u32 = 0x8C3E;
pub const UNSIGNED_INT_24_8: u32 = 0x84FA;
pub const FLOAT_32_UNSIGNED_INT_24_8_REV: u32 = 0x8DAD;

// sized internal formats
const R8: u32 = 0x8229;
const R8_SNORM: u32 = 0x8F94;
const RG8: u32 = 0x822B;
const RG8_SNORM: u32 = 0x8F95;
const RGB8: u32 = 0x8051;
const RGB8_SNORM: u32 = 0x8F96;
const RGB565: u32 = 0x8D62;
const RGBA4: u32 = 0x8056;
const RGB5_A1: u32 = 0x8057;
const RGBA8: u32 = 0x8058;
const RGBA8_SNORM: u32 = 0x8F97;
const RGB10_A2: u32 = 0x8059;
const RGB10_A2UI: u32 = 0x906F;
const SRGB8: u32 = 0x8C41;
const SRGB8_ALPHA8: u32 = 0x8C43;
const R16F: u32 = 0x822D;
const RG16F: u32 = 0x822F;
const RGB16F: u32 = 0x881B;
const RGBA16F: u32 = 0x881A;
const R32F: u32 = 0x822E;
const RG32F: u32 = 0x8230;
const RGB32F: u32 = 0x8815;
const RGBA32F: u32 = 0x8814;
const R11F_G11F_B10F: u32 = 0x8C3A;
const RGB9_E5: u32 = 0x8C3D;
const R8I: u32 = 0x8231;
const R8UI: u32 = 0x8232;
const R16I: u32 = 0x8233;
const R16UI: u32 = 0x8234;
const R32I: u32 = 0x8235;
const R32UI: u32 = 0x8236;
const RG8I: u32 = 0x8237;
const RG8UI: u32 = 0x8238;
const RG16I: u32 = 0x8239;
const RG16UI: u32 = 0x823A;
const RG32I: u32 = 0x823B;
const RG32UI: u32 = 0x823C;
const RGBA8I: u32 = 0x8D8E;
const RGBA8UI: u32 = 0x8D7C;
const RGBA16I: u32 = 0x8D88;
const RGBA16UI: u32 = 0x8D76;
const RGBA32I: u32 = 0x8D82;
const RGBA32UI: u32 = 0x8D70;
const RGB8I: u32 = 0x8D8F;
const RGB8UI: u32 = 0x8D7D;
const RGB16I: u32 = 0x8D89;
const RGB16UI: u32 = 0x8D77;
const RGB32I: u32 = 0x8D83;
const RGB32UI: u32 = 0x8D71;
pub const DEPTH_COMPONENT16: u32 = 0x81A5;
const DEPTH_COMPONENT24: u32 = 0x81A6;
const DEPTH_COMPONENT32F: u32 = 0x8CAC;
pub const DEPTH24_STENCIL8: u32 = 0x88F0;
const DEPTH32F_STENCIL8: u32 = 0x8CAD;
pub const STENCIL_INDEX8: u32 = 0x8D48;
// RGBA32F as WEBGL_color_buffer_float and EXT_sRGB name them
pub const RGBA32F_EXT: u32 = RGBA32F;

/// What a texture holds, as far as GL can tell.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Fmt {
    pub wgpu: F,
    /// The internal format getParameter and friends speak of (the format itself in WebGL 1).
    pub internal: u32,
    /// Channels of the original format, for what uploading fills in (see `Channels`).
    pub channels: Channels,
}

/// How the channels of what is uploaded map to the RGBA of the texture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Channels {
    Same,
    /// RGB: alpha is 1
    Rgb,
    /// L: rrr1
    Luminance,
    /// LA: rrra
    LuminanceAlpha,
    /// A: 000a
    Alpha,
}

impl Fmt {
    pub fn is_depth(&self) -> bool {
        self.wgpu.has_depth_aspect()
    }
    pub fn has_stencil(&self) -> bool {
        self.wgpu.has_stencil_aspect()
    }
    pub fn is_depth_or_stencil(&self) -> bool {
        self.is_depth() || self.has_stencil()
    }
    /// Sint or Uint.
    pub fn is_integer(&self) -> bool {
        matches!(self.sample_kind(), SampleKind::Sint | SampleKind::Uint)
    }
    pub fn sample_kind(&self) -> SampleKind {
        sample_kind(self.wgpu)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SampleKind {
    Float,
    Sint,
    Uint,
    Depth,
}

pub fn sample_kind(f: F) -> SampleKind {
    match f {
        F::R8Sint | F::R16Sint | F::R32Sint | F::Rg8Sint | F::Rg16Sint | F::Rg32Sint | F::Rgba8Sint | F::Rgba16Sint | F::Rgba32Sint => SampleKind::Sint,
        F::R8Uint | F::R16Uint | F::R32Uint | F::Rg8Uint | F::Rg16Uint | F::Rg32Uint | F::Rgba8Uint | F::Rgba16Uint | F::Rgba32Uint | F::Rgb10a2Uint => SampleKind::Uint,
        F::Depth16Unorm | F::Depth24Plus | F::Depth24PlusStencil8 | F::Depth32Float | F::Depth32FloatStencil8 | F::Stencil8 => SampleKind::Depth,
        _ => SampleKind::Float,
    }
}

/// A sized or unsized internal format with its format and type, as texImage says it. None: the combination is not valid.
pub fn texture_format(internal: u32, format: u32, ty: u32, webgl2: bool) -> Option<Fmt> {
    let f = |wgpu, channels| Some(Fmt { wgpu, internal, channels });
    // the unsized formats of WebGL 1 (and 2)
    if internal == format {
        match (format, ty) {
            (RGBA, UNSIGNED_BYTE | UNSIGNED_SHORT_4_4_4_4 | UNSIGNED_SHORT_5_5_5_1) => return f(F::Rgba8Unorm, Channels::Same),
            (RGB, UNSIGNED_BYTE | UNSIGNED_SHORT_5_6_5) => return f(F::Rgba8Unorm, Channels::Rgb),
            (LUMINANCE, UNSIGNED_BYTE) => return f(F::Rgba8Unorm, Channels::Luminance),
            (LUMINANCE_ALPHA, UNSIGNED_BYTE) => return f(F::Rgba8Unorm, Channels::LuminanceAlpha),
            (ALPHA, UNSIGNED_BYTE) => return f(F::Rgba8Unorm, Channels::Alpha),
            (RGBA, FLOAT) => return f(F::Rgba32Float, Channels::Same),
            (RGB, FLOAT) => return f(F::Rgba32Float, Channels::Rgb),
            (LUMINANCE, FLOAT) => return f(F::Rgba32Float, Channels::Luminance),
            (LUMINANCE_ALPHA, FLOAT) => return f(F::Rgba32Float, Channels::LuminanceAlpha),
            (ALPHA, FLOAT) => return f(F::Rgba32Float, Channels::Alpha),
            (RGBA, HALF_FLOAT_OES | HALF_FLOAT) => return f(F::Rgba16Float, Channels::Same),
            (RGB, HALF_FLOAT_OES | HALF_FLOAT) => return f(F::Rgba16Float, Channels::Rgb),
            (LUMINANCE, HALF_FLOAT_OES | HALF_FLOAT) => return f(F::Rgba16Float, Channels::Luminance),
            (LUMINANCE_ALPHA, HALF_FLOAT_OES | HALF_FLOAT) => return f(F::Rgba16Float, Channels::LuminanceAlpha),
            (ALPHA, HALF_FLOAT_OES | HALF_FLOAT) => return f(F::Rgba16Float, Channels::Alpha),
            (DEPTH_COMPONENT, UNSIGNED_SHORT) => return f(F::Depth16Unorm, Channels::Same),
            (DEPTH_COMPONENT, UNSIGNED_INT) => return f(F::Depth24Plus, Channels::Same),
            (DEPTH_STENCIL, UNSIGNED_INT_24_8) => return f(F::Depth24PlusStencil8, Channels::Same),
            (SRGB_ALPHA_EXT, UNSIGNED_BYTE) => return f(F::Rgba8UnormSrgb, Channels::Same),
            (SRGB_EXT, UNSIGNED_BYTE) => return f(F::Rgba8UnormSrgb, Channels::Rgb),
            _ => return None,
        }
    }
    if !webgl2 {
        return None;
    }
    let ok = match (internal, format) {
        (R8 | R8_SNORM | R16F | R32F, RED) => true,
        (R8UI | R8I | R16UI | R16I | R32UI | R32I, RED_INTEGER) => true,
        (RG8 | RG8_SNORM | RG16F | RG32F, RG) => true,
        (RG8UI | RG8I | RG16UI | RG16I | RG32UI | RG32I, RG_INTEGER) => true,
        (RGB8 | SRGB8 | RGB565 | RGB8_SNORM | R11F_G11F_B10F | RGB9_E5 | RGB16F | RGB32F, RGB) => true,
        (RGB8UI | RGB8I | RGB16UI | RGB16I | RGB32UI | RGB32I, RGB_INTEGER) => true,
        (RGBA8 | SRGB8_ALPHA8 | RGBA8_SNORM | RGB5_A1 | RGBA4 | RGB10_A2 | RGBA16F | RGBA32F, RGBA) => true,
        (RGBA8UI | RGBA8I | RGB10_A2UI | RGBA16UI | RGBA16I | RGBA32UI | RGBA32I, RGBA_INTEGER) => true,
        (DEPTH_COMPONENT16 | DEPTH_COMPONENT24 | DEPTH_COMPONENT32F, DEPTH_COMPONENT) => true,
        (DEPTH24_STENCIL8 | DEPTH32F_STENCIL8, DEPTH_STENCIL) => true,
        _ => false,
    };
    if !ok {
        return None;
    }
    sized_format(internal).filter(|_| type_fits(internal, ty))
}

/// A sized internal format (texStorage, renderbufferStorage).
pub fn sized_format(internal: u32) -> Option<Fmt> {
    let f = |wgpu, channels| Some(Fmt { wgpu, internal, channels });
    match internal {
        R8 => f(F::R8Unorm, Channels::Same),
        R8_SNORM => f(F::R8Snorm, Channels::Same),
        RG8 => f(F::Rg8Unorm, Channels::Same),
        RG8_SNORM => f(F::Rg8Snorm, Channels::Same),
        RGB8 => f(F::Rgba8Unorm, Channels::Rgb),
        RGB8_SNORM => f(F::Rgba8Snorm, Channels::Rgb),
        RGB565 => f(F::Rgba8Unorm, Channels::Rgb),
        RGBA4 | RGB5_A1 | RGBA8 => f(F::Rgba8Unorm, Channels::Same),
        RGBA8_SNORM => f(F::Rgba8Snorm, Channels::Same),
        RGB10_A2 => f(F::Rgb10a2Unorm, Channels::Same),
        RGB10_A2UI => f(F::Rgb10a2Uint, Channels::Same),
        SRGB8 => f(F::Rgba8UnormSrgb, Channels::Rgb),
        SRGB8_ALPHA8 => f(F::Rgba8UnormSrgb, Channels::Same),
        R16F => f(F::R16Float, Channels::Same),
        RG16F => f(F::Rg16Float, Channels::Same),
        RGB16F => f(F::Rgba16Float, Channels::Rgb),
        RGBA16F => f(F::Rgba16Float, Channels::Same),
        R32F => f(F::R32Float, Channels::Same),
        RG32F => f(F::Rg32Float, Channels::Same),
        RGB32F => f(F::Rgba32Float, Channels::Rgb),
        RGBA32F => f(F::Rgba32Float, Channels::Same),
        R11F_G11F_B10F => f(F::Rg11b10Ufloat, Channels::Same),
        RGB9_E5 => f(F::Rgb9e5Ufloat, Channels::Same),
        R8I => f(F::R8Sint, Channels::Same),
        R8UI => f(F::R8Uint, Channels::Same),
        R16I => f(F::R16Sint, Channels::Same),
        R16UI => f(F::R16Uint, Channels::Same),
        R32I => f(F::R32Sint, Channels::Same),
        R32UI => f(F::R32Uint, Channels::Same),
        RG8I => f(F::Rg8Sint, Channels::Same),
        RG8UI => f(F::Rg8Uint, Channels::Same),
        RG16I => f(F::Rg16Sint, Channels::Same),
        RG16UI => f(F::Rg16Uint, Channels::Same),
        RG32I => f(F::Rg32Sint, Channels::Same),
        RG32UI => f(F::Rg32Uint, Channels::Same),
        RGBA8I => f(F::Rgba8Sint, Channels::Same),
        RGBA8UI => f(F::Rgba8Uint, Channels::Same),
        RGBA16I => f(F::Rgba16Sint, Channels::Same),
        RGBA16UI => f(F::Rgba16Uint, Channels::Same),
        RGBA32I => f(F::Rgba32Sint, Channels::Same),
        RGBA32UI => f(F::Rgba32Uint, Channels::Same),
        RGB8I => f(F::Rgba8Sint, Channels::Rgb),
        RGB8UI => f(F::Rgba8Uint, Channels::Rgb),
        RGB16I => f(F::Rgba16Sint, Channels::Rgb),
        RGB16UI => f(F::Rgba16Uint, Channels::Rgb),
        RGB32I => f(F::Rgba32Sint, Channels::Rgb),
        RGB32UI => f(F::Rgba32Uint, Channels::Rgb),
        DEPTH_COMPONENT16 => f(F::Depth16Unorm, Channels::Same),
        DEPTH_COMPONENT24 => f(F::Depth24Plus, Channels::Same),
        DEPTH_COMPONENT32F => f(F::Depth32Float, Channels::Same),
        DEPTH24_STENCIL8 => f(F::Depth24PlusStencil8, Channels::Same),
        DEPTH32F_STENCIL8 => f(F::Depth32FloatStencil8, Channels::Same),
        STENCIL_INDEX8 => f(F::Stencil8, Channels::Same),
        _ => None,
    }
}

/// A renderbuffer's format. (`DEPTH_STENCIL` is WebGL's name for depth 24 stencil 8.)
pub fn renderbuffer_format(internal: u32, webgl2: bool) -> Option<Fmt> {
    match internal {
        DEPTH_STENCIL => Some(Fmt { wgpu: F::Depth24PlusStencil8, internal, channels: Channels::Same }),
        RGBA4 | RGB565 | RGB5_A1 | DEPTH_COMPONENT16 | STENCIL_INDEX8 => sized_format(internal),
        SRGB8_ALPHA8 => sized_format(internal),
        _ if webgl2 => sized_format(internal).filter(|f| !matches!(f.channels, Channels::Rgb) || internal == RGB8),
        RGBA32F | RGBA16F => sized_format(internal),
        _ => None,
    }
}

fn type_fits(internal: u32, ty: u32) -> bool {
    match internal {
        R8 | RG8 | RGB8 | RGBA8 | SRGB8 | SRGB8_ALPHA8 | R8UI | RG8UI | RGB8UI | RGBA8UI => ty == UNSIGNED_BYTE,
        R8_SNORM | RG8_SNORM | RGB8_SNORM | RGBA8_SNORM | R8I | RG8I | RGB8I | RGBA8I => ty == BYTE,
        RGB565 => ty == UNSIGNED_BYTE || ty == UNSIGNED_SHORT_5_6_5,
        RGBA4 => ty == UNSIGNED_BYTE || ty == UNSIGNED_SHORT_4_4_4_4,
        RGB5_A1 => ty == UNSIGNED_BYTE || ty == UNSIGNED_SHORT_5_5_5_1 || ty == UNSIGNED_INT_2_10_10_10_REV,
        RGB10_A2 | RGB10_A2UI => ty == UNSIGNED_INT_2_10_10_10_REV,
        R16F | RG16F | RGB16F | RGBA16F => ty == HALF_FLOAT || ty == FLOAT || ty == HALF_FLOAT_OES,
        R32F | RG32F | RGB32F | RGBA32F => ty == FLOAT,
        R11F_G11F_B10F => ty == UNSIGNED_INT_10F_11F_11F_REV || ty == HALF_FLOAT || ty == FLOAT,
        RGB9_E5 => ty == UNSIGNED_INT_5_9_9_9_REV || ty == HALF_FLOAT || ty == FLOAT,
        R16UI | RG16UI | RGB16UI | RGBA16UI => ty == UNSIGNED_SHORT,
        R16I | RG16I | RGB16I | RGBA16I => ty == SHORT,
        R32UI | RG32UI | RGB32UI | RGBA32UI => ty == UNSIGNED_INT,
        R32I | RG32I | RGB32I | RGBA32I => ty == INT,
        DEPTH_COMPONENT16 => ty == UNSIGNED_SHORT || ty == UNSIGNED_INT,
        DEPTH_COMPONENT24 => ty == UNSIGNED_INT,
        DEPTH_COMPONENT32F => ty == FLOAT,
        DEPTH24_STENCIL8 => ty == UNSIGNED_INT_24_8,
        DEPTH32F_STENCIL8 => ty == FLOAT_32_UNSIGNED_INT_24_8_REV,
        _ => false,
    }
}

/// Number of components of a pixel format.
pub fn format_components(format: u32) -> Option<u32> {
    Some(match format {
        RED | RED_INTEGER | ALPHA | LUMINANCE | DEPTH_COMPONENT | DEPTH_STENCIL => 1,
        RG | RG_INTEGER | LUMINANCE_ALPHA => 2,
        RGB | RGB_INTEGER | SRGB_EXT => 3,
        RGBA | RGBA_INTEGER | SRGB_ALPHA_EXT => 4,
        _ => return None,
    })
}

/// Bytes per pixel of (format, type).
pub fn bytes_per_pixel(format: u32, ty: u32) -> Option<u32> {
    let c = format_components(format)?;
    Some(match ty {
        BYTE | UNSIGNED_BYTE => c,
        SHORT | UNSIGNED_SHORT | HALF_FLOAT | HALF_FLOAT_OES => c * 2,
        INT | UNSIGNED_INT | FLOAT => c * 4,
        UNSIGNED_SHORT_4_4_4_4 | UNSIGNED_SHORT_5_5_5_1 | UNSIGNED_SHORT_5_6_5 => 2,
        UNSIGNED_INT_2_10_10_10_REV | UNSIGNED_INT_10F_11F_11F_REV | UNSIGNED_INT_5_9_9_9_REV | UNSIGNED_INT_24_8 => 4,
        FLOAT_32_UNSIGNED_INT_24_8_REV => 8,
        _ => return None,
    })
}

/// How pixels are laid out in what a page gives (the UNPACK_ parameters).
#[derive(Clone, Copy, Debug)]
pub struct Unpack {
    pub alignment: u32,
    pub row_length: u32,
    pub image_height: u32,
    pub skip_rows: u32,
    pub skip_pixels: u32,
    pub skip_images: u32,
    pub flip_y: bool,
    pub premultiply: bool,
}

impl Default for Unpack {
    fn default() -> Self {
        Unpack { alignment: 4, row_length: 0, image_height: 0, skip_rows: 0, skip_pixels: 0, skip_images: 0, flip_y: false, premultiply: false }
    }
}

/// Bytes between rows, between images and the first byte used, for an upload of w x h x d; the total size needed. None on overflow.
pub fn layout(u: &Unpack, bpp: u32, w: u32, h: u32, d: u32) -> Option<(usize, usize, usize, usize)> {
    let row_px = if u.row_length > 0 { u.row_length } else { w } as usize;
    let a = u.alignment.max(1) as usize;
    let row = row_px.checked_mul(bpp as usize)?;
    let stride = row.checked_add(a - 1)? / a * a;
    let img_h = if u.image_height > 0 { u.image_height } else { h } as usize;
    let image = stride.checked_mul(img_h)?;
    let first = image.checked_mul(u.skip_images as usize)?.checked_add(stride.checked_mul(u.skip_rows as usize)?)?.checked_add((u.skip_pixels as usize).checked_mul(bpp as usize)?)?;
    if w == 0 || h == 0 || d == 0 {
        return Some((stride, image, first, first));
    }
    let last_row = (w as usize).checked_mul(bpp as usize)?;
    let end = first.checked_add(image.checked_mul(d as usize - 1)?)?.checked_add(stride.checked_mul(h as usize - 1)?)?.checked_add(last_row)?;
    Some((stride, image, first, end))
}

/// f16 from f32 (IEEE 754 binary16), rounding to nearest.
pub fn f16_from_f32(v: f32) -> u16 {
    let x = v.to_bits();
    let sign = ((x >> 16) & 0x8000) as u16;
    let exp = ((x >> 23) & 0xff) as i32 - 127 + 15;
    let frac = x & 0x7f_ffff;
    if (x & 0x7fff_ffff) > 0x7f80_0000 {
        return sign | 0x7e00; // NaN
    }
    if exp >= 31 {
        return sign | 0x7c00; // too large: infinity
    }
    if exp <= 0 {
        if exp < -10 {
            return sign;
        }
        let m = frac | 0x80_0000;
        let shift = (14 - exp) as u32;
        return sign | ((m + (1 << (shift - 1))) >> shift) as u16;
    }
    let r = (exp as u32) << 10 | (frac >> 13);
    let round = (frac >> 12) & 1;
    sign | (r + round) as u16
}

/// f32 from f16.
pub fn f32_from_f16(v: u16) -> f32 {
    let s = ((v as u32) & 0x8000) << 16;
    let e = ((v >> 10) & 0x1f) as u32;
    let f = (v & 0x3ff) as u32;
    let bits = match e {
        0 => {
            if f == 0 {
                s
            } else {
                let mut m = f;
                let mut ex = 127 - 15 + 1;
                while m & 0x400 == 0 {
                    m <<= 1;
                    ex -= 1;
                }
                s | ((ex as u32) << 23) | ((m & 0x3ff) << 13)
            }
        }
        31 => s | 0x7f80_0000 | (f << 13),
        _ => s | ((e + 127 - 15) << 23) | (f << 13),
    };
    f32::from_bits(bits)
}

/// Bytes per texel of a wgpu format that can be uploaded; None for depth formats that cannot.
pub fn texel_bytes(f: F) -> Option<u32> {
    f.block_copy_size(None)
}

/// Reads one pixel of (format, type) into RGBA as f32 (the alpha that a format lacks is 1, as GL says), or as raw integers
/// converted to f32 for integer formats.
fn read_pixel(src: &[u8], format: u32, ty: u32) -> [f32; 4] {
    let rd16 = |i: usize| u16::from_ne_bytes([src[i * 2], src[i * 2 + 1]]);
    let rd32 = |i: usize| u32::from_ne_bytes([src[i * 4], src[i * 4 + 1], src[i * 4 + 2], src[i * 4 + 3]]);
    let n = format_components(format).unwrap_or(4) as usize;
    let integer = matches!(format, RED_INTEGER | RG_INTEGER | RGB_INTEGER | RGBA_INTEGER);
    let mut c = [0.0f32, 0.0, 0.0, 1.0];
    match ty {
        UNSIGNED_BYTE => {
            for i in 0..n {
                c[i] = if integer { src[i] as f32 } else { src[i] as f32 / 255.0 };
            }
        }
        BYTE => {
            for i in 0..n {
                let v = src[i] as i8;
                c[i] = if integer { v as f32 } else { (v as f32 / 127.0).max(-1.0) };
            }
        }
        UNSIGNED_SHORT => {
            for i in 0..n {
                c[i] = rd16(i) as f32;
            }
        }
        SHORT => {
            for i in 0..n {
                c[i] = rd16(i) as i16 as f32;
            }
        }
        UNSIGNED_INT => {
            for i in 0..n {
                c[i] = rd32(i) as f32;
            }
        }
        INT => {
            for i in 0..n {
                c[i] = rd32(i) as i32 as f32;
            }
        }
        FLOAT => {
            for i in 0..n {
                c[i] = f32::from_bits(rd32(i));
            }
        }
        HALF_FLOAT | HALF_FLOAT_OES => {
            for i in 0..n {
                c[i] = f32_from_f16(rd16(i));
            }
        }
        UNSIGNED_SHORT_5_6_5 => {
            let v = rd16(0);
            c = [((v >> 11) & 31) as f32 / 31.0, ((v >> 5) & 63) as f32 / 63.0, (v & 31) as f32 / 31.0, 1.0];
        }
        UNSIGNED_SHORT_4_4_4_4 => {
            let v = rd16(0);
            c = [((v >> 12) & 15) as f32 / 15.0, ((v >> 8) & 15) as f32 / 15.0, ((v >> 4) & 15) as f32 / 15.0, (v & 15) as f32 / 15.0];
        }
        UNSIGNED_SHORT_5_5_5_1 => {
            let v = rd16(0);
            c = [((v >> 11) & 31) as f32 / 31.0, ((v >> 6) & 31) as f32 / 31.0, ((v >> 1) & 31) as f32 / 31.0, (v & 1) as f32];
        }
        UNSIGNED_INT_2_10_10_10_REV => {
            let v = rd32(0);
            c = [(v & 1023) as f32 / 1023.0, ((v >> 10) & 1023) as f32 / 1023.0, ((v >> 20) & 1023) as f32 / 1023.0, (v >> 30) as f32 / 3.0];
        }
        _ => {}
    }
    // luminance and alpha travel as RGBA
    match format {
        LUMINANCE => [c[0], c[0], c[0], 1.0],
        LUMINANCE_ALPHA => [c[0], c[0], c[0], c[1]],
        ALPHA => [0.0, 0.0, 0.0, c[0]],
        _ => c,
    }
}

fn clamp01(v: f32) -> f32 {
    if v < 0.0 {
        0.0
    } else if v > 1.0 {
        1.0
    } else {
        v
    }
}

/// Writes one pixel in a wgpu format. False: a format this path does not write.
fn write_pixel(dst: &mut [u8], f: F, c: [f32; 4]) -> bool {
    let u8n = |v: f32| (clamp01(v) * 255.0 + 0.5) as u8;
    let i8n = |v: f32| (v.max(-1.0).min(1.0) * 127.0).round() as i8 as u8;
    match f {
        F::Rgba8Unorm | F::Rgba8UnormSrgb => {
            dst[0] = u8n(c[0]);
            dst[1] = u8n(c[1]);
            dst[2] = u8n(c[2]);
            dst[3] = u8n(c[3]);
        }
        F::Rgba8Snorm => {
            for i in 0..4 {
                dst[i] = i8n(c[i]);
            }
        }
        F::R8Unorm => dst[0] = u8n(c[0]),
        F::R8Snorm => dst[0] = i8n(c[0]),
        F::Rg8Unorm => {
            dst[0] = u8n(c[0]);
            dst[1] = u8n(c[1]);
        }
        F::Rg8Snorm => {
            dst[0] = i8n(c[0]);
            dst[1] = i8n(c[1]);
        }
        F::R16Float | F::Rg16Float | F::Rgba16Float => {
            let n = match f {
                F::R16Float => 1,
                F::Rg16Float => 2,
                _ => 4,
            };
            for i in 0..n {
                dst[i * 2..i * 2 + 2].copy_from_slice(&f16_from_f32(c[i]).to_ne_bytes());
            }
        }
        F::R32Float | F::Rg32Float | F::Rgba32Float => {
            let n = match f {
                F::R32Float => 1,
                F::Rg32Float => 2,
                _ => 4,
            };
            for i in 0..n {
                dst[i * 4..i * 4 + 4].copy_from_slice(&c[i].to_ne_bytes());
            }
        }
        F::Rgb10a2Unorm => {
            let v = (clamp01(c[0]) * 1023.0 + 0.5) as u32 | ((clamp01(c[1]) * 1023.0 + 0.5) as u32) << 10 | ((clamp01(c[2]) * 1023.0 + 0.5) as u32) << 20 | ((clamp01(c[3]) * 3.0 + 0.5) as u32) << 30;
            dst[..4].copy_from_slice(&v.to_ne_bytes());
        }
        F::R8Uint | F::R8Sint => dst[0] = c[0] as i32 as u8,
        F::Rg8Uint | F::Rg8Sint => {
            for i in 0..2 {
                dst[i] = c[i] as i32 as u8;
            }
        }
        F::Rgba8Uint | F::Rgba8Sint => {
            for i in 0..4 {
                dst[i] = c[i] as i32 as u8;
            }
        }
        F::R16Uint | F::R16Sint => dst[..2].copy_from_slice(&(c[0] as i32 as u16).to_ne_bytes()),
        F::Rg16Uint | F::Rg16Sint => {
            for i in 0..2 {
                dst[i * 2..i * 2 + 2].copy_from_slice(&(c[i] as i32 as u16).to_ne_bytes());
            }
        }
        F::Rgba16Uint | F::Rgba16Sint => {
            for i in 0..4 {
                dst[i * 2..i * 2 + 2].copy_from_slice(&(c[i] as i32 as u16).to_ne_bytes());
            }
        }
        F::R32Uint | F::R32Sint => dst[..4].copy_from_slice(&(c[0] as i64 as u32).to_ne_bytes()),
        F::Rg32Uint | F::Rg32Sint => {
            for i in 0..2 {
                dst[i * 4..i * 4 + 4].copy_from_slice(&(c[i] as i64 as u32).to_ne_bytes());
            }
        }
        F::Rgba32Uint | F::Rgba32Sint => {
            for i in 0..4 {
                dst[i * 4..i * 4 + 4].copy_from_slice(&(c[i] as i64 as u32).to_ne_bytes());
            }
        }
        _ => return false,
    }
    true
}

/// Pixels as the texture wants them, tightly packed, rows in the order GL gives them (or flipped with UNPACK_FLIP_Y_WEBGL).
/// `src` holds at least what `layout` says (checked by the caller). None: this format cannot be uploaded this way.
#[allow(clippy::too_many_arguments)]
pub fn convert_upload(src: &[u8], u: &Unpack, format: u32, ty: u32, fmt: Fmt, w: u32, h: u32, d: u32) -> Option<Vec<u8>> {
    let bpp = bytes_per_pixel(format, ty)? as usize;
    let (stride, image, first, _) = layout(u, bpp as u32, w, h, d)?;
    let out_bpp = texel_bytes(fmt.wgpu)? as usize;
    let (w_, h_, d_) = (w as usize, h as usize, d as usize);
    let out_row = out_bpp * w_;
    let mut out = vec![0u8; out_row.checked_mul(h_)?.checked_mul(d_)?];
    // a direct copy when the bytes are the same; otherwise, pixel by pixel
    let direct = fmt.channels == Channels::Same && bpp == out_bpp && !u.premultiply && matches!(
        (fmt.wgpu, ty),
        (F::Rgba8Unorm | F::Rgba8UnormSrgb | F::Rgba8Uint | F::R8Unorm | F::Rg8Unorm | F::R8Uint | F::Rg8Uint, UNSIGNED_BYTE)
            | (F::Rgba8Snorm | F::Rgba8Sint | F::R8Snorm | F::Rg8Snorm | F::R8Sint | F::Rg8Sint, BYTE)
            | (F::R16Float | F::Rg16Float | F::Rgba16Float, HALF_FLOAT | HALF_FLOAT_OES)
            | (F::R32Float | F::Rg32Float | F::Rgba32Float, FLOAT)
            | (F::R16Uint | F::Rg16Uint | F::Rgba16Uint, UNSIGNED_SHORT)
            | (F::R16Sint | F::Rg16Sint | F::Rgba16Sint, SHORT)
            | (F::R32Uint | F::Rg32Uint | F::Rgba32Uint, UNSIGNED_INT)
            | (F::R32Sint | F::Rg32Sint | F::Rgba32Sint, INT)
            | (F::Rgb10a2Unorm | F::Rgb10a2Uint | F::Rg11b10Ufloat, UNSIGNED_INT_2_10_10_10_REV | UNSIGNED_INT_10F_11F_11F_REV)
            | (F::Rgb9e5Ufloat, UNSIGNED_INT_5_9_9_9_REV)
    );
    let fast_rgb8 = matches!(fmt.wgpu, F::Rgba8Unorm | F::Rgba8UnormSrgb) && ty == UNSIGNED_BYTE && !u.premultiply;
    let rgb_alpha_one = fmt.channels == Channels::Rgb;
    for z in 0..d_ {
        for y in 0..h_ {
            let oy = if u.flip_y { h_ - 1 - y } else { y };
            let from = first + z * image + y * stride;
            let to = (z * h_ + oy) * out_row;
            let line = &src[from..from + w_ * bpp];
            let dst = &mut out[to..to + out_row];
            if direct {
                dst.copy_from_slice(line);
            } else if fast_rgb8 && format == RGB {
                for (s, t) in line.chunks_exact(3).zip(dst.chunks_exact_mut(4)) {
                    t[0] = s[0];
                    t[1] = s[1];
                    t[2] = s[2];
                    t[3] = 255;
                }
            } else if fast_rgb8 && format == LUMINANCE {
                for (s, t) in line.iter().zip(dst.chunks_exact_mut(4)) {
                    t[0] = *s;
                    t[1] = *s;
                    t[2] = *s;
                    t[3] = 255;
                }
            } else if fast_rgb8 && format == ALPHA {
                for (s, t) in line.iter().zip(dst.chunks_exact_mut(4)) {
                    t[3] = *s;
                }
            } else if fast_rgb8 && format == LUMINANCE_ALPHA {
                for (s, t) in line.chunks_exact(2).zip(dst.chunks_exact_mut(4)) {
                    t[0] = s[0];
                    t[1] = s[0];
                    t[2] = s[0];
                    t[3] = s[1];
                }
            } else {
                for (s, t) in line.chunks_exact(bpp).zip(dst.chunks_exact_mut(out_bpp)) {
                    let mut c = read_pixel(s, format, ty);
                    if rgb_alpha_one {
                        c[3] = 1.0;
                    }
                    if u.premultiply {
                        c[0] *= c[3];
                        c[1] *= c[3];
                        c[2] *= c[3];
                    }
                    if !write_pixel(t, fmt.wgpu, c) {
                        return None;
                    }
                }
            }
        }
    }
    Some(out)
}

/// Pixels of an image (straight or premultiplied RGBA8, rows from the top) as the texture wants them, for texImage2D of an
/// element. `(format, ty)` say what the page asked; a source of a different alpha convention is converted as UNPACK_ says.
#[allow(clippy::too_many_arguments)]
pub fn convert_image(src: &[u8], src_premultiplied: bool, u: &Unpack, format: u32, fmt: Fmt, w: u32, h: u32) -> Option<Vec<u8>> {
    let mut tmp;
    let straight = if src_premultiplied && !u.premultiply {
        tmp = src.to_vec();
        for p in tmp.chunks_exact_mut(4) {
            let a = p[3] as u32;
            if a > 0 && a < 255 {
                p[0] = ((p[0] as u32 * 255 + a / 2) / a).min(255) as u8;
                p[1] = ((p[1] as u32 * 255 + a / 2) / a).min(255) as u8;
                p[2] = ((p[2] as u32 * 255 + a / 2) / a).min(255) as u8;
            }
        }
        &tmp[..]
    } else {
        src
    };
    let already = src_premultiplied && u.premultiply;
    let unpack = Unpack { alignment: 1, row_length: 0, image_height: 0, skip_rows: 0, skip_pixels: 0, skip_images: 0, flip_y: u.flip_y, premultiply: u.premultiply && !already };
    let out_bpp = texel_bytes(fmt.wgpu)? as usize;
    let (w_, h_) = (w as usize, h as usize);
    let out_row = out_bpp * w_;
    let mut out = vec![0u8; out_row.checked_mul(h_)?];
    if src.len() < w_ * h_ * 4 {
        return None;
    }
    let direct = fmt.channels == Channels::Same && matches!(fmt.wgpu, F::Rgba8Unorm | F::Rgba8UnormSrgb) && !unpack.premultiply && format == RGBA;
    for y in 0..h_ {
        let oy = if u.flip_y { h_ - 1 - y } else { y };
        let line = &straight[y * w_ * 4..(y + 1) * w_ * 4];
        let dst = &mut out[oy * out_row..(oy + 1) * out_row];
        if direct {
            dst.copy_from_slice(line);
            continue;
        }
        for (s, t) in line.chunks_exact(4).zip(dst.chunks_exact_mut(out_bpp)) {
            let mut c = [s[0] as f32 / 255.0, s[1] as f32 / 255.0, s[2] as f32 / 255.0, s[3] as f32 / 255.0];
            if unpack.premultiply {
                c[0] *= c[3];
                c[1] *= c[3];
                c[2] *= c[3];
            }
            match fmt.channels {
                Channels::Rgb => c[3] = 1.0,
                Channels::Luminance => c = [c[0], c[0], c[0], 1.0],
                Channels::LuminanceAlpha => c = [c[0], c[0], c[0], c[3]],
                Channels::Alpha => c = [0.0, 0.0, 0.0, c[3]],
                Channels::Same => {}
            }
            if !write_pixel(t, fmt.wgpu, c) {
                return None;
            }
        }
    }
    Some(out)
}

/// Texels of a framebuffer (a wgpu format, tightly packed) as readPixels gives them. `(format, ty)` were checked.
#[allow(clippy::too_many_arguments)]
pub fn convert_readback(src: &[u8], src_bpr: usize, f: F, format: u32, ty: u32, w: usize, h: usize, stride: usize, out: &mut [u8]) -> bool {
    let Some(bpp) = texel_bytes(f) else { return false };
    let bpp = bpp as usize;
    let Some(obpp) = bytes_per_pixel(format, ty) else { return false };
    let obpp = obpp as usize;
    let direct = matches!((f, format, ty), (F::Rgba8Unorm | F::Rgba8UnormSrgb, RGBA, UNSIGNED_BYTE) | (F::Rgba32Float, RGBA, FLOAT) | (F::Rgba16Float, RGBA, HALF_FLOAT | HALF_FLOAT_OES) | (F::Rgba8Uint, RGBA_INTEGER, UNSIGNED_BYTE) | (F::Rgba8Sint, RGBA_INTEGER, BYTE) | (F::R8Unorm, RED, UNSIGNED_BYTE) | (F::Rg8Unorm, RG, UNSIGNED_BYTE) | (F::R32Float, RED, FLOAT) | (F::Rg32Float, RG, FLOAT) | (F::R32Uint, RED_INTEGER, UNSIGNED_INT) | (F::R32Sint, RED_INTEGER, INT) | (F::Rgba32Uint, RGBA_INTEGER, UNSIGNED_INT) | (F::Rgba32Sint, RGBA_INTEGER, INT));
    for y in 0..h {
        let from = y * src_bpr;
        let to = y * stride;
        if to + w * obpp > out.len() || from + w * bpp > src.len() {
            return false;
        }
        let line = &src[from..from + w * bpp];
        let dst = &mut out[to..to + w * obpp];
        if direct {
            dst.copy_from_slice(line);
            continue;
        }
        for (s, t) in line.chunks_exact(bpp).zip(dst.chunks_exact_mut(obpp)) {
            let c = read_texel(s, f);
            let n = format_components(format).unwrap_or(4) as usize;
            for i in 0..n {
                match ty {
                    UNSIGNED_BYTE => t[i] = (clamp01(c[i]) * 255.0 + 0.5) as u8,
                    FLOAT => t[i * 4..i * 4 + 4].copy_from_slice(&c[i].to_ne_bytes()),
                    HALF_FLOAT | HALF_FLOAT_OES => t[i * 2..i * 2 + 2].copy_from_slice(&f16_from_f32(c[i]).to_ne_bytes()),
                    UNSIGNED_SHORT => t[i * 2..i * 2 + 2].copy_from_slice(&(c[i] as u32 as u16).to_ne_bytes()),
                    SHORT => t[i * 2..i * 2 + 2].copy_from_slice(&(c[i] as i32 as u16).to_ne_bytes()),
                    INT | UNSIGNED_INT => t[i * 4..i * 4 + 4].copy_from_slice(&(c[i] as i64 as u32).to_ne_bytes()),
                    BYTE => t[i] = c[i] as i32 as u8,
                    _ => {}
                }
            }
        }
    }
    true
}

fn read_texel(s: &[u8], f: F) -> [f32; 4] {
    let rd16 = |i: usize| u16::from_ne_bytes([s[i * 2], s[i * 2 + 1]]);
    let rd32 = |i: usize| u32::from_ne_bytes([s[i * 4], s[i * 4 + 1], s[i * 4 + 2], s[i * 4 + 3]]);
    match f {
        F::Rgba8Unorm | F::Rgba8UnormSrgb => [s[0] as f32 / 255.0, s[1] as f32 / 255.0, s[2] as f32 / 255.0, s[3] as f32 / 255.0],
        F::R8Unorm => [s[0] as f32 / 255.0, 0.0, 0.0, 1.0],
        F::Rg8Unorm => [s[0] as f32 / 255.0, s[1] as f32 / 255.0, 0.0, 1.0],
        F::R16Float => [f32_from_f16(rd16(0)), 0.0, 0.0, 1.0],
        F::Rg16Float => [f32_from_f16(rd16(0)), f32_from_f16(rd16(1)), 0.0, 1.0],
        F::Rgba16Float => [f32_from_f16(rd16(0)), f32_from_f16(rd16(1)), f32_from_f16(rd16(2)), f32_from_f16(rd16(3))],
        F::R32Float => [f32::from_bits(rd32(0)), 0.0, 0.0, 1.0],
        F::Rg32Float => [f32::from_bits(rd32(0)), f32::from_bits(rd32(1)), 0.0, 1.0],
        F::Rgba32Float => [f32::from_bits(rd32(0)), f32::from_bits(rd32(1)), f32::from_bits(rd32(2)), f32::from_bits(rd32(3))],
        F::Rgb10a2Unorm => {
            let v = rd32(0);
            [(v & 1023) as f32 / 1023.0, ((v >> 10) & 1023) as f32 / 1023.0, ((v >> 20) & 1023) as f32 / 1023.0, (v >> 30) as f32 / 3.0]
        }
        F::R8Uint | F::Rg8Uint | F::Rgba8Uint => [s[0] as f32, *s.get(1).unwrap_or(&0) as f32, *s.get(2).unwrap_or(&0) as f32, *s.get(3).unwrap_or(&0) as f32],
        F::R32Uint => [rd32(0) as f32, 0.0, 0.0, 1.0],
        F::R32Sint => [rd32(0) as i32 as f32, 0.0, 0.0, 1.0],
        _ => [0.0, 0.0, 0.0, 1.0],
    }
}

/// The format readPixels should be offered for a framebuffer's format: (format, type).
pub fn implementation_read(f: F) -> (u32, u32) {
    match sample_kind(f) {
        SampleKind::Sint => (RGBA_INTEGER, INT),
        SampleKind::Uint => (RGBA_INTEGER, UNSIGNED_INT),
        _ => match f {
            F::Rgba16Float | F::R16Float | F::Rg16Float | F::Rgba32Float | F::R32Float | F::Rg32Float | F::Rg11b10Ufloat => (RGBA, FLOAT),
            _ => (RGBA, UNSIGNED_BYTE),
        },
    }
}

/// Bits of each channel of a format: red, green, blue, alpha, depth, stencil.
pub fn bits(f: F) -> [u32; 6] {
    match f {
        F::Rgba8Unorm | F::Rgba8UnormSrgb | F::Rgba8Snorm | F::Rgba8Uint | F::Rgba8Sint => [8, 8, 8, 8, 0, 0],
        F::R8Unorm | F::R8Snorm | F::R8Uint | F::R8Sint => [8, 0, 0, 0, 0, 0],
        F::Rg8Unorm | F::Rg8Snorm | F::Rg8Uint | F::Rg8Sint => [8, 8, 0, 0, 0, 0],
        F::Rgba16Float | F::Rgba16Uint | F::Rgba16Sint => [16, 16, 16, 16, 0, 0],
        F::R16Float | F::R16Uint | F::R16Sint => [16, 0, 0, 0, 0, 0],
        F::Rg16Float | F::Rg16Uint | F::Rg16Sint => [16, 16, 0, 0, 0, 0],
        F::Rgba32Float | F::Rgba32Uint | F::Rgba32Sint => [32, 32, 32, 32, 0, 0],
        F::R32Float | F::R32Uint | F::R32Sint => [32, 0, 0, 0, 0, 0],
        F::Rg32Float | F::Rg32Uint | F::Rg32Sint => [32, 32, 0, 0, 0, 0],
        F::Rgb10a2Unorm | F::Rgb10a2Uint => [10, 10, 10, 2, 0, 0],
        F::Rg11b10Ufloat => [11, 11, 10, 0, 0, 0],
        F::Depth16Unorm => [0, 0, 0, 0, 16, 0],
        F::Depth24Plus => [0, 0, 0, 0, 24, 0],
        F::Depth24PlusStencil8 => [0, 0, 0, 0, 24, 8],
        F::Depth32Float => [0, 0, 0, 0, 32, 0],
        F::Depth32FloatStencil8 => [0, 0, 0, 0, 32, 8],
        F::Stencil8 => [0, 0, 0, 0, 0, 8],
        _ => [0; 6],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn half_floats_round_trip() {
        for v in [0.0f32, 1.0, -1.0, 0.5, 1.5, 1024.0, 1e-5] {
            let h = f16_from_f32(v);
            let b = f32_from_f16(h);
            assert!((b - v).abs() <= v.abs() * 0.01 + 1e-6, "{v} -> {b}");
        }
        assert_eq!(f16_from_f32(1e9), 0x7c00);
    }

    #[test]
    fn layout_counts_alignment() {
        let u = Unpack::default();
        // 3 x 2 of RGB at alignment 4: rows of 12 bytes (9 rounded), the last one 9
        let (stride, _, first, end) = layout(&u, 3, 3, 2, 1).unwrap();
        assert_eq!((stride, first, end), (12, 0, 21));
    }

    #[test]
    fn rgb_gets_an_opaque_alpha_and_flips() {
        let fmt = texture_format(RGB, RGB, UNSIGNED_BYTE, false).unwrap();
        let u = Unpack { alignment: 1, flip_y: true, ..Unpack::default() };
        let px = convert_upload(&[1, 2, 3, 4, 5, 6], &u, RGB, UNSIGNED_BYTE, fmt, 1, 2, 1).unwrap();
        assert_eq!(px, [4, 5, 6, 255, 1, 2, 3, 255]);
    }

    #[test]
    fn invalid_combinations_are_refused() {
        assert!(texture_format(RGBA, RGB, UNSIGNED_BYTE, false).is_none());
        assert!(texture_format(RGB, RGB, UNSIGNED_SHORT_4_4_4_4, false).is_none());
        assert!(texture_format(0x8058, RGBA, UNSIGNED_BYTE, false).is_none());
        assert!(texture_format(0x8058, RGBA, UNSIGNED_BYTE, true).is_some());
        assert!(texture_format(0x8058, RGBA, FLOAT, true).is_none());
    }
}
