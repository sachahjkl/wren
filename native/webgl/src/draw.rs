//! Drawing: render passes, the cache of pipelines, vertex streams, clears, blits, mipmaps. See gl.rs.

use crate::formats::{self, Fmt, SampleKind};
use crate::gl::*;
use crate::translate;
use std::borrow::Cow;
use std::collections::HashMap;

/// A vertex attribute of a slot: (format, offset in the slot, location).
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub struct SlotLayout {
    pub stride: u32,
    pub instance: bool,
    pub attrs: Vec<(wgpu::VertexFormat, u32, u32)>,
}

/// All that makes a pipeline (with the program it is cached in).
#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub struct PipelineKey {
    pub points: bool,
    pub topology: wgpu::PrimitiveTopology,
    pub strip_index: Option<wgpu::IndexFormat>,
    pub blend: Option<[u32; 6]>,
    pub color_mask: [bool; 4],
    pub depth: Option<(bool, u32)>,
    pub stencil: Option<[u32; 10]>,
    pub cull: u32,
    pub front: u32,
    pub offset: Option<(u32, u32)>,
    pub alpha_to_coverage: bool,
    pub samples: u32,
    pub colors: Vec<Option<wgpu::TextureFormat>>,
    pub ds: Option<wgpu::TextureFormat>,
    pub slots: Vec<SlotLayout>,
    pub binds: Vec<BindKind>,
}

/// What the open pass has been told already.
#[derive(Default)]
pub struct PassState {
    pub viewport: Option<[i32; 4]>,
    pub depth_range: [u32; 2],
    pub scissor: Option<[u32; 4]>,
    pub blend_constant: Option<[u32; 4]>,
    pub stencil_ref: Option<u32>,
}

/// A clear done when a pass starts.
#[derive(Clone, Copy, Default)]
pub struct PassClear {
    pub color: Option<wgpu::Color>,
    /// For one attachment only (clearBuffer): its index.
    pub only: Option<usize>,
    pub depth: Option<f32>,
    pub stencil: Option<u32>,
}

/// The attachments of a draw framebuffer, resolved.
#[derive(Clone)]
pub struct Target {
    pub colors: Vec<Option<(wgpu::TextureView, Option<wgpu::TextureView>, wgpu::TextureFormat)>>,
    pub ds: Option<(wgpu::TextureView, wgpu::TextureFormat)>,
    pub w: u32,
    pub h: u32,
    pub samples: u32,
}

const QUAD_VS: &str = "#version 450 core
layout(location = 0) out vec2 uv;
layout(std140, set = 0, binding = 0) uniform P { vec4 rect; vec4 clear_color; vec4 depth; };
void main() {
    vec2 p = vec2(float((gl_VertexIndex & 1) * 2), float((gl_VertexIndex >> 1) * 2));
    gl_Position = vec4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, depth.x, 1.0);
    uv = rect.xy + p * rect.zw;
}";
const BLIT_FS: &str = "#version 450 core
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;
layout(set = 1, binding = 0) uniform texture2D src;
layout(set = 1, binding = 1) uniform sampler smp;
void main() { color = textureLod(sampler2D(src, smp), uv, 0.0); }";
const CLEAR_FS: &str = "#version 450 core
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color0;
layout(std140, set = 0, binding = 0) uniform P { vec4 rect; vec4 clear_color; vec4 depth; };
void main() { color0 = clear_color; }";

/// A pipeline that takes this long is told to the console.
const SLOW_PIPELINE: std::time::Duration = std::time::Duration::from_millis(1000);
/// Bytes of the parameters of the utility shaders.
const UTILITY_PARAMS: u64 = 48;

/// Shaders of the context itself: mipmaps, blits, clears with a mask.
pub struct Utility {
    pub vs: wgpu::ShaderModule,
    pub blit_fs: wgpu::ShaderModule,
    pub clear_fs: wgpu::ShaderModule,
    pub params: wgpu::BindGroupLayout,
    pub src: wgpu::BindGroupLayout,
    pub blit_layout: wgpu::PipelineLayout,
    pub clear_layout: wgpu::PipelineLayout,
    pub blit: HashMap<(wgpu::TextureFormat, u32), wgpu::RenderPipeline>,
    pub clear: HashMap<(Vec<(wgpu::TextureFormat, [bool; 4])>, Option<(wgpu::TextureFormat, bool, u32)>, u32), wgpu::RenderPipeline>,
    pub linear: wgpu::Sampler,
    pub nearest: wgpu::Sampler,
}

impl Utility {
    pub fn new(device: &wgpu::Device) -> Result<Utility, String> {
        let m = |stage, text: &str| -> Result<wgpu::ShaderModule, String> {
            let module = translate::parse_glsl(stage, text)?;
            shader_module(device, module).ok_or_else(|| "a shader of the context did not build".to_string())
        };
        let vs = m(translate::Stage::Vertex, QUAD_VS)?;
        let blit_fs = m(translate::Stage::Fragment, BLIT_FS)?;
        let clear_fs = m(translate::Stage::Fragment, CLEAR_FS)?;
        let params = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: true, min_binding_size: wgpu::BufferSize::new(UTILITY_PARAMS) },
                count: None,
            }],
        });
        let src = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[
                wgpu::BindGroupLayoutEntry { binding: 0, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: true }, view_dimension: wgpu::TextureViewDimension::D2, multisampled: false }, count: None },
                wgpu::BindGroupLayoutEntry { binding: 1, visibility: wgpu::ShaderStages::FRAGMENT, ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering), count: None },
            ],
        });
        let blit_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[Some(&params), Some(&src)], immediate_size: 0 });
        let clear_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &[Some(&params)], immediate_size: 0 });
        let sampler = |f: wgpu::FilterMode| device.create_sampler(&wgpu::SamplerDescriptor { mag_filter: f, min_filter: f, ..Default::default() });
        Ok(Utility { vs, blit_fs, clear_fs, params, src, blit_layout, clear_layout, blit: HashMap::new(), clear: HashMap::new(), linear: sampler(wgpu::FilterMode::Linear), nearest: sampler(wgpu::FilterMode::Nearest) })
    }
}

/// naga's module as a wgpu module. None: wgpu's validation refused it (this translator's fault, or a shader that passed naga's
/// front end but not its validator): the link fails.
pub fn shader_module(device: &wgpu::Device, module: naga::Module) -> Option<wgpu::ShaderModule> {
    let scope = device.push_error_scope(wgpu::ErrorFilter::Validation);
    let m = device.create_shader_module(wgpu::ShaderModuleDescriptor { label: None, source: wgpu::ShaderSource::Naga(Cow::Owned(module)) });
    match pollster::block_on(scope.pop()) {
        None => Some(m),
        Some(e) => {
            LAST_SHADER_ERROR.with(|s| *s.borrow_mut() = e.to_string());
            None
        }
    }
}

thread_local! {
    /// wgpu's words for the last module it refused (a program's log).
    pub static LAST_SHADER_ERROR: std::cell::RefCell<String> = const { std::cell::RefCell::new(String::new()) };
}

fn blend_factor(f: u32) -> wgpu::BlendFactor {
    use wgpu::BlendFactor as B;
    match f {
        0 => B::Zero,
        1 => B::One,
        0x300 => B::Src,
        0x301 => B::OneMinusSrc,
        0x302 => B::SrcAlpha,
        0x303 => B::OneMinusSrcAlpha,
        0x304 => B::DstAlpha,
        0x305 => B::OneMinusDstAlpha,
        0x306 => B::Dst,
        0x307 => B::OneMinusDst,
        0x308 => B::SrcAlphaSaturated,
        0x8001 | 0x8003 => B::Constant,
        _ => B::OneMinusConstant,
    }
}

fn blend_op(e: u32) -> wgpu::BlendOperation {
    match e {
        0x800A => wgpu::BlendOperation::Subtract,
        0x800B => wgpu::BlendOperation::ReverseSubtract,
        0x8007 => wgpu::BlendOperation::Min,
        0x8008 => wgpu::BlendOperation::Max,
        _ => wgpu::BlendOperation::Add,
    }
}

fn stencil_op(e: u32) -> wgpu::StencilOperation {
    use wgpu::StencilOperation as S;
    match e {
        0 => S::Zero,
        0x1E01 => S::Replace,
        0x1E02 => S::IncrementClamp,
        0x1E03 => S::DecrementClamp,
        0x150A => S::Invert,
        0x8507 => S::IncrementWrap,
        0x8508 => S::DecrementWrap,
        _ => S::Keep,
    }
}

/// The wgpu format of a vertex attribute as it is, or None when it must be converted first.
fn vertex_format(a: &Attr) -> Option<wgpu::VertexFormat> {
    use wgpu::VertexFormat as V;
    Some(match (a.ty, a.size, a.normalized, a.integer) {
        (formats::FLOAT, 1, ..) => V::Float32,
        (formats::FLOAT, 2, ..) => V::Float32x2,
        (formats::FLOAT, 3, ..) => V::Float32x3,
        (formats::FLOAT, 4, ..) => V::Float32x4,
        (formats::HALF_FLOAT | formats::HALF_FLOAT_OES, 2, ..) => V::Float16x2,
        (formats::HALF_FLOAT | formats::HALF_FLOAT_OES, 4, ..) => V::Float16x4,
        (formats::UNSIGNED_BYTE, 1, true, false) => V::Unorm8,
        (formats::UNSIGNED_BYTE, 2, true, false) => V::Unorm8x2,
        (formats::UNSIGNED_BYTE, 4, true, false) => V::Unorm8x4,
        (formats::BYTE, 1, true, false) => V::Snorm8,
        (formats::BYTE, 2, true, false) => V::Snorm8x2,
        (formats::BYTE, 4, true, false) => V::Snorm8x4,
        (formats::UNSIGNED_SHORT, 1, true, false) => V::Unorm16,
        (formats::UNSIGNED_SHORT, 2, true, false) => V::Unorm16x2,
        (formats::UNSIGNED_SHORT, 4, true, false) => V::Unorm16x4,
        (formats::SHORT, 1, true, false) => V::Snorm16,
        (formats::SHORT, 2, true, false) => V::Snorm16x2,
        (formats::SHORT, 4, true, false) => V::Snorm16x4,
        (formats::UNSIGNED_BYTE, 1, _, true) => V::Uint8,
        (formats::UNSIGNED_BYTE, 2, _, true) => V::Uint8x2,
        (formats::UNSIGNED_BYTE, 4, _, true) => V::Uint8x4,
        (formats::BYTE, 1, _, true) => V::Sint8,
        (formats::BYTE, 2, _, true) => V::Sint8x2,
        (formats::BYTE, 4, _, true) => V::Sint8x4,
        (formats::UNSIGNED_SHORT, 1, _, true) => V::Uint16,
        (formats::UNSIGNED_SHORT, 2, _, true) => V::Uint16x2,
        (formats::UNSIGNED_SHORT, 4, _, true) => V::Uint16x4,
        (formats::SHORT, 1, _, true) => V::Sint16,
        (formats::SHORT, 2, _, true) => V::Sint16x2,
        (formats::SHORT, 4, _, true) => V::Sint16x4,
        (formats::UNSIGNED_INT, 1, _, true) => V::Uint32,
        (formats::UNSIGNED_INT, 2, _, true) => V::Uint32x2,
        (formats::UNSIGNED_INT, 3, _, true) => V::Uint32x3,
        (formats::UNSIGNED_INT, 4, _, true) => V::Uint32x4,
        (formats::INT, 1, _, true) => V::Sint32,
        (formats::INT, 2, _, true) => V::Sint32x2,
        (formats::INT, 3, _, true) => V::Sint32x3,
        (formats::INT, 4, _, true) => V::Sint32x4,
        (formats::UNSIGNED_INT_2_10_10_10_REV, 4, true, false) => V::Unorm10_10_10_2,
        _ => return None,
    })
}

fn attr_bytes(a: &Attr) -> u32 {
    let ts = match a.ty {
        formats::BYTE | formats::UNSIGNED_BYTE => 1,
        formats::SHORT | formats::UNSIGNED_SHORT | formats::HALF_FLOAT | formats::HALF_FLOAT_OES => 2,
        0x8D9F | formats::UNSIGNED_INT_2_10_10_10_REV => return 4,
        _ => 4,
    };
    ts * a.size
}

/// Reads a component of a vertex as a number (for the conversion).
fn read_component(s: &[u8], ty: u32, normalized: bool) -> f64 {
    let g = |n: usize| -> &[u8] { &s[..n] };
    match ty {
        formats::BYTE => {
            let v = g(1)[0] as i8 as f64;
            if normalized { (v / 127.0).max(-1.0) } else { v }
        }
        formats::UNSIGNED_BYTE => {
            let v = g(1)[0] as f64;
            if normalized { v / 255.0 } else { v }
        }
        formats::SHORT => {
            let v = i16::from_ne_bytes([s[0], s[1]]) as f64;
            if normalized { (v / 32767.0).max(-1.0) } else { v }
        }
        formats::UNSIGNED_SHORT => {
            let v = u16::from_ne_bytes([s[0], s[1]]) as f64;
            if normalized { v / 65535.0 } else { v }
        }
        formats::INT => {
            let v = i32::from_ne_bytes([s[0], s[1], s[2], s[3]]) as f64;
            if normalized { (v / 2147483647.0).max(-1.0) } else { v }
        }
        formats::UNSIGNED_INT => {
            let v = u32::from_ne_bytes([s[0], s[1], s[2], s[3]]) as f64;
            if normalized { v / 4294967295.0 } else { v }
        }
        formats::HALF_FLOAT | formats::HALF_FLOAT_OES => formats::f32_from_f16(u16::from_ne_bytes([s[0], s[1]])) as f64,
        _ => f32::from_ne_bytes([s[0], s[1], s[2], s[3]]) as f64,
    }
}

/// Number of bytes of an index type; None when it is not one.
fn index_bytes(ty: u32, elem_uint: bool) -> Option<u32> {
    match ty {
        formats::UNSIGNED_BYTE => Some(1),
        formats::UNSIGNED_SHORT => Some(2),
        formats::UNSIGNED_INT if elem_uint => Some(4),
        _ => None,
    }
}

const POINTS: u32 = 0;
const LINES: u32 = 1;
const LINE_LOOP: u32 = 2;
const LINE_STRIP: u32 = 3;
const TRIANGLES: u32 = 4;
const TRIANGLE_STRIP: u32 = 5;
const TRIANGLE_FAN: u32 = 6;

impl Ctx {
    /// The attachments of a framebuffer; None: it is incomplete or there is nothing to draw on.
    pub fn target_of(&mut self, fb: u32) -> Option<Target> {
        if fb == 0 {
            let bb = &self.bb;
            let color = match &bb.msaa_view {
                Some(m) => (m.clone(), Some(bb.color_view.clone()), wgpu::TextureFormat::Rgba8Unorm),
                None => (bb.color_view.clone(), None, wgpu::TextureFormat::Rgba8Unorm),
            };
            let samples = if bb.msaa_view.is_some() { self.limits.max_samples } else { 1 };
            let ds = bb.depth_view.as_ref().map(|v| (v.clone(), bb.format_ds.unwrap()));
            return Some(Target { colors: vec![Some(color)], ds, w: bb.w, h: bb.h, samples });
        }
        let f = self.fbs.get(&fb)?.clone();
        let mut colors = Vec::with_capacity(MAX_COLOR_ATTACHMENTS);
        let (mut w, mut h, mut samples) = (0, 0, 1);
        for i in 0..MAX_COLOR_ATTACHMENTS {
            let on = f.draw_buffers[i] == COLOR_ATTACHMENT0 + i as u32;
            let a = if on { f.color[i] } else { None };
            match a {
                Some(a) => {
                    let (aw, ah, fmt, s) = self.attachment_info(&a)?;
                    w = aw;
                    h = ah;
                    samples = s;
                    let view = self.attachment_view(&a)?;
                    colors.push(Some((view, None, fmt.wgpu)));
                }
                None => colors.push(None),
            }
        }
        while matches!(colors.last(), Some(None)) {
            colors.pop();
        }
        let dsa = f.depth.or(f.stencil);
        let ds = match dsa {
            Some(a) => {
                let (aw, ah, fmt, s) = self.attachment_info(&a)?;
                w = aw;
                h = ah;
                samples = s;
                Some((self.attachment_view(&a)?, fmt.wgpu))
            }
            None => None,
        };
        if colors.is_empty() && ds.is_none() {
            // attached only to a buffer that is not drawn to
            for a in f.color.iter().flatten() {
                let (aw, ah, _, s) = self.attachment_info(a)?;
                w = aw;
                h = ah;
                samples = s;
            }
        }
        Some(Target { colors, ds, w, h, samples })
    }

    fn attachment_view(&mut self, a: &Attach) -> Option<wgpu::TextureView> {
        match a {
            Attach::Rb { id } => {
                let enc_gen = self.enc_gen;
                let r = self.rbs.get_mut(id)?;
                r.used_gen = enc_gen;
                r.view.clone()
            }
            Attach::Tex { id, level, layer } => {
                let enc_gen = self.enc_gen;
                let t = self.textures.get_mut(id)?;
                t.used_gen = enc_gen;
                let key = (100u8, *level, *layer);
                if let Some(v) = t.views.get(&key) {
                    return Some(v.clone());
                }
                let fmt = t.fmt?;
                let aspect = if fmt.is_depth_or_stencil() { wgpu::TextureAspect::All } else { wgpu::TextureAspect::All };
                let v = t.gpu.as_ref()?.create_view(&wgpu::TextureViewDescriptor {
                    label: None,
                    format: None,
                    dimension: Some(wgpu::TextureViewDimension::D2),
                    usage: Some(wgpu::TextureUsages::RENDER_ATTACHMENT),
                    aspect,
                    base_mip_level: *level,
                    mip_level_count: Some(1),
                    base_array_layer: *layer,
                    array_layer_count: Some(1),
                });
                t.views.insert(key, v.clone());
                Some(v)
            }
        }
    }

    /// Opens the pass of the current draw framebuffer, with what it starts with.
    pub fn ensure_pass(&mut self, clear: Option<PassClear>) -> Option<Target> {
        let fb = self.st.draw_fb;
        let t = self.target_of(fb)?;
        let clearing_default = fb == 0 && self.needs_clear;
        if self.pass.is_some() && self.pass_fb == Some(fb) && self.cur.depth_range[0] == self.fb_gen as u32 && clear.is_none() && !clearing_default {
            return Some(t);
        }
        self.end_pass();
        self.ensure_encoder();
        let alpha_off = fb == 0 && !self.attrs.alpha;
        let mut colors = Vec::with_capacity(t.colors.len());
        for (i, c) in t.colors.iter().enumerate() {
            colors.push(c.as_ref().map(|(view, resolve, _)| {
                let mut load = wgpu::LoadOp::Load;
                if clearing_default {
                    load = wgpu::LoadOp::Clear(wgpu::Color { r: 0.0, g: 0.0, b: 0.0, a: if alpha_off { 1.0 } else { 0.0 } });
                }
                if let Some(pc) = &clear {
                    if let Some(col) = pc.color {
                        if pc.only.map_or(true, |o| o == i) {
                            load = wgpu::LoadOp::Clear(col);
                        }
                    }
                }
                wgpu::RenderPassColorAttachment { view, depth_slice: None, resolve_target: resolve.as_ref(), ops: wgpu::Operations { load, store: wgpu::StoreOp::Store } }
            }));
        }
        let ds = t.ds.as_ref().map(|(view, format)| {
            let mut dload = wgpu::LoadOp::Load;
            let mut sload = wgpu::LoadOp::Load;
            if clearing_default {
                dload = wgpu::LoadOp::Clear(1.0);
                sload = wgpu::LoadOp::Clear(0);
            }
            if let Some(pc) = &clear {
                if let Some(d) = pc.depth {
                    dload = wgpu::LoadOp::Clear(d);
                }
                if let Some(s) = pc.stencil {
                    sload = wgpu::LoadOp::Clear(s);
                }
            }
            wgpu::RenderPassDepthStencilAttachment {
                view,
                depth_ops: if format.has_depth_aspect() { Some(wgpu::Operations { load: dload, store: wgpu::StoreOp::Store }) } else { None },
                stencil_ops: if format.has_stencil_aspect() { Some(wgpu::Operations { load: sload, store: wgpu::StoreOp::Store }) } else { None },
            }
        });
        let pass = self.encoder.as_mut()?.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: None,
            color_attachments: &colors,
            depth_stencil_attachment: ds,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        self.pass = Some(pass.forget_lifetime());
        self.pass_fb = Some(fb);
        if fb == 0 {
            self.needs_clear = false;
            self.drew_since_present = true;
        }
        self.cur = PassState::default();
        self.cur.depth_range = [self.fb_gen as u32, 0];
        Some(t)
    }

    /// A slice of the ring for this draw: Err when it cannot be had at all.
    fn ring_alloc(&mut self, bytes: &[u8], align: u32) -> Result<u32, ()> {
        let a = align as usize;
        let at = (self.ring_cpu.len() + a - 1) / a * a;
        if at + bytes.len() > RING_BYTES {
            return Err(());
        }
        self.ring_cpu.resize(at, 0);
        self.ring_cpu.extend_from_slice(bytes);
        Ok(at as u32)
    }

    // ---- clears ----

    pub fn gl_clear(&mut self, mask: u32) {
        if mask & !(COLOR_BUFFER_BIT | DEPTH_BUFFER_BIT | STENCIL_BUFFER_BIT) != 0 {
            return self.set_error(INVALID_VALUE);
        }
        let fb = self.st.draw_fb;
        if self.fb_status(fb) != 0x8CD5 {
            return self.set_error(INVALID_FRAMEBUFFER_OPERATION);
        }
        if mask == 0 || self.st.rasterizer_discard {
            return;
        }
        let Some(t) = self.target_of(fb) else { return };
        let (cc, st) = (self.st.clear_color, &self.st);
        let alpha_off = fb == 0 && !self.attrs.alpha;
        let color_on = mask & COLOR_BUFFER_BIT != 0 && st.color_mask.iter().any(|m| *m);
        let depth_on = mask & DEPTH_BUFFER_BIT != 0 && st.depth_mask && t.ds.as_ref().map_or(false, |d| d.1.has_depth_aspect());
        let stencil_mask = st.stencil_front.write_mask & 0xFF;
        let stencil_on = mask & STENCIL_BUFFER_BIT != 0 && stencil_mask != 0 && t.ds.as_ref().map_or(false, |d| d.1.has_stencil_aspect());
        if !color_on && !depth_on && !stencil_on {
            return;
        }
        let rect = self.scissor_rect(t.w, t.h);
        if rect == Some([0, 0, 0, 0]) {
            return;
        }
        let whole = rect.map_or(true, |r| r == [0, 0, t.w, t.h]);
        let color_full = st.color_mask == [true; 4] || (alpha_off && st.color_mask[0] && st.color_mask[1] && st.color_mask[2]);
        let ints = t.colors.iter().flatten().any(|c| formats::sample_kind(c.2) != SampleKind::Float);
        if whole && (!color_on || color_full) && (!stencil_on || stencil_mask == 0xFF) && !ints {
            let c = wgpu::Color { r: cc[0] as f64, g: cc[1] as f64, b: cc[2] as f64, a: if alpha_off { 1.0 } else { cc[3] as f64 } };
            let pc = PassClear {
                color: if color_on { Some(c) } else { None },
                only: None,
                depth: if depth_on { Some(self.st.clear_depth) } else { None },
                stencil: if stencil_on { Some(self.st.clear_stencil as u32 & 0xFF) } else { None },
            };
            self.ensure_pass(Some(pc));
            self.draws_in_submit += 1;
            return;
        }
        // a part of the target, or some channels: drawn
        let mask_c = if color_on { self.st.color_mask } else { [false; 4] };
        let key_colors: Vec<_> = t.colors.iter().flatten().filter(|c| formats::sample_kind(c.2) == SampleKind::Float).map(|c| (c.2, if alpha_off { [mask_c[0], mask_c[1], mask_c[2], false] } else { mask_c })).collect();
        // a pipeline's targets must match the pass's: integer attachments keep a place with no writes
        let colors_for_pipeline: Vec<Option<wgpu::ColorTargetState>> = t
            .colors
            .iter()
            .map(|c| {
                c.as_ref().map(|c| wgpu::ColorTargetState {
                    format: c.2,
                    blend: None,
                    write_mask: if formats::sample_kind(c.2) == SampleKind::Float { color_writes(if alpha_off { [mask_c[0], mask_c[1], mask_c[2], false] } else { mask_c }) } else { wgpu::ColorWrites::empty() },
                })
            })
            .collect();
        let ds_key = t.ds.as_ref().map(|d| (d.1, depth_on, if stencil_on { stencil_mask } else { 0 }));
        let key = (key_colors, ds_key, t.samples);
        if !self.utility.clear.contains_key(&key) {
            let device = self.device.clone();
            let ds_state = ds_key.map(|(format, dw, sm)| {
                let face = wgpu::StencilFaceState { compare: wgpu::CompareFunction::Always, fail_op: wgpu::StencilOperation::Replace, depth_fail_op: wgpu::StencilOperation::Replace, pass_op: wgpu::StencilOperation::Replace };
                wgpu::DepthStencilState {
                    format,
                    depth_write_enabled: Some(dw),
                    depth_compare: Some(wgpu::CompareFunction::Always),
                    stencil: if format.has_stencil_aspect() { wgpu::StencilState { front: face, back: face, read_mask: 0xFF, write_mask: sm } } else { wgpu::StencilState::default() },
                    bias: wgpu::DepthBiasState::default(),
                }
            });
            let p = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("clear"),
                layout: Some(&self.utility.clear_layout),
                vertex: wgpu::VertexState { module: &self.utility.vs, entry_point: Some("main"), compilation_options: Default::default(), buffers: &[] },
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: ds_state,
                multisample: wgpu::MultisampleState { count: t.samples, mask: !0, alpha_to_coverage_enabled: false },
                fragment: Some(wgpu::FragmentState { module: &self.utility.clear_fs, entry_point: Some("main"), compilation_options: Default::default(), targets: &colors_for_pipeline }),
                multiview_mask: None,
                cache: None,
            });
            self.utility.clear.insert(key.clone(), p);
        }
        let mut params = [0f32; 12];
        params[4..8].copy_from_slice(&[cc[0], cc[1], cc[2], if alpha_off { 1.0 } else { cc[3] }]);
        params[8] = self.st.clear_depth;
        let bytes = floats_as_bytes(&params);
        self.ring_room(UTILITY_PARAMS as usize + 1024);
        let Ok(at) = self.ring_alloc(&bytes, self.limits.ubo_align) else { return };
        let bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.utility.params,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: &self.ring, offset: 0, size: wgpu::BufferSize::new(UTILITY_PARAMS) }) }],
        });
        self.ensure_pass(None);
        let sref = self.st.clear_stencil as u32 & 0xFF;
        let p = self.utility.clear[&key].clone();
        let r = rect.unwrap_or([0, 0, t.w, t.h]);
        let pass = self.pass.as_mut().unwrap();
        pass.set_pipeline(&p);
        pass.set_bind_group(0, &bg, &[at]);
        pass.set_stencil_reference(sref);
        pass.set_viewport(0.0, 0.0, t.w as f32, t.h as f32, 0.0, 1.0);
        pass.set_scissor_rect(r[0], r[1], r[2], r[3]);
        pass.draw(0..3, 0..1);
        self.cur = PassState { depth_range: self.cur.depth_range, ..PassState::default() };
        self.draws_in_submit += 1;
    }

    /// Submits now if the ring does not have room for `need` more bytes.
    pub fn ring_room(&mut self, need: usize) {
        if self.ring_cpu.len() + need + self.limits.ubo_align as usize * 4 > RING_BYTES {
            self.submit();
        }
    }

    /// The scissor as a rectangle inside the target; None when the test is off.
    fn scissor_rect(&self, w: u32, h: u32) -> Option<[u32; 4]> {
        if !self.st.scissor_test {
            return None;
        }
        let [x, y, sw, sh] = self.st.scissor;
        let x0 = (x as i64).clamp(0, w as i64);
        let y0 = (y as i64).clamp(0, h as i64);
        let x1 = (x as i64 + sw as i64).clamp(0, w as i64);
        let y1 = (y as i64 + sh as i64).clamp(0, h as i64);
        if x1 <= x0 || y1 <= y0 {
            return Some([0, 0, 0, 0]);
        }
        Some([x0 as u32, y0 as u32, (x1 - x0) as u32, (y1 - y0) as u32])
    }

    /// clearBufferfv and friends. kind: 0 float, 1 int, 2 uint, 3 depth and stencil (first word f32, second i32).
    pub fn clear_buffer(&mut self, buffer: u32, index: i32, kind: u32, v: [u32; 4]) {
        let fb = self.st.draw_fb;
        if self.fb_status(fb) != 0x8CD5 {
            return self.set_error(INVALID_FRAMEBUFFER_OPERATION);
        }
        let as_f64 = |w: u32| -> f64 {
            match kind {
                0 => f32::from_bits(w) as f64,
                1 => w as i32 as f64,
                _ => w as f64,
            }
        };
        let mut pc = PassClear::default();
        match buffer {
            COLOR => {
                if index < 0 || index as u32 >= self.caps.max_draw_buffers {
                    return self.set_error(INVALID_VALUE);
                }
                pc.color = Some(wgpu::Color { r: as_f64(v[0]), g: as_f64(v[1]), b: as_f64(v[2]), a: as_f64(v[3]) });
                pc.only = Some(index as usize);
            }
            DEPTH => {
                if index != 0 {
                    return self.set_error(INVALID_VALUE);
                }
                pc.depth = Some(f32::from_bits(v[0]).clamp(0.0, 1.0));
            }
            STENCIL => {
                if index != 0 {
                    return self.set_error(INVALID_VALUE);
                }
                pc.stencil = Some(v[0] & 0xFF);
            }
            DEPTH_STENCIL_BUFFER => {
                if index != 0 {
                    return self.set_error(INVALID_VALUE);
                }
                pc.depth = Some(f32::from_bits(v[0]).clamp(0.0, 1.0));
                pc.stencil = Some(v[1] & 0xFF);
            }
            _ => return self.set_error(INVALID_ENUM),
        }
        self.ensure_pass(Some(pc));
        self.draws_in_submit += 1;
    }

    // ---- draws ----

    pub fn draw_arrays(&mut self, mode: u32, first: i32, count: i32, instances: i32) {
        if mode > TRIANGLE_FAN {
            return self.set_error(INVALID_ENUM);
        }
        if first < 0 || count < 0 || instances < 0 {
            return self.set_error(INVALID_VALUE);
        }
        let Some(last) = (first as i64 + count as i64 - 1).try_into().ok().filter(|_: &u32| count > 0) else {
            // no vertex: the other checks still apply
            self.draw_common(mode, DrawKind::Arrays { first: first as u32, count: 0 }, instances as u32, 0);
            return;
        };
        self.draw_common(mode, DrawKind::Arrays { first: first as u32, count: count as u32 }, instances as u32, last);
    }

    pub fn draw_elements(&mut self, mode: u32, count: i32, ty: u32, offset: i64, instances: i32) {
        if mode > TRIANGLE_FAN {
            return self.set_error(INVALID_ENUM);
        }
        let Some(bytes) = index_bytes(ty, self.ext.element_index_uint) else { return self.set_error(INVALID_ENUM) };
        if count < 0 || instances < 0 {
            return self.set_error(INVALID_VALUE);
        }
        if offset < 0 {
            return self.set_error(INVALID_VALUE);
        }
        if offset as u64 % bytes as u64 != 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let eid = self.current_vao().element;
        if eid == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let webgl2 = self.is_webgl2();
        let Some(b) = self.buffers.get_mut(&eid) else { return self.set_error(INVALID_OPERATION) };
        let end = offset as u64 + count as u64 * bytes as u64;
        if end > b.shadow.len() as u64 {
            return self.set_error(INVALID_OPERATION);
        }
        let key = (offset as u32, count as u32, ty);
        let max = if count == 0 {
            0
        } else if let Some(m) = b.max_index.get(&key) {
            *m
        } else {
            let data = &b.shadow[offset as usize..end as usize];
            let m = max_index(data, bytes, webgl2);
            if b.max_index.len() > 256 {
                b.max_index.clear();
            }
            b.max_index.insert(key, m);
            m
        };
        self.draw_common(mode, DrawKind::Elements { count: count as u32, ty, bytes, offset: offset as u32, element: eid }, instances as u32, max);
    }

    fn draw_common(&mut self, mode: u32, kind: DrawKind, instances: u32, last_vertex: u32) {
        let pid = self.st.program;
        if pid == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let Some(mut linked) = self.programs.get_mut(&pid).and_then(|p| p.linked.take()) else {
            return self.set_error(INVALID_OPERATION);
        };
        let r = self.draw_inner(&mut linked, mode, kind, instances, last_vertex);
        if let Some(p) = self.programs.get_mut(&pid) {
            p.linked = Some(linked);
        }
        if let Err(code) = r {
            if code != 0 {
                self.set_error(code);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_inner(&mut self, l: &mut Linked, mode: u32, kind: DrawKind, instances: u32, last_vertex: u32) -> Result<(), u32> {
        let vao_id = self.st.vao;
        let vao = self.vaos.get(&vao_id).cloned().unwrap_or_default();
        let count_of = match kind {
            DrawKind::Arrays { count, .. } => count,
            DrawKind::Elements { count, .. } => count,
        };
        // attributes against buffers: what WebGL requires so that no draw reads out of bounds
        let points = mode == POINTS;
        for (name, ty, arr, loc, _) in &l.attributes {
            let _ = name;
            let slots = ty.cols * (*arr).max(1);
            for k in 0..slots {
                let index = (*loc + k) as usize;
                if index >= MAX_ATTRIBS {
                    continue;
                }
                let a = &vao.attrs[index];
                let wants_int = ty.scalar() != translate::Scalar::Float;
                if a.enabled {
                    if a.buffer == 0 {
                        return Err(INVALID_OPERATION);
                    }
                    if self.attrs.webgl2 && a.integer != wants_int {
                        return Err(INVALID_OPERATION);
                    }
                    if !self.attrs.webgl2 && wants_int {
                        return Err(INVALID_OPERATION);
                    }
                    if count_of > 0 && instances > 0 {
                        let size = attr_bytes(a) as u64;
                        let stride = if a.stride == 0 { size } else { a.stride as u64 };
                        let n: u64 = if a.divisor == 0 { last_vertex as u64 } else { (instances as u64 - 1) / a.divisor as u64 };
                        let need = a.offset as u64 + n * stride + size;
                        let have = self.buffers.get(&a.buffer).map_or(0, |b| b.shadow.len()) as u64;
                        if need > have {
                            return Err(INVALID_OPERATION);
                        }
                    }
                }
            }
        }
        let fb = self.st.draw_fb;
        if self.fb_status(fb) != 0x8CD5 {
            return Err(INVALID_FRAMEBUFFER_OPERATION);
        }
        let front = self.st.stencil_front;
        let back = self.st.stencil_back;
        if (front.write_mask & 0xFF) != (back.write_mask & 0xFF) || (front.read_mask & 0xFF) != (back.read_mask & 0xFF) || (front.reference & 0xFF) != (back.reference & 0xFF) {
            return Err(INVALID_OPERATION);
        }
        let f = self.st.blend_func;
        let is_const = |x: u32| matches!(x, 0x8001 | 0x8002);
        let is_alpha_const = |x: u32| matches!(x, 0x8003 | 0x8004);
        if self.st.blend && ((is_const(f[0]) || is_const(f[1])) && (is_alpha_const(f[0]) || is_alpha_const(f[1]))) {
            return Err(INVALID_OPERATION);
        }
        if count_of == 0 || instances == 0 {
            return Ok(());
        }
        if self.st.rasterizer_discard {
            return Ok(());
        }
        let triangles = matches!(mode, TRIANGLES | TRIANGLE_STRIP | TRIANGLE_FAN);
        if self.st.cull && self.st.cull_face == FRONT_AND_BACK && triangles {
            return Ok(());
        }
        if self.st.viewport[2] == 0 || self.st.viewport[3] == 0 {
            return Ok(());
        }
        let Some(t) = self.target_of(fb) else { return Err(INVALID_FRAMEBUFFER_OPERATION) };
        let rect = self.scissor_rect(t.w, t.h);
        if rect == Some([0, 0, 0, 0]) {
            return Ok(());
        }

        // textures: a bind group for what the units hold now
        let n_samplers = l.sampler_dims.len();
        let mut binds = Vec::with_capacity(n_samplers);
        let mut views: Vec<wgpu::TextureView> = Vec::with_capacity(n_samplers);
        let mut samplers: Vec<wgpu::Sampler> = Vec::with_capacity(n_samplers);
        let mut group_key: Vec<u64> = Vec::with_capacity(n_samplers * 2);
        if n_samplers > 0 {
            let mut attached: Vec<u32> = Vec::new();
            if fb != 0 {
                if let Some(f) = self.fbs.get(&fb) {
                    for a in f.color.iter().flatten().chain(f.depth.iter()).chain(f.stencil.iter()) {
                        if let Attach::Tex { id, .. } = a {
                            attached.push(*id);
                        }
                    }
                }
            }
            for i in 0..n_samplers {
                let (dim, sk, shadow) = l.sampler_dims[i];
                let unit = l.sampler_units[i] as usize;
                let tid = match dim {
                    wgpu::TextureViewDimension::Cube => self.st.tex_cube[unit],
                    wgpu::TextureViewDimension::D3 => self.st.tex_3d[unit],
                    wgpu::TextureViewDimension::D2Array => self.st.tex_array[unit],
                    _ => self.st.tex_2d[unit],
                };
                if tid != 0 && attached.contains(&tid) {
                    return Err(INVALID_OPERATION); // a feedback loop
                }
                let sobj = self.st.samplers[unit];
                let mut params = None;
                if sobj != 0 {
                    params = self.sampler_objs.get(&sobj).copied();
                }
                let tex_state = self.texture_for_draw(tid, dim, sk, shadow, params);
                let (view, token, bind, state) = match tex_state {
                    Some(x) => x,
                    None => {
                        let k = match (sk, shadow) {
                            (SampleKind::Sint, _) => BindKind::Sint,
                            (SampleKind::Uint, _) => BindKind::Uint,
                            (_, true) => BindKind::Shadow,
                            _ => BindKind::Filterable,
                        };
                        let (v, tok) = self.fallback_view(dim, k);
                        let mut s = SamplerState::default();
                        s.min = NEAREST;
                        s.mag = NEAREST;
                        if k == BindKind::Shadow {
                            s.compare_mode = COMPARE_REF_TO_TEXTURE;
                        }
                        (v, tok, k, s)
                    }
                };
                let mut state = state;
                if bind == BindKind::Unfilterable {
                    state.min = NEAREST;
                    state.mag = NEAREST;
                }
                if bind == BindKind::Shadow && state.compare_mode != COMPARE_REF_TO_TEXTURE {
                    state.compare_mode = COMPARE_REF_TO_TEXTURE;
                } else if bind != BindKind::Shadow {
                    state.compare_mode = NONE;
                }
                if matches!(bind, BindKind::Sint | BindKind::Uint) {
                    state.min = NEAREST;
                    state.mag = NEAREST;
                }
                let (sampler, stok) = self.sampler_for(state);
                binds.push(bind);
                views.push(view);
                samplers.push(sampler);
                group_key.push(token);
                group_key.push(stok);
            }
        }

        // what the ring needs for this draw
        let mut generated: Option<(Vec<u8>, wgpu::IndexFormat, u32)> = None;
        if let DrawKind::Elements { count, ty, bytes, offset, element } = kind {
            let shadow = &self.buffers[&element].shadow;
            let data = &shadow[offset as usize..(offset + count * bytes) as usize];
            if points {
                // drawn point by point: see below
            } else if ty == formats::UNSIGNED_BYTE || mode == LINE_LOOP || mode == TRIANGLE_FAN {
                generated = Some(generate_indices(mode, Some((data, bytes)), 0, count));
            }
        } else if let DrawKind::Arrays { first, count } = kind {
            if mode == LINE_LOOP || mode == TRIANGLE_FAN {
                generated = Some(generate_indices(mode, None, first, count));
            }
        }
        let gen_len = generated.as_ref().map_or(0, |g| g.0.len());
        if gen_len + l.vs_image.len() + l.fs_image.len() + 4096 > RING_BYTES {
            self.warn("WebGL: a draw needs more generated index data than the context holds".to_string());
            return Err(OUT_OF_MEMORY);
        }
        self.ring_room(gen_len + l.vs_image.len() + l.fs_image.len() + 2048);

        // vertex streams
        let mut slots: Vec<SlotLayout> = Vec::new();
        let mut slot_buffers: Vec<(wgpu::Buffer, u64)> = Vec::new();
        let mut slot_keys: Vec<(u32, u32, bool, u64)> = Vec::new();
        for (_, ty, arr, loc, _) in &l.attributes {
            let n = ty.cols * (*arr).max(1);
            let scalar = ty.scalar();
            for k in 0..n {
                let index = (*loc + k) as usize;
                if index >= MAX_ATTRIBS {
                    continue;
                }
                let a = vao.attrs[index];
                if !a.enabled {
                    // a constant for all vertices: from the ring, stride 0
                    let words = self.st.generic[index];
                    let mut bytes = [0u8; 16];
                    for (j, w) in words.iter().enumerate() {
                        bytes[j * 4..j * 4 + 4].copy_from_slice(&w.to_ne_bytes());
                    }
                    let at = self.ring_alloc(&bytes, 16).map_err(|_| OUT_OF_MEMORY)?;
                    let format = match scalar {
                        translate::Scalar::Int => wgpu::VertexFormat::Sint32x4,
                        translate::Scalar::Uint => wgpu::VertexFormat::Uint32x4,
                        _ => wgpu::VertexFormat::Float32x4,
                    };
                    slots.push(SlotLayout { stride: 0, instance: true, attrs: vec![(format, 0, index as u32)] });
                    slot_buffers.push((self.ring.clone(), at as u64));
                    slot_keys.push((u32::MAX, 0, true, at as u64));
                    continue;
                }
                let size = attr_bytes(&a);
                let stride = if a.stride == 0 { size } else { a.stride };
                let fmt = vertex_format(&a);
                let instance = a.divisor != 0 || points;
                if a.divisor > 1 && self.console.len() < 8 {
                    self.warn("WebGL: a vertex attribute divisor above 1 is drawn as 1".to_string());
                }
                let native = fmt.filter(|f| {
                    let align = f.size().min(4);
                    stride % 4 == 0 && (a.offset as u64) % align == 0 && (f.size() as u32) <= stride
                });
                let (buffer, format, off, stride) = match native {
                    Some(f) => {
                        let b = self.buffers.get_mut(&a.buffer).unwrap();
                        b.used_gen = self.enc_gen;
                        (b.gpu.clone().ok_or(INVALID_OPERATION)?, f, a.offset as u64, stride)
                    }
                    None => {
                        let (buf, f, st) = self.converted_stream(a.buffer, &a).ok_or(OUT_OF_MEMORY)?;
                        (buf, f, 0, st)
                    }
                };
                // a slot of the same buffer, stride and stepping, if the attribute fits in it
                let base = off & !3;
                let mut placed = false;
                let buf_key = token_of(&buffer);
                for (si, s) in slots.iter_mut().enumerate() {
                    let (kb, ks, ki, kbase) = slot_keys[si];
                    if kb == buf_key && ks == stride && ki == instance && off >= kbase && (off - kbase) + format.size() <= stride as u64 {
                        s.attrs.push((format, (off - kbase) as u32, index as u32));
                        placed = true;
                        break;
                    }
                }
                if !placed {
                    slots.push(SlotLayout { stride, instance, attrs: vec![(format, (off - base) as u32, index as u32)] });
                    slot_buffers.push((buffer, base));
                    slot_keys.push((buf_key, stride, instance, base));
                }
            }
        }
        if slots.len() > self.limits.max_vertex_buffers as usize {
            self.warn(format!("WebGL: this draw needs {} vertex buffers, the device has {}", slots.len(), self.limits.max_vertex_buffers));
            return Err(INVALID_OPERATION);
        }

        // the pipeline
        let strip_index = match (mode, &kind, &generated) {
            (LINE_STRIP | TRIANGLE_STRIP, DrawKind::Elements { ty, .. }, None) => Some(if *ty == formats::UNSIGNED_INT { wgpu::IndexFormat::Uint32 } else { wgpu::IndexFormat::Uint16 }),
            (LINE_LOOP, _, Some(g)) => Some(g.1),
            (LINE_STRIP | TRIANGLE_STRIP, _, Some(g)) => Some(g.1),
            _ => None,
        };
        let topology = match mode {
            POINTS | TRIANGLES | TRIANGLE_FAN => wgpu::PrimitiveTopology::TriangleList,
            LINES => wgpu::PrimitiveTopology::LineList,
            LINE_LOOP | LINE_STRIP => wgpu::PrimitiveTopology::LineStrip,
            _ => wgpu::PrimitiveTopology::TriangleStrip,
        };
        let st = &self.st;
        let key = PipelineKey {
            points,
            topology,
            strip_index,
            blend: if st.blend { Some([st.blend_eq[0], st.blend_eq[1], st.blend_func[0], st.blend_func[1], st.blend_func[2], st.blend_func[3]]) } else { None },
            color_mask: if fb == 0 && !self.attrs.alpha { [st.color_mask[0], st.color_mask[1], st.color_mask[2], false] } else { st.color_mask },
            depth: if st.depth_test && t.ds.as_ref().map_or(false, |d| d.1.has_depth_aspect()) { Some((st.depth_mask, st.depth_func)) } else { None },
            stencil: if st.stencil_test && t.ds.as_ref().map_or(false, |d| d.1.has_stencil_aspect()) {
                Some([front.func, front.fail, front.zfail, front.zpass, back.func, back.fail, back.zfail, back.zpass, front.read_mask & 0xFF, front.write_mask & 0xFF])
            } else {
                None
            },
            cull: if st.cull && triangles { st.cull_face } else { 0 },
            front: st.front_face,
            offset: if st.polygon_offset { Some((st.polygon_factor.to_bits(), st.polygon_units.to_bits())) } else { None },
            alpha_to_coverage: st.alpha_to_coverage && t.samples > 1,
            samples: t.samples,
            colors: t.colors.iter().map(|c| c.as_ref().map(|c| c.2)).collect(),
            ds: t.ds.as_ref().map(|d| d.1),
            slots: slots.clone(),
            binds: binds.clone(),
        };
        let pipeline = self.pipeline(l, &key)?;
        let Some(pipeline) = pipeline else { return Err(INVALID_OPERATION) };

        // uniforms in the ring
        let align = self.limits.ubo_align;
        if l.ring_epoch != self.ring_epoch {
            l.vs_dirty = true;
            l.fs_dirty = true;
            l.ring_epoch = self.ring_epoch;
        }
        // (the viewport's size for points lives in the vertex block)
        if points {
            let vp = [self.st.viewport[2] as f32, self.st.viewport[3] as f32];
            let old = [f32::from_ne_bytes(l.vs_image[0..4].try_into().unwrap()), f32::from_ne_bytes(l.vs_image[4..8].try_into().unwrap())];
            if old != vp {
                l.vs_image[0..4].copy_from_slice(&vp[0].to_ne_bytes());
                l.vs_image[4..8].copy_from_slice(&vp[1].to_ne_bytes());
                l.vs_dirty = true;
            }
        }
        if l.vs_dirty {
            l.vs_at = self.ring_alloc(&l.vs_image, align).map_err(|_| OUT_OF_MEMORY)?;
            l.vs_dirty = false;
        }
        if l.fs_dirty && !l.fs_image.is_empty() {
            l.fs_at = self.ring_alloc(&l.fs_image, align).map_err(|_| OUT_OF_MEMORY)?;
            l.fs_dirty = false;
        }
        let gen_at = match &generated {
            Some((data, fmt, _)) => {
                let a = if *fmt == wgpu::IndexFormat::Uint32 { 4 } else { 2 };
                Some(self.ring_alloc(data, a).map_err(|_| OUT_OF_MEMORY)?)
            }
            None => None,
        };

        // bind groups
        self.ensure_bg0(l);
        let tex_group = if n_samplers > 0 {
            if l.tex_groups.len() > MAX_CACHED_BIND_GROUPS {
                l.tex_groups.clear();
            }
            let mut full_key = group_key.clone();
            for b in &binds {
                full_key.push(*b as u64);
            }
            if !l.tex_groups.contains_key(&full_key) {
                let layout = &l.layouts.get(&binds).ok_or(0u32)?.0;
                let mut entries = Vec::with_capacity(n_samplers * 2);
                for i in 0..n_samplers {
                    entries.push(wgpu::BindGroupEntry { binding: i as u32 * 2, resource: wgpu::BindingResource::TextureView(&views[i]) });
                    entries.push(wgpu::BindGroupEntry { binding: i as u32 * 2 + 1, resource: wgpu::BindingResource::Sampler(&samplers[i]) });
                }
                let bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor { label: None, layout, entries: &entries });
                l.tex_groups.insert(full_key.clone(), bg);
            }
            Some(l.tex_groups[&full_key].clone())
        } else {
            None
        };
        let block_group = if !l.blocks.is_empty() { Some(self.block_group(l)?) } else { None };

        // the pass
        let scissor = rect.unwrap_or([0, 0, t.w, t.h]);
        if self.ensure_pass(None).is_none() {
            return Err(INVALID_FRAMEBUFFER_OPERATION);
        }
        for (b, _) in slot_buffers.iter() {
            let _ = b;
        }
        let vp = self.st.viewport;
        let dr = self.st.depth_range;
        let blend_c = self.st.blend_color;
        let sref = (self.st.stencil_front.reference & 0xFF) as u32;
        let has_points_tex = points;
        let _ = has_points_tex;
        let stale_vp = self.cur.viewport != Some(vp) || self.cur.depth_range[1] != dr[1].to_bits();
        let stale_scissor = self.cur.scissor != Some(scissor);
        let bc_bits = [blend_c[0].to_bits(), blend_c[1].to_bits(), blend_c[2].to_bits(), blend_c[3].to_bits()];
        let stale_bc = self.cur.blend_constant != Some(bc_bits);
        let stale_ref = self.cur.stencil_ref != Some(sref);
        let enc_gen = self.enc_gen;
        let empty_group = if tex_group.is_none() { Some(self.utility_empty_group()) } else { None };
        let pass = self.pass.as_mut().ok_or(0u32)?;
        pass.set_pipeline(&pipeline);
        if stale_vp {
            let m = t.w.max(t.h) as f32 * 2.0;
            let (x, y, w, h) = (vp[0] as f32, vp[1] as f32, (vp[2] as f32).min(32767.0), (vp[3] as f32).min(32767.0));
            let _ = m;
            pass.set_viewport(x, y, w, h, dr[0], dr[1]);
            self.cur.viewport = Some(vp);
            self.cur.depth_range[1] = dr[1].to_bits();
        }
        if stale_scissor {
            pass.set_scissor_rect(scissor[0], scissor[1], scissor[2], scissor[3]);
            self.cur.scissor = Some(scissor);
        }
        if stale_bc {
            pass.set_blend_constant(wgpu::Color { r: blend_c[0] as f64, g: blend_c[1] as f64, b: blend_c[2] as f64, a: blend_c[3] as f64 });
            self.cur.blend_constant = Some(bc_bits);
        }
        if stale_ref {
            pass.set_stencil_reference(sref);
            self.cur.stencil_ref = Some(sref);
        }
        let bg0 = l.bg0.as_ref().ok_or(0u32)?;
        if l.fs_image.is_empty() {
            pass.set_bind_group(0, bg0, &[l.vs_at]);
        } else {
            pass.set_bind_group(0, bg0, &[l.vs_at, l.fs_at]);
        }
        if let Some(g) = tex_group.as_ref().or(empty_group.as_ref()) {
            pass.set_bind_group(1, g, &[]);
        }
        if let Some(g) = &block_group {
            pass.set_bind_group(2, g, &[]);
        }
        for (i, (b, off)) in slot_buffers.iter().enumerate() {
            pass.set_vertex_buffer(i as u32, b.slice(*off..));
        }
        let inst = 0..instances;
        match (kind, gen_at, &generated) {
            (DrawKind::Arrays { first, count }, None, _) => {
                if points {
                    pass.draw(0..6, first..first + count);
                } else {
                    pass.draw(first..first + count, inst);
                }
            }
            (DrawKind::Elements { count, ty, bytes, offset, element }, None, _) => {
                if points {
                    let shadow = &self.buffers[&element].shadow;
                    let data = &shadow[offset as usize..(offset + count * bytes) as usize];
                    for chunk in data.chunks_exact(bytes as usize) {
                        let v = match bytes {
                            1 => chunk[0] as u32,
                            2 => u16::from_ne_bytes([chunk[0], chunk[1]]) as u32,
                            _ => u32::from_ne_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]),
                        };
                        pass.draw(0..6, v..v + 1);
                    }
                } else {
                    let b = self.buffers.get_mut(&element).ok_or(INVALID_OPERATION)?;
                    b.used_gen = enc_gen;
                    let gpu = b.gpu.as_ref().ok_or(INVALID_OPERATION)?;
                    let f = if ty == formats::UNSIGNED_INT { wgpu::IndexFormat::Uint32 } else { wgpu::IndexFormat::Uint16 };
                    pass.set_index_buffer(gpu.slice(offset as u64..), f);
                    pass.draw_indexed(0..count, 0, inst);
                }
            }
            (_, Some(at), Some((_, fmt, n))) => {
                let ring = self.ring.clone();
                pass.set_index_buffer(ring.slice(at as u64..), *fmt);
                pass.draw_indexed(0..*n, 0, inst);
            }
            _ => {}
        }
        self.draws_in_submit += 1;
        if fb == 0 {
            self.drew_since_present = true;
        }
        Ok(())
    }

    /// The group bound at 1 when a program has no samplers.
    fn utility_empty_group(&mut self) -> wgpu::BindGroup {
        if let Some((_, bg)) = self.fallback_group.as_ref() {
            return bg.clone();
        }
        let layout = self.device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &[] });
        let bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor { label: None, layout: &layout, entries: &[] });
        self.fallback_group = Some((layout, bg.clone()));
        bg
    }

    /// A vertex stream converted to floats (or 32-bit integers), kept while the buffer does not change.
    fn converted_stream(&mut self, id: u32, a: &Attr) -> Option<(wgpu::Buffer, wgpu::VertexFormat, u32)> {
        let key = (a.ty, a.size, a.normalized, a.stride, a.offset);
        let device = self.device.clone();
        let queue = self.queue.clone();
        let b = self.buffers.get_mut(&id)?;
        if let Some((buf, f, st)) = b.converted.get(&key) {
            return Some((buf.clone(), *f, *st));
        }
        let size = attr_bytes(a) as usize;
        let stride = if a.stride == 0 { size } else { a.stride as usize };
        let off = a.offset as usize;
        if b.shadow.len() < off + size {
            return None;
        }
        let n = (b.shadow.len() - off - size) / stride + 1;
        let comps = a.size as usize;
        let out_stride = 4 * comps;
        let total = n.checked_mul(out_stride)?;
        if total > MAX_CONVERTED_STREAM_BYTES {
            return None;
        }
        let mut data = vec![0u8; total];
        let ts = if a.size > 0 { size / comps } else { 1 };
        for v in 0..n {
            let s = &b.shadow[off + v * stride..off + v * stride + size];
            let d = &mut data[v * out_stride..(v + 1) * out_stride];
            for c in 0..comps {
                let x = &s[c * ts..(c + 1) * ts];
                if a.integer {
                    let val = read_component(x, a.ty, false);
                    let w = if a.ty == formats::UNSIGNED_INT || a.ty == formats::UNSIGNED_SHORT || a.ty == formats::UNSIGNED_BYTE { val as u32 } else { val as i32 as u32 };
                    d[c * 4..c * 4 + 4].copy_from_slice(&w.to_ne_bytes());
                } else {
                    let val = read_component(x, a.ty, a.normalized) as f32;
                    d[c * 4..c * 4 + 4].copy_from_slice(&val.to_ne_bytes());
                }
            }
        }
        use wgpu::VertexFormat as V;
        let unsigned = matches!(a.ty, formats::UNSIGNED_INT | formats::UNSIGNED_SHORT | formats::UNSIGNED_BYTE);
        let format = match (a.integer, unsigned, comps) {
            (false, _, 1) => V::Float32,
            (false, _, 2) => V::Float32x2,
            (false, _, 3) => V::Float32x3,
            (false, _, _) => V::Float32x4,
            (true, true, 1) => V::Uint32,
            (true, true, 2) => V::Uint32x2,
            (true, true, 3) => V::Uint32x3,
            (true, true, _) => V::Uint32x4,
            (true, false, 1) => V::Sint32,
            (true, false, 2) => V::Sint32x2,
            (true, false, 3) => V::Sint32x3,
            (true, false, _) => V::Sint32x4,
        };
        let buf = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: total.max(4) as u64, usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false });
        queue.write_buffer(&buf, 0, &data);
        b.converted.insert(key, (buf.clone(), format, out_stride as u32));
        Some((buf, format, out_stride as u32))
    }

    /// A texture for a sampler, or None when it is incomplete (a fallback reads black).
    fn texture_for_draw(&mut self, id: u32, dim: wgpu::TextureViewDimension, sk: SampleKind, shadow: bool, sampler_obj: Option<SamplerState>) -> Option<(wgpu::TextureView, u64, BindKind, SamplerState)> {
        if id == 0 {
            return None;
        }
        let webgl2 = self.attrs.webgl2;
        let (float_linear, half_linear) = (self.ext.texture_float_linear || self.features.contains(wgpu::Features::FLOAT32_FILTERABLE) && webgl2, self.ext.texture_half_float_linear || webgl2);
        let enc_gen = self.enc_gen;
        let device_float32_filter = self.features.contains(wgpu::Features::FLOAT32_FILTERABLE);
        let t = self.textures.get_mut(&id)?;
        let fmt = t.fmt?;
        t.gpu.as_ref()?;
        let params = sampler_obj.unwrap_or(t.params);
        let uses_mip = !matches!(params.min, NEAREST | LINEAR);
        let linear_wanted = params.mag == LINEAR || matches!(params.min, LINEAR | LINEAR_MIPMAP_NEAREST | NEAREST_MIPMAP_LINEAR | LINEAR_MIPMAP_LINEAR);
        // completeness
        let faces = if t.target == TEXTURE_CUBE_MAP { 6 } else { 1 };
        let base = t.base_level.min(31);
        for f in 0..faces {
            if t.defined[f] & (1 << base) == 0 {
                return None;
            }
        }
        if uses_mip {
            let top = base + full_levels((t.w >> base).max(1), (t.h >> base).max(1), if t.target == TEXTURE_3D { (t.d >> base).max(1) } else { 1 }) - 1;
            let last = top.min(t.max_level).min(t.levels.saturating_sub(1)).min(31);
            for f in 0..faces {
                for level in base..=last {
                    if t.defined[f] & (1 << level) == 0 {
                        return None;
                    }
                }
            }
        }
        if !webgl2 {
            let npot = !t.w.is_power_of_two() || !t.h.is_power_of_two();
            if npot && (uses_mip || params.wrap_s != CLAMP_TO_EDGE || params.wrap_t != CLAMP_TO_EDGE) {
                return None;
            }
        }
        // what the sampler says against what the texture holds
        let kind = fmt.sample_kind();
        let bind = match (sk, kind) {
            (SampleKind::Sint, SampleKind::Sint) => BindKind::Sint,
            (SampleKind::Uint, SampleKind::Uint) => BindKind::Uint,
            (SampleKind::Depth, SampleKind::Depth) => BindKind::Shadow,
            (SampleKind::Float, SampleKind::Depth) => {
                if linear_wanted && params.compare_mode == NONE && !shadow {
                    return None;
                }
                BindKind::Unfilterable
            }
            (SampleKind::Float, SampleKind::Float) => {
                let filterable = match fmt.wgpu {
                    wgpu::TextureFormat::Rgba32Float | wgpu::TextureFormat::R32Float | wgpu::TextureFormat::Rg32Float => device_float32_filter,
                    _ => true,
                };
                let allowed = match fmt.wgpu {
                    wgpu::TextureFormat::Rgba32Float | wgpu::TextureFormat::R32Float | wgpu::TextureFormat::Rg32Float => float_linear && filterable,
                    wgpu::TextureFormat::Rgba16Float if !webgl2 => half_linear,
                    _ => true,
                };
                if linear_wanted && !allowed {
                    return None;
                }
                if filterable {
                    BindKind::Filterable
                } else {
                    BindKind::Unfilterable
                }
            }
            _ => return None,
        };
        t.used_gen = enc_gen;
        let dim_code = match dim {
            wgpu::TextureViewDimension::D2 => 0u8,
            wgpu::TextureViewDimension::Cube => 1,
            wgpu::TextureViewDimension::D3 => 2,
            _ => 3,
        };
        let levels = t.levels.saturating_sub(base).max(1).min(t.max_level.saturating_sub(base).saturating_add(1));
        let key = (dim_code, base, levels);
        if !t.views.contains_key(&key) {
            let aspect = if fmt.is_depth_or_stencil() { wgpu::TextureAspect::DepthOnly } else { wgpu::TextureAspect::All };
            let v = t.gpu.as_ref()?.create_view(&wgpu::TextureViewDescriptor {
                label: None,
                format: None,
                dimension: Some(dim),
                usage: Some(wgpu::TextureUsages::TEXTURE_BINDING),
                aspect,
                base_mip_level: base.min(t.levels.saturating_sub(1)),
                mip_level_count: Some(levels),
                base_array_layer: 0,
                array_layer_count: None,
            });
            t.views.insert(key, v);
        }
        let view = t.views[&key].clone();
        let token = ((id as u64) << 32) | (t.generation << 8) | ((levels as u64) << 3) | dim_code as u64 | ((base as u64) << 56);
        Some((view, token, bind, params))
    }

    fn ensure_bg0(&mut self, l: &mut Linked) {
        if l.bgl0.is_some() {
            return;
        }
        let vis_v = wgpu::ShaderStages::VERTEX;
        let vis_f = wgpu::ShaderStages::FRAGMENT;
        let mut entries = vec![wgpu::BindGroupLayoutEntry {
            binding: 0,
            visibility: vis_v,
            ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: true, min_binding_size: wgpu::BufferSize::new(l.vs_image.len() as u64) },
            count: None,
        }];
        if !l.fs_image.is_empty() {
            entries.push(wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: vis_f,
                ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: true, min_binding_size: wgpu::BufferSize::new(l.fs_image.len() as u64) },
                count: None,
            });
        }
        let layout = self.device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &entries });
        let mut group = vec![wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: &self.ring, offset: 0, size: wgpu::BufferSize::new(l.vs_image.len() as u64) }) }];
        if !l.fs_image.is_empty() {
            group.push(wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: &self.ring, offset: 0, size: wgpu::BufferSize::new(l.fs_image.len() as u64) }) });
        }
        let bg = self.device.create_bind_group(&wgpu::BindGroupDescriptor { label: None, layout: &layout, entries: &group });
        l.bgl0 = Some(layout);
        l.bg0 = Some(bg);
        if !l.blocks.is_empty() {
            let mut e = Vec::new();
            for (i, b) in l.blocks.iter().enumerate() {
                e.push(wgpu::BindGroupLayoutEntry {
                    binding: l.stage_blocks[i],
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: wgpu::BufferSize::new(b.size as u64) },
                    count: None,
                });
            }
            l.bgl2 = Some(self.device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &e }));
        }
    }

    /// The group of a program's blocks of uniforms; a binding left empty or too small is INVALID_OPERATION.
    fn block_group(&mut self, l: &mut Linked) -> Result<wgpu::BindGroup, u32> {
        let mut key = Vec::with_capacity(l.blocks.len() * 3);
        let enc_gen = self.enc_gen;
        for (i, b) in l.blocks.iter().enumerate() {
            let (id, off, size) = self.st.ubo_ranges[l.block_bindings[i] as usize];
            if id == 0 {
                return Err(INVALID_OPERATION);
            }
            let bf = self.buffers.get_mut(&id).ok_or(INVALID_OPERATION)?;
            bf.used_gen = enc_gen;
            let len = bf.shadow.len() as u64;
            let avail = if size == u32::MAX as u64 { len.saturating_sub(off) } else { size.min(len.saturating_sub(off)) };
            if avail < b.size as u64 {
                return Err(INVALID_OPERATION);
            }
            key.push(token_of(bf.gpu.as_ref().ok_or(INVALID_OPERATION)?) as u64);
            key.push(off);
            key.push(avail);
        }
        if l.block_groups.len() > MAX_CACHED_BIND_GROUPS {
            l.block_groups.clear();
        }
        if let Some(g) = l.block_groups.get(&key) {
            return Ok(g.clone());
        }
        let mut entries = Vec::new();
        for (i, _) in l.blocks.iter().enumerate() {
            let (id, off, size) = self.st.ubo_ranges[l.block_bindings[i] as usize];
            let bf = &self.buffers[&id];
            let len = bf.shadow.len() as u64;
            let avail = if size == u32::MAX as u64 { len.saturating_sub(off) } else { size.min(len.saturating_sub(off)) };
            let avail = avail.min(self.limits.max_uniform_block as u64);
            entries.push(wgpu::BindGroupEntry {
                binding: l.stage_blocks[i],
                resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: bf.gpu.as_ref().ok_or(INVALID_OPERATION)?, offset: off, size: wgpu::BufferSize::new(avail) }),
            });
        }
        let layout = l.bgl2.as_ref().ok_or(0u32)?;
        let g = self.device.create_bind_group(&wgpu::BindGroupDescriptor { label: None, layout, entries: &entries });
        l.block_groups.insert(key, g.clone());
        Ok(g)
    }

    /// The pipeline of a key, made on first use. Ok(None): it could not be made (a warning went to the console).
    fn pipeline(&mut self, l: &mut Linked, key: &PipelineKey) -> Result<Option<wgpu::RenderPipeline>, u32> {
        if let Some(p) = l.pipelines.get(key) {
            return Ok(p.clone());
        }
        if l.pipelines.len() > MAX_CACHED_PIPELINES {
            l.pipelines.clear();
        }
        self.ensure_bg0(l);
        if !l.layouts.contains_key(&key.binds) {
            let mut entries = Vec::with_capacity(key.binds.len() * 2);
            for (i, b) in key.binds.iter().enumerate() {
                let (dim, _, _) = l.sampler_dims[i];
                let (sample_type, sampler_type) = match b {
                    BindKind::Filterable => (wgpu::TextureSampleType::Float { filterable: true }, wgpu::SamplerBindingType::Filtering),
                    BindKind::Unfilterable => (wgpu::TextureSampleType::Float { filterable: false }, wgpu::SamplerBindingType::NonFiltering),
                    BindKind::Sint => (wgpu::TextureSampleType::Sint, wgpu::SamplerBindingType::NonFiltering),
                    BindKind::Uint => (wgpu::TextureSampleType::Uint, wgpu::SamplerBindingType::NonFiltering),
                    BindKind::Shadow => (wgpu::TextureSampleType::Depth, wgpu::SamplerBindingType::Comparison),
                };
                let vis = wgpu::ShaderStages::VERTEX_FRAGMENT;
                entries.push(wgpu::BindGroupLayoutEntry { binding: i as u32 * 2, visibility: vis, ty: wgpu::BindingType::Texture { sample_type, view_dimension: dim, multisampled: false }, count: None });
                entries.push(wgpu::BindGroupLayoutEntry { binding: i as u32 * 2 + 1, visibility: vis, ty: wgpu::BindingType::Sampler(sampler_type), count: None });
            }
            let bgl1 = self.device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &entries });
            let bgl0 = l.bgl0.as_ref().ok_or(0u32)?;
            let layouts: Vec<Option<&wgpu::BindGroupLayout>> = match &l.bgl2 {
                Some(b) => vec![Some(bgl0), Some(&bgl1), Some(b)],
                None => vec![Some(bgl0), Some(&bgl1)],
            };
            let pl = self.device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &layouts, immediate_size: 0 });
            l.layouts.insert(key.binds.clone(), (bgl1, pl));
        }
        let vs_module = if key.points {
            let caps = self.caps.clone();
            let device = self.device.clone();
            let m = l.vs_points.get_or_init(|| {
                let (shader, map) = (l.vs_shader.clone(), l.map.clone());
                translate::points_variant(&shader, &map, &caps).ok().and_then(|module| shader_module(&device, module))
            });
            match m {
                Some(m) => m.clone(),
                None => {
                    self.warn("WebGL: this program cannot draw points".to_string());
                    l.pipelines.insert(key.clone(), None);
                    return Ok(None);
                }
            }
        } else {
            l.vs.clone()
        };
        let vertex_attrs: Vec<Vec<wgpu::VertexAttribute>> = key
            .slots
            .iter()
            .map(|s| s.attrs.iter().map(|(format, offset, loc)| wgpu::VertexAttribute { format: *format, offset: *offset as u64, shader_location: *loc }).collect())
            .collect();
        let buffers: Vec<Option<wgpu::VertexBufferLayout<'_>>> = key
            .slots
            .iter()
            .zip(vertex_attrs.iter())
            .map(|(s, a)| Some(wgpu::VertexBufferLayout { array_stride: s.stride as u64, step_mode: if s.instance { wgpu::VertexStepMode::Instance } else { wgpu::VertexStepMode::Vertex }, attributes: a }))
            .collect();
        let blend = key.blend.map(|b| wgpu::BlendState {
            color: wgpu::BlendComponent {
                src_factor: if matches!(b[0], 0x8007 | 0x8008) { wgpu::BlendFactor::One } else { blend_factor(b[2]) },
                dst_factor: if matches!(b[0], 0x8007 | 0x8008) { wgpu::BlendFactor::One } else { blend_factor(b[3]) },
                operation: blend_op(b[0]),
            },
            alpha: wgpu::BlendComponent {
                src_factor: if matches!(b[1], 0x8007 | 0x8008) { wgpu::BlendFactor::One } else { blend_factor(b[4]) },
                dst_factor: if matches!(b[1], 0x8007 | 0x8008) { wgpu::BlendFactor::One } else { blend_factor(b[5]) },
                operation: blend_op(b[1]),
            },
        });
        let features = self.features;
        let targets: Vec<Option<wgpu::ColorTargetState>> = key
            .colors
            .iter()
            .enumerate()
            .map(|(i, c)| {
                c.map(|format| {
                    let blendable = format.guaranteed_format_features(features).flags.contains(wgpu::TextureFormatFeatureFlags::BLENDABLE);
                    let written = l.outputs & (1u32 << i.min(31)) != 0;
                    wgpu::ColorTargetState { format, blend: if blendable { blend } else { None }, write_mask: if written { color_writes(key.color_mask) } else { wgpu::ColorWrites::empty() } }
                })
            })
            .collect();
        let stencil = match key.stencil {
            Some(s) => wgpu::StencilState {
                front: wgpu::StencilFaceState { compare: compare_fn(s[0]), fail_op: stencil_op(s[1]), depth_fail_op: stencil_op(s[2]), pass_op: stencil_op(s[3]) },
                back: wgpu::StencilFaceState { compare: compare_fn(s[4]), fail_op: stencil_op(s[5]), depth_fail_op: stencil_op(s[6]), pass_op: stencil_op(s[7]) },
                read_mask: s[8],
                write_mask: s[9],
            },
            None => wgpu::StencilState::default(),
        };
        let bias = match key.offset {
            Some((f, u)) if key.ds.is_some() => wgpu::DepthBiasState { constant: f32::from_bits(u).clamp(-1e7, 1e7) as i32, slope_scale: f32::from_bits(f), clamp: 0.0 },
            _ => wgpu::DepthBiasState::default(),
        };
        let depth_stencil = key.ds.map(|format| wgpu::DepthStencilState {
            format,
            depth_write_enabled: Some(format.has_depth_aspect() && key.depth.map_or(false, |d| d.0)),
            depth_compare: Some(if format.has_depth_aspect() { key.depth.map_or(wgpu::CompareFunction::Always, |d| compare_fn(d.1)) } else { wgpu::CompareFunction::Always }),
            stencil,
            bias,
        });
        let primitive = wgpu::PrimitiveState {
            topology: key.topology,
            strip_index_format: key.strip_index,
            // the vertex shader flips y: what GL calls counter-clockwise reaches wgpu clockwise
            front_face: if key.front == 0x0901 { wgpu::FrontFace::Cw } else { wgpu::FrontFace::Ccw },
            cull_mode: match key.cull {
                FRONT => Some(wgpu::Face::Front),
                BACK => Some(wgpu::Face::Back),
                _ => None,
            },
            unclipped_depth: false,
            polygon_mode: wgpu::PolygonMode::Fill,
            conservative: false,
        };
        let layout = &l.layouts[&key.binds].1;
        let started = std::time::Instant::now();
        let validation = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let internal = self.device.push_error_scope(wgpu::ErrorFilter::Internal);
        let p = self.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: None,
            layout: Some(layout),
            vertex: wgpu::VertexState { module: &vs_module, entry_point: Some("main"), compilation_options: Default::default(), buffers: &buffers },
            primitive,
            depth_stencil,
            multisample: wgpu::MultisampleState { count: key.samples, mask: !0, alpha_to_coverage_enabled: key.alpha_to_coverage },
            fragment: Some(wgpu::FragmentState { module: &l.fs, entry_point: Some("main"), compilation_options: Default::default(), targets: &targets }),
            multiview_mask: None,
            cache: None,
        });
        let e1 = pollster::block_on(internal.pop());
        let e2 = pollster::block_on(validation.pop());
        if started.elapsed() >= SLOW_PIPELINE {
            self.warn(format!("WebGL: a pipeline took {} ms to compile", started.elapsed().as_millis()));
        }
        let made = if let Some(e) = e1.or(e2) {
            self.warn(format!("WebGL: the device refused a pipeline: {}", e));
            None
        } else {
            Some(p)
        };
        l.pipelines.insert(key.clone(), made.clone());
        Ok(made)
    }

    // ---- reading back ----

    /// Copies a rectangle of a texture to the CPU: (texels, bytes per row). The caller's context is flushed first.
    pub fn read_texture(&mut self, tex: &wgpu::Texture, level: u32, layer: u32, x: u32, y: u32, w: u32, h: u32) -> Option<(Vec<u8>, usize)> {
        let format = tex.format();
        let texel = format.block_copy_size(None)?;
        let bpr = (w * texel + wgpu::COPY_BYTES_PER_ROW_ALIGNMENT - 1) / wgpu::COPY_BYTES_PER_ROW_ALIGNMENT * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let size = bpr as u64 * h as u64;
        if size == 0 {
            return Some((Vec::new(), bpr as usize));
        }
        let staging = self.device.create_buffer(&wgpu::BufferDescriptor { label: None, size, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
        self.end_pass();
        self.ensure_encoder();
        self.encoder.as_mut()?.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo { texture: tex, mip_level: level, origin: wgpu::Origin3d { x, y, z: layer }, aspect: wgpu::TextureAspect::All },
            wgpu::TexelCopyBufferInfo { buffer: &staging, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(bpr), rows_per_image: Some(h) } },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        );
        self.submit();
        let (tx, rx) = std::sync::mpsc::channel();
        staging.slice(..).map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r.is_ok());
        });
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
        if !matches!(rx.try_recv(), Ok(true)) {
            return None;
        }
        let data = staging.slice(..).get_mapped_range().ok()?.to_vec();
        staging.unmap();
        Some((data, bpr as usize))
    }

    /// The texture and place where the read framebuffer's pixels are: (texture, level, layer, format, samples).
    pub fn read_source(&mut self) -> Result<(wgpu::Texture, u32, u32, Fmt, u32, u32, u32), u32> {
        let fb = self.st.read_fb;
        if self.fb_status(fb) != 0x8CD5 {
            return Err(INVALID_FRAMEBUFFER_OPERATION);
        }
        if fb == 0 {
            if fb == self.st.draw_fb && self.needs_clear {
                self.ensure_pass(None);
            } else if self.needs_clear {
                // the default framebuffer is cleared lazily: make it true now
                let saved = self.st.draw_fb;
                self.st.draw_fb = 0;
                self.ensure_pass(None);
                self.end_pass();
                self.st.draw_fb = saved;
            }
            let bb = &self.bb;
            return Ok((bb.color.clone(), 0, 0, Fmt { wgpu: wgpu::TextureFormat::Rgba8Unorm, internal: formats::RGBA, channels: formats::Channels::Same }, bb.w, bb.h, 1));
        }
        let f = self.fbs.get(&fb).ok_or(INVALID_OPERATION)?;
        if f.read_buffer == NONE {
            return Err(INVALID_OPERATION);
        }
        let idx = (f.read_buffer - COLOR_ATTACHMENT0) as usize;
        let Some(a) = f.color.get(idx).copied().flatten() else { return Err(INVALID_OPERATION) };
        let (w, h, fmt, s) = self.attachment_info(&a).ok_or(INVALID_OPERATION)?;
        match a {
            Attach::Tex { id, level, layer } => {
                let t = self.textures.get(&id).ok_or(INVALID_OPERATION)?;
                Ok((t.gpu.clone().ok_or(INVALID_OPERATION)?, level, layer, fmt, w, h, 1))
            }
            Attach::Rb { id } => {
                let r = self.rbs.get(&id).ok_or(INVALID_OPERATION)?;
                Ok((r.gpu.clone().ok_or(INVALID_OPERATION)?, 0, 0, fmt, w, h, s))
            }
        }
    }

    pub fn copy_tex_image(&mut self, target: u32, level: i32, internal: u32, x: i32, y: i32, w: i32, h: i32, border: i32) {
        if !matches!(target, TEXTURE_2D | 0x8515..=0x851A) {
            return self.set_error(INVALID_ENUM);
        }
        if border != 0 || level < 0 || w < 0 || h < 0 {
            return self.set_error(INVALID_VALUE);
        }
        let (bind, face) = if target == TEXTURE_2D { (TEXTURE_2D, 0) } else { (TEXTURE_CUBE_MAP, target - TEXTURE_CUBE_MAP_POSITIVE_X) };
        if bind == TEXTURE_CUBE_MAP && w != h {
            return self.set_error(INVALID_VALUE);
        }
        let Some(id) = self.tex_binding(bind) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        if self.textures[&id].immutable > 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let src = match self.read_source() {
            Ok(s) => s,
            Err(e) => return self.set_error(e),
        };
        // an unsized format takes the framebuffer's kind; RGB and RGBA and friends follow the texture_format table
        let fmt = match internal {
            formats::RGBA | formats::RGB | formats::ALPHA | formats::LUMINANCE | formats::LUMINANCE_ALPHA => formats::texture_format(internal, internal, formats::UNSIGNED_BYTE, false),
            _ => formats::sized_format(internal),
        };
        let Some(fmt) = fmt else { return self.set_error(INVALID_ENUM) };
        if !self.is_webgl2() && matches!(fmt.wgpu, wgpu::TextureFormat::Rgba32Float | wgpu::TextureFormat::Rgba16Float) {
            return self.set_error(INVALID_OPERATION);
        }
        let _ = src;
        if level != 0 && self.textures[&id].gpu.is_some() {
            let t = &self.textures[&id];
            if (t.w >> level).max(1) != w as u32 || (t.h >> level).max(1) != h as u32 {
                return;
            }
        } else if w > 0 && h > 0 {
            if !self.ensure_storage_public(id, fmt, (w as u32) << level, (h as u32) << level) {
                return;
            }
        } else {
            return;
        }
        self.mark_level(id, level as u32, face);
        self.copy_rect_into(id, level as u32, face, 0, 0, x, y, w, h);
    }

    #[allow(clippy::too_many_arguments)]
    pub fn copy_tex_sub_image(&mut self, target: u32, level: i32, xo: i32, yo: i32, zo: i32, x: i32, y: i32, w: i32, h: i32) {
        let (bind, face) = match target {
            TEXTURE_2D => (TEXTURE_2D, 0),
            0x8515..=0x851A => (TEXTURE_CUBE_MAP, target - TEXTURE_CUBE_MAP_POSITIVE_X),
            TEXTURE_3D | TEXTURE_2D_ARRAY => (target, 0),
            _ => return self.set_error(INVALID_ENUM),
        };
        if level < 0 || xo < 0 || yo < 0 || zo < 0 || w < 0 || h < 0 {
            return self.set_error(INVALID_VALUE);
        }
        let Some(id) = self.tex_binding(bind) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let t = &self.textures[&id];
        if t.fmt.is_none() || t.defined[face as usize] & (1 << (level as u32).min(31)) == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let (tw, th) = ((t.w >> level).max(1), (t.h >> level).max(1));
        if xo as u32 + w as u32 > tw || yo as u32 + h as u32 > th {
            return self.set_error(INVALID_VALUE);
        }
        self.copy_rect_into(id, level as u32, if bind == TEXTURE_CUBE_MAP { face } else { zo as u32 }, xo as u32, yo as u32, x, y, w, h);
    }

    /// The part of the read framebuffer's rectangle inside it, into a texture. What is outside stays as it is.
    #[allow(clippy::too_many_arguments)]
    fn copy_rect_into(&mut self, id: u32, level: u32, layer: u32, xo: u32, yo: u32, x: i32, y: i32, w: i32, h: i32) {
        let (src, s_level, s_layer, s_fmt, sw, sh, samples) = match self.read_source() {
            Ok(s) => s,
            Err(e) => return self.set_error(e),
        };
        if samples > 1 {
            return self.set_error(INVALID_OPERATION);
        }
        let (x0, y0) = (x.max(0), y.max(0));
        let (x1, y1) = ((x as i64 + w as i64).min(sw as i64) as i32, (y as i64 + h as i64).min(sh as i64) as i32);
        if x1 <= x0 || y1 <= y0 {
            return;
        }
        let (cw, ch) = ((x1 - x0) as u32, (y1 - y0) as u32);
        let (dx, dy) = (xo + (x0 - x) as u32, yo + (y0 - y) as u32);
        let t = &self.textures[&id];
        let Some(dst_fmt) = t.fmt else { return };
        let Some(dst) = t.gpu.clone() else { return };
        if s_fmt.wgpu == dst_fmt.wgpu && dst_fmt.channels == formats::Channels::Same {
            self.end_pass();
            self.ensure_encoder();
            self.encoder.as_mut().unwrap().copy_texture_to_texture(
                wgpu::TexelCopyTextureInfo { texture: &src, mip_level: s_level, origin: wgpu::Origin3d { x: x0 as u32, y: y0 as u32, z: s_layer }, aspect: wgpu::TextureAspect::All },
                wgpu::TexelCopyTextureInfo { texture: &dst, mip_level: level, origin: wgpu::Origin3d { x: dx, y: dy, z: layer }, aspect: wgpu::TextureAspect::All },
                wgpu::Extent3d { width: cw, height: ch, depth_or_array_layers: 1 },
            );
            self.textures.get_mut(&id).unwrap().used_gen = self.enc_gen;
            return;
        }
        // formats that differ: through the CPU
        let Some((texels, bpr)) = self.read_texture(&src, s_level, s_layer, x0 as u32, y0 as u32, cw, ch) else { return };
        let mut rgba = vec![0u8; cw as usize * ch as usize * 4];
        if !formats::convert_readback(&texels, bpr, s_fmt.wgpu, formats::RGBA, formats::UNSIGNED_BYTE, cw as usize, ch as usize, cw as usize * 4, &mut rgba) {
            return self.set_error(INVALID_OPERATION);
        }
        let u = formats::Unpack::default();
        let Some(px) = formats::convert_image(&rgba, false, &u, formats::RGBA, dst_fmt, cw, ch) else { return self.set_error(INVALID_OPERATION) };
        self.write_texture(id, level, layer, dx, dy, 0, cw, ch, 1, &px);
    }

    /// blitFramebuffer.
    pub fn blit_framebuffer(&mut self, v: [i32; 8], mask: u32, filter: u32) {
        if !matches!(filter, NEAREST | LINEAR) {
            return self.set_error(INVALID_ENUM);
        }
        if mask & !(COLOR_BUFFER_BIT | DEPTH_BUFFER_BIT | STENCIL_BUFFER_BIT) != 0 {
            return self.set_error(INVALID_VALUE);
        }
        if mask & (DEPTH_BUFFER_BIT | STENCIL_BUFFER_BIT) != 0 && filter != NEAREST {
            return self.set_error(INVALID_OPERATION);
        }
        let (rf, df) = (self.st.read_fb, self.st.draw_fb);
        if self.fb_status(rf) != 0x8CD5 || self.fb_status(df) != 0x8CD5 {
            return self.set_error(INVALID_FRAMEBUFFER_OPERATION);
        }
        if mask & COLOR_BUFFER_BIT != 0 {
            self.blit_color(v, filter);
        }
        if mask & (DEPTH_BUFFER_BIT | STENCIL_BUFFER_BIT) != 0 {
            self.blit_depth(v);
        }
    }

    fn blit_color(&mut self, v: [i32; 8], filter: u32) {
        let (src, s_level, s_layer, s_fmt, sw, sh, samples) = match self.read_source() {
            Ok(s) => s,
            Err(e) => return self.set_error(e),
        };
        let df = self.st.draw_fb;
        let Some(dst) = self.target_of(df) else { return };
        if df == 0 && self.needs_clear {
            self.ensure_pass(None);   // (the buffer's lazy clear comes before what is copied onto it)
        }
        let [sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1] = v;
        self.end_pass();
        self.ensure_encoder();
        // a multisampled source resolves first
        let (source, s_level, s_layer) = if samples > 1 {
            let resolved = self.device.create_texture(&wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d { width: sw, height: sh, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: s_fmt.wgpu,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_SRC,
                view_formats: &[],
            });
            let view = src.create_view(&wgpu::TextureViewDescriptor::default());
            let rv = resolved.create_view(&wgpu::TextureViewDescriptor::default());
            drop(self.encoder.as_mut().unwrap().begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment { view: &view, depth_slice: None, resolve_target: Some(&rv), ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store } })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            }));
            (resolved, 0, 0)
        } else {
            (src, s_level, s_layer)
        };
        let same_size = (sx1 - sx0) == (dx1 - dx0) && (sy1 - sy0) == (dy1 - dy0) && sx1 > sx0 && sy1 > sy0;
        // the plain case: a copy to each draw buffer
        for (i, c) in dst.colors.iter().enumerate() {
            let Some((view, resolve, format)) = c else { continue };
            let dest_tex = if df == 0 {
                Some((self.bb.color.clone(), 0, 0))
            } else {
                self.fbs.get(&df).and_then(|f| f.color[i]).and_then(|a| match a {
                    Attach::Tex { id, level, layer } => self.textures.get(&id).and_then(|t| t.gpu.clone()).map(|g| (g, level, layer)),
                    Attach::Rb { id } => self.rbs.get(&id).and_then(|r| r.gpu.clone()).map(|g| (g, 0, 0)),
                })
            };
            let single = dst.samples == 1;
            if same_size && *format == s_fmt.wgpu && single {
                if let Some((d, d_level, d_layer)) = dest_tex {
                    // clipped to both
                    let (x0, y0) = (sx0.max(0), sy0.max(0));
                    let (x1, y1) = (sx1.min(sw as i32), sy1.min(sh as i32));
                    let ox = dx0 + (x0 - sx0);
                    let oy = dy0 + (y0 - sy0);
                    let (w, h) = (x1 - x0, y1 - y0);
                    if w > 0 && h > 0 && ox >= 0 && oy >= 0 && (ox + w) as u32 <= dst.w && (oy + h) as u32 <= dst.h {
                        self.encoder.as_mut().unwrap().copy_texture_to_texture(
                            wgpu::TexelCopyTextureInfo { texture: &source, mip_level: s_level, origin: wgpu::Origin3d { x: x0 as u32, y: y0 as u32, z: s_layer }, aspect: wgpu::TextureAspect::All },
                            wgpu::TexelCopyTextureInfo { texture: &d, mip_level: d_level, origin: wgpu::Origin3d { x: ox as u32, y: oy as u32, z: d_layer }, aspect: wgpu::TextureAspect::All },
                            wgpu::Extent3d { width: w as u32, height: h as u32, depth_or_array_layers: 1 },
                        );
                        continue;
                    }
                }
            }
            // scaled, flipped, or between formats: drawn
            if formats::sample_kind(s_fmt.wgpu) != SampleKind::Float || formats::sample_kind(*format) != SampleKind::Float {
                self.warn("WebGL: this blitFramebuffer is not supported".to_string());
                self.set_error(INVALID_OPERATION);
                return;
            }
            let (w, h) = (source.width().max(1) as f32, source.height().max(1) as f32);
            let rect = [sx0 as f32 / w, sy0 as f32 / h, (sx1 - sx0) as f32 / w, (sy1 - sy0) as f32 / h];
            let src_view = source.create_view(&wgpu::TextureViewDescriptor {
                dimension: Some(wgpu::TextureViewDimension::D2),
                base_mip_level: s_level,
                mip_level_count: Some(1),
                base_array_layer: s_layer,
                array_layer_count: Some(1),
                ..Default::default()
            });
            let view = view.clone();
            let format = *format;
            // a destination with x1 < x0 or y1 < y0 is a flip of the source rectangle
            let (mut r, mut x, mut y, mut ww, mut hh) = (rect, dx0.min(dx1), dy0.min(dy1), (dx1 - dx0).abs(), (dy1 - dy0).abs());
            if dx1 < dx0 {
                r[0] += r[2];
                r[2] = -r[2];
            }
            if dy1 < dy0 {
                r[1] += r[3];
                r[3] = -r[3];
            }
            // clipped to the destination
            let (ox, oy) = (x, y);
            x = x.max(0);
            y = y.max(0);
            ww -= x - ox;
            hh -= y - oy;
            if x as u32 >= dst.w || y as u32 >= dst.h || ww <= 0 || hh <= 0 {
                continue;
            }
            let resolve = resolve.clone();
            self.blit_quad(&src_view, &view, resolve.as_ref(), dst.samples, format, [x as f32, y as f32, ww as f32, hh as f32], r, filter == LINEAR, dst.w, dst.h);
        }
        if df == 0 {
            self.drew_since_present = true;
        }
    }

    fn blit_depth(&mut self, v: [i32; 8]) {
        let (rf, df) = (self.st.read_fb, self.st.draw_fb);
        let attachment_of = |ctx: &Ctx, fb: u32| -> Option<Attach> {
            let f = ctx.fbs.get(&fb)?;
            f.depth.or(f.stencil)
        };
        let (Some(a), Some(b)) = (attachment_of(self, rf), attachment_of(self, df)) else {
            if self.console.len() < 8 {
                self.warn("WebGL: a depth blit to or from the default framebuffer is not supported".to_string());
            }
            return;
        };
        let (Some((aw, ah, af, asamples)), Some((bw, bh, bf, bsamples))) = (self.attachment_info(&a), self.attachment_info(&b)) else { return };
        if af.wgpu != bf.wgpu {
            return self.set_error(INVALID_OPERATION);
        }
        let whole = v[0] == 0 && v[1] == 0 && v[2] == aw as i32 && v[3] == ah as i32 && v[4] == 0 && v[5] == 0 && v[6] == bw as i32 && v[7] == bh as i32 && aw == bw && ah == bh;
        if !whole || asamples != bsamples {
            if self.console.len() < 8 {
                self.warn("WebGL: a depth blit other than a whole copy of the same samples is not supported".to_string());
            }
            return;
        }
        let tex = |ctx: &Ctx, a: &Attach| -> Option<(wgpu::Texture, u32, u32)> {
            match a {
                Attach::Tex { id, level, layer } => ctx.textures.get(id).and_then(|t| t.gpu.clone()).map(|g| (g, *level, *layer)),
                Attach::Rb { id } => ctx.rbs.get(id).and_then(|r| r.gpu.clone()).map(|g| (g, 0, 0)),
            }
        };
        let (Some((s, sl, sz)), Some((d, dl, dz))) = (tex(self, &a), tex(self, &b)) else { return };
        self.end_pass();
        self.ensure_encoder();
        self.encoder.as_mut().unwrap().copy_texture_to_texture(
            wgpu::TexelCopyTextureInfo { texture: &s, mip_level: sl, origin: wgpu::Origin3d { x: 0, y: 0, z: sz }, aspect: wgpu::TextureAspect::All },
            wgpu::TexelCopyTextureInfo { texture: &d, mip_level: dl, origin: wgpu::Origin3d { x: 0, y: 0, z: dz }, aspect: wgpu::TextureAspect::All },
            wgpu::Extent3d { width: aw, height: ah, depth_or_array_layers: 1 },
        );
    }

    /// Draws a texture onto a view.
    #[allow(clippy::too_many_arguments)]
    pub fn blit_quad(&mut self, src: &wgpu::TextureView, dst: &wgpu::TextureView, resolve: Option<&wgpu::TextureView>, samples: u32, format: wgpu::TextureFormat, viewport: [f32; 4], rect: [f32; 4], linear: bool, tw: u32, th: u32) {
        self.end_pass();
        self.ensure_encoder();
        if !self.utility.blit.contains_key(&(format, samples)) {
            let p = self.device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("blit"),
                layout: Some(&self.utility.blit_layout),
                vertex: wgpu::VertexState { module: &self.utility.vs, entry_point: Some("main"), compilation_options: Default::default(), buffers: &[] },
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: None,
                multisample: wgpu::MultisampleState { count: samples, mask: !0, alpha_to_coverage_enabled: false },
                fragment: Some(wgpu::FragmentState { module: &self.utility.blit_fs, entry_point: Some("main"), compilation_options: Default::default(), targets: &[Some(wgpu::ColorTargetState { format, blend: None, write_mask: wgpu::ColorWrites::ALL })] }),
                multiview_mask: None,
                cache: None,
            });
            self.utility.blit.insert((format, samples), p);
        }
        let mut params = [0f32; 12];
        params[0..4].copy_from_slice(&rect);
        let bytes = floats_as_bytes(&params);
        self.ring_room(1024);
        self.ensure_encoder();
        let Ok(at) = self.ring_alloc(&bytes, self.limits.ubo_align) else { return };
        let bg0 = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.utility.params,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: &self.ring, offset: 0, size: wgpu::BufferSize::new(UTILITY_PARAMS) }) }],
        });
        let sampler = if linear { self.utility.linear.clone() } else { self.utility.nearest.clone() };
        let bg1 = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.utility.src,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(src) }, wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&sampler) }],
        });
        let pipeline = self.utility.blit[&(format, samples)].clone();
        let enc = self.encoder.as_mut().unwrap();
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: None,
            color_attachments: &[Some(wgpu::RenderPassColorAttachment { view: dst, depth_slice: None, resolve_target: resolve, ops: wgpu::Operations { load: wgpu::LoadOp::Load, store: wgpu::StoreOp::Store } })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &bg0, &[at]);
        pass.set_bind_group(1, &bg1, &[]);
        pass.set_viewport(viewport[0], viewport[1], viewport[2], viewport[3], 0.0, 1.0);
        let x = viewport[0].max(0.0) as u32;
        let y = viewport[1].max(0.0) as u32;
        let w = (viewport[2] as u32).min(tw.saturating_sub(x));
        let h = (viewport[3] as u32).min(th.saturating_sub(y));
        pass.set_scissor_rect(x, y, w, h);
        pass.draw(0..3, 0..1);
    }

    pub fn ensure_storage_public(&mut self, id: u32, fmt: Fmt, w: u32, h: u32) -> bool {
        self.storage_for_copy(id, fmt, w, h)
    }
}

/// How a draw names its vertices.
#[derive(Clone, Copy)]
pub enum DrawKind {
    Arrays { first: u32, count: u32 },
    Elements { count: u32, ty: u32, bytes: u32, offset: u32, element: u32 },
}

fn color_writes(m: [bool; 4]) -> wgpu::ColorWrites {
    let mut w = wgpu::ColorWrites::empty();
    if m[0] {
        w |= wgpu::ColorWrites::RED;
    }
    if m[1] {
        w |= wgpu::ColorWrites::GREEN;
    }
    if m[2] {
        w |= wgpu::ColorWrites::BLUE;
    }
    if m[3] {
        w |= wgpu::ColorWrites::ALPHA;
    }
    w
}

fn floats_as_bytes(f: &[f32]) -> Vec<u8> {
    let mut v = Vec::with_capacity(f.len() * 4);
    for x in f {
        v.extend_from_slice(&x.to_ne_bytes());
    }
    v
}

/// An identity for a wgpu buffer (they are reference counted, equal when the same).
fn token_of(b: &wgpu::Buffer) -> u32 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    b.hash(&mut h);
    let v = h.finish();
    (v ^ (v >> 32)) as u32 & 0x7FFF_FFFF
}

/// The largest index of a range. The restart value of WebGL 2 does not count.
pub fn max_index(data: &[u8], bytes: u32, webgl2: bool) -> u32 {
    let mut max = 0u32;
    match bytes {
        1 => {
            for b in data {
                max = max.max(*b as u32);
            }
        }
        2 => {
            for c in data.chunks_exact(2) {
                let v = u16::from_ne_bytes([c[0], c[1]]) as u32;
                if webgl2 && v == 0xFFFF {
                    continue;
                }
                max = max.max(v);
            }
        }
        _ => {
            for c in data.chunks_exact(4) {
                let v = u32::from_ne_bytes([c[0], c[1], c[2], c[3]]);
                if webgl2 && v == u32::MAX {
                    continue;
                }
                max = max.max(v);
            }
        }
    }
    max
}

/// Indices for what wgpu has no primitive for: from a list of indices (bytes each) or from `first`..: (data, format, count).
fn generate_indices(mode: u32, source: Option<(&[u8], u32)>, first: u32, count: u32) -> (Vec<u8>, wgpu::IndexFormat, u32) {
    let at = |i: u32| -> u32 {
        match source {
            None => first + i,
            Some((d, 1)) => d[i as usize] as u32,
            Some((d, 2)) => u16::from_ne_bytes([d[i as usize * 2], d[i as usize * 2 + 1]]) as u32,
            Some((d, _)) => u32::from_ne_bytes([d[i as usize * 4], d[i as usize * 4 + 1], d[i as usize * 4 + 2], d[i as usize * 4 + 3]]),
        }
    };
    let mut out: Vec<u32> = Vec::new();
    match mode {
        TRIANGLE_FAN => {
            if count >= 3 {
                out.reserve((count as usize - 2) * 3);
                for i in 1..count - 1 {
                    out.push(at(0));
                    out.push(at(i));
                    out.push(at(i + 1));
                }
            }
        }
        LINE_LOOP => {
            if count >= 2 {
                out.reserve(count as usize + 1);
                for i in 0..count {
                    out.push(at(i));
                }
                out.push(at(0));
            }
        }
        _ => {
            out.reserve(count as usize);
            for i in 0..count {
                out.push(at(i));
            }
        }
    }
    let n = out.len() as u32;
    if out.iter().all(|v| *v < 0xFFFF) {
        let mut d = Vec::with_capacity(out.len() * 2);
        for v in out {
            d.extend_from_slice(&(v as u16).to_ne_bytes());
        }
        (d, wgpu::IndexFormat::Uint16, n)
    } else {
        let mut d = Vec::with_capacity(out.len() * 4);
        for v in out {
            d.extend_from_slice(&v.to_ne_bytes());
        }
        (d, wgpu::IndexFormat::Uint32, n)
    }
}

/// Every mip level of a texture from its first, drawn.
pub fn generate_mipmaps(ctx: &mut Ctx, id: u32) {
    ctx.end_pass();
    let t = &ctx.textures[&id];
    let (Some(gpu), Some(fmt)) = (t.gpu.clone(), t.fmt) else { return };
    let (w0, h0, levels) = (t.w, t.h, t.levels);
    let faces: u32 = match t.target {
        TEXTURE_CUBE_MAP => 6,
        TEXTURE_2D_ARRAY => t.d.max(1),
        _ => 1,
    };
    let base = t.base_level.min(levels.saturating_sub(1));
    for face in 0..faces {
        for level in base + 1..levels {
            let make = |lv: u32| {
                gpu.create_view(&wgpu::TextureViewDescriptor {
                    dimension: Some(wgpu::TextureViewDimension::D2),
                    base_mip_level: lv,
                    mip_level_count: Some(1),
                    base_array_layer: face,
                    array_layer_count: Some(1),
                    ..Default::default()
                })
            };
            let (w, h) = ((w0 >> level).max(1), (h0 >> level).max(1));
            ctx.blit_quad(&make(level - 1), &make(level), None, 1, fmt.wgpu, [0.0, 0.0, w as f32, h as f32], [0.0, 0.0, 1.0, 1.0], true, w, h);
        }
    }
    let enc_gen = ctx.enc_gen;
    let t = ctx.textures.get_mut(&id).unwrap();
    t.used_gen = enc_gen;
    let bits = if levels >= 32 { u32::MAX } else { (1u32 << levels) - 1 };
    for d in t.defined.iter_mut() {
        *d |= bits & !((1u32 << base) - 1);
    }
}
