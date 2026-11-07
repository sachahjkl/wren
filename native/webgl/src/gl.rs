//! One WebGL context on its own wgpu device: the state machine of OpenGL ES over wgpu's objects. Everything a page does arrives
//! here as a stream (ops.rs); what goes wrong is a GL error kept for getError, never a wgpu validation error if this code is
//! right, and if it is not, an error scope around pipelines and the device's error handler lose the context rather than the
//! browser.
//!
//! What GL has and wgpu does not, and what stands for it:
//!   - mutable state over immutable pipelines: a cache of pipelines by the state that makes them (draw.rs);
//!   - draws between uploads: `queue.write_*` runs before the commands of the next submit, so a resource used by the open
//!     encoder is written through the encoder (buffers) or after a submit (textures);
//!   - uniform values: a block per stage per program, copied per draw into a ring bound with dynamic offsets;
//!   - framebuffer rows: stored bottom row first, as GL thinks of them (the vertex shader flips y, front faces swap); a
//!     canvas is flipped when it is shown;
//!   - triangle fans, line loops, byte indices, points: index data generated into the ring, quads for points;
//!   - vertex formats wgpu lacks (3 bytes, integers to float, strides that are not multiples of 4): converted once per
//!     buffer version into a buffer of their own.

use crate::formats::{self, Channels, Fmt, SampleKind, Unpack};
use crate::ops::{self, Reader};
use crate::translate::{self, Caps, LinkMap, Shader, Stage};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

// GL errors
pub const NO_ERROR: u32 = 0;
pub const INVALID_ENUM: u32 = 0x500;
pub const INVALID_VALUE: u32 = 0x501;
pub const INVALID_OPERATION: u32 = 0x502;
pub const OUT_OF_MEMORY: u32 = 0x505;
pub const INVALID_FRAMEBUFFER_OPERATION: u32 = 0x506;

// targets
pub const ARRAY_BUFFER: u32 = 0x8892;
pub const ELEMENT_ARRAY_BUFFER: u32 = 0x8893;
pub const COPY_READ_BUFFER: u32 = 0x8F36;
pub const COPY_WRITE_BUFFER: u32 = 0x8F37;
pub const PIXEL_PACK_BUFFER: u32 = 0x88EB;
pub const PIXEL_UNPACK_BUFFER: u32 = 0x88EC;
pub const TRANSFORM_FEEDBACK_BUFFER: u32 = 0x8C8E;
pub const UNIFORM_BUFFER: u32 = 0x8A11;
pub const TEXTURE_2D: u32 = 0x0DE1;
pub const TEXTURE_3D: u32 = 0x806F;
pub const TEXTURE_2D_ARRAY: u32 = 0x8C1A;
pub const TEXTURE_CUBE_MAP: u32 = 0x8513;
pub const TEXTURE_CUBE_MAP_POSITIVE_X: u32 = 0x8515;
pub const FRAMEBUFFER: u32 = 0x8D40;
pub const READ_FRAMEBUFFER: u32 = 0x8CA8;
pub const DRAW_FRAMEBUFFER: u32 = 0x8CA9;
pub const RENDERBUFFER: u32 = 0x8D41;
pub const COLOR_ATTACHMENT0: u32 = 0x8CE0;
pub const DEPTH_ATTACHMENT: u32 = 0x8D00;
pub const STENCIL_ATTACHMENT: u32 = 0x8D20;
pub const DEPTH_STENCIL_ATTACHMENT: u32 = 0x821A;
pub const NONE: u32 = 0;
pub const BACK: u32 = 0x0405;
pub const FRONT: u32 = 0x0404;
pub const FRONT_AND_BACK: u32 = 0x0408;
pub const COLOR: u32 = 0x1800;
pub const DEPTH: u32 = 0x1801;
pub const STENCIL: u32 = 0x1802;
pub const DEPTH_STENCIL_BUFFER: u32 = 0x84F9;
pub const COLOR_BUFFER_BIT: u32 = 0x4000;
pub const DEPTH_BUFFER_BIT: u32 = 0x100;
pub const STENCIL_BUFFER_BIT: u32 = 0x400;

// capabilities
pub const CULL_FACE: u32 = 0x0B44;
pub const BLEND: u32 = 0x0BE2;
pub const DITHER: u32 = 0x0BD0;
pub const STENCIL_TEST: u32 = 0x0B90;
pub const DEPTH_TEST: u32 = 0x0B71;
pub const SCISSOR_TEST: u32 = 0x0C11;
pub const POLYGON_OFFSET_FILL: u32 = 0x8037;
pub const SAMPLE_ALPHA_TO_COVERAGE: u32 = 0x809E;
pub const SAMPLE_COVERAGE: u32 = 0x80A0;
pub const RASTERIZER_DISCARD: u32 = 0x8C89;
pub const PRIMITIVE_RESTART_FIXED: u32 = 0x8D69;

// texture parameters
pub const TEXTURE_MAG_FILTER: u32 = 0x2800;
pub const TEXTURE_MIN_FILTER: u32 = 0x2801;
pub const TEXTURE_WRAP_S: u32 = 0x2802;
pub const TEXTURE_WRAP_T: u32 = 0x2803;
pub const TEXTURE_WRAP_R: u32 = 0x8072;
pub const TEXTURE_MIN_LOD: u32 = 0x813A;
pub const TEXTURE_MAX_LOD: u32 = 0x813B;
pub const TEXTURE_BASE_LEVEL: u32 = 0x813C;
pub const TEXTURE_MAX_LEVEL: u32 = 0x813D;
pub const TEXTURE_COMPARE_MODE: u32 = 0x884C;
pub const TEXTURE_COMPARE_FUNC: u32 = 0x884D;
pub const TEXTURE_MAX_ANISOTROPY: u32 = 0x84FE;
pub const TEXTURE_IMMUTABLE_FORMAT: u32 = 0x912F;
pub const TEXTURE_IMMUTABLE_LEVELS: u32 = 0x82DF;
pub const NEAREST: u32 = 0x2600;
pub const LINEAR: u32 = 0x2601;
pub const NEAREST_MIPMAP_NEAREST: u32 = 0x2700;
pub const LINEAR_MIPMAP_NEAREST: u32 = 0x2701;
pub const NEAREST_MIPMAP_LINEAR: u32 = 0x2702;
pub const LINEAR_MIPMAP_LINEAR: u32 = 0x2703;
pub const REPEAT: u32 = 0x2901;
pub const CLAMP_TO_EDGE: u32 = 0x812F;
pub const MIRRORED_REPEAT: u32 = 0x8370;
pub const COMPARE_REF_TO_TEXTURE: u32 = 0x884E;

// pixel store
pub const UNPACK_ALIGNMENT: u32 = 0x0CF5;
pub const PACK_ALIGNMENT: u32 = 0x0D05;
pub const UNPACK_FLIP_Y_WEBGL: u32 = 0x9240;
pub const UNPACK_PREMULTIPLY_ALPHA_WEBGL: u32 = 0x9241;
pub const UNPACK_COLORSPACE_CONVERSION_WEBGL: u32 = 0x9243;
pub const BROWSER_DEFAULT_WEBGL: u32 = 0x9244;
pub const UNPACK_ROW_LENGTH: u32 = 0x0CF2;
pub const UNPACK_IMAGE_HEIGHT: u32 = 0x806E;
pub const UNPACK_SKIP_ROWS: u32 = 0x0CF3;
pub const UNPACK_SKIP_PIXELS: u32 = 0x0CF4;
pub const UNPACK_SKIP_IMAGES: u32 = 0x806D;
pub const PACK_ROW_LENGTH: u32 = 0x0D02;
pub const PACK_SKIP_ROWS: u32 = 0x0D03;
pub const PACK_SKIP_PIXELS: u32 = 0x0D04;

/// Why an image of a page cannot exceed this in one dimension, whatever the device says.
pub const MAX_TEXTURE_SIZE_CAP: u32 = 16384;
pub const MAX_3D_TEXTURE_SIZE_CAP: u32 = 2048;
pub const MAX_ARRAY_LAYERS_CAP: u32 = 2048;
/// Bytes of GPU memory one context may hold in buffers and textures (accounting, a soft limit); `limits.max_bytes` overrides it.
pub const DEFAULT_MAX_BYTES: u64 = 4 << 30;
/// The ring of uniform values and generated indices, per submit.
pub const RING_BYTES: usize = 32 << 20;
/// A submit no later than this many draws (long frames would hold everything back).
pub const MAX_DRAWS_PER_SUBMIT: u32 = 20_000;
/// Antialiasing of a context that asks for it.
pub const ANTIALIAS_SAMPLES: u32 = 4;
/// Vertex attribute slots GL exposes.
pub const MAX_ATTRIBS: usize = 16;
pub const MAX_COLOR_ATTACHMENTS: usize = 8;
pub const MAX_TEXTURE_UNITS: usize = 32;
pub const MAX_UNIFORM_BUFFER_BINDINGS: usize = 24;
/// The largest point a shader may ask for.
pub const MAX_POINT_SIZE: f32 = 256.0;
/// Pipelines and bind groups kept per program before the cache starts over.
pub const MAX_CACHED_BIND_GROUPS: usize = 1024;
pub const MAX_CACHED_PIPELINES: usize = 4096;
/// Texture bytes above which a draw with a converted stream is refused rather than converted.
pub const MAX_CONVERTED_STREAM_BYTES: usize = 256 << 20;
/// How many GL errors go to the page's console, per context.
pub const MAX_ERRORS_TOLD: u32 = 32;
/// How many staging buffers of canvas size are kept for showing the canvas.
pub const FRAME_POOL: usize = 4;
/// The most samples any adapter is said to have; more from a GPU process is not believed.
pub const MAX_REPORTED_SAMPLES: u32 = 64;

/// What getContext was given.
#[derive(Clone, Copy, Debug)]
pub struct Attrs {
    pub webgl2: bool,
    pub alpha: bool,
    pub depth: bool,
    pub stencil: bool,
    pub antialias: bool,
    pub premultiplied: bool,
    pub preserve: bool,
    pub width: u32,
    pub height: u32,
    pub max_bytes: u64,
    pub max_dimension: u32,
    pub force_software: bool,
    pub backend: i32,
}

/// Set from other threads: the device is gone or an error got out.
#[derive(Default)]
pub struct Flags {
    /// Operations done so far, and whether the context's thread is inside a message: how the browser tells work from a hang.
    pub ops: std::sync::atomic::AtomicU64,
    pub busy: AtomicBool,
    pub device_lost: AtomicBool,
    pub validation_failed: AtomicBool,
    pub out_of_memory: AtomicBool,
}

pub struct Reply {
    pub data: Vec<u8>,
    /// Pixels to copy into the caller's buffer at an offset, row by row, leaving what is outside untouched: (first, row bytes, stride).
    pub rows: Option<(usize, usize, usize)>,
}

impl Reply {
    pub fn empty() -> Reply {
        Reply { data: Vec::new(), rows: None }
    }
    pub fn tag(tag: u32) -> Reply {
        let mut r = Reply::empty();
        r.u(tag);
        r
    }
    pub fn u(&mut self, v: u32) {
        self.data.extend_from_slice(&v.to_ne_bytes());
    }
    pub fn int(v: i32) -> Reply {
        let mut r = Reply::tag(ops::TAG_INT);
        r.u(v as u32);
        r
    }
    pub fn uint(v: u32) -> Reply {
        let mut r = Reply::tag(ops::TAG_UINT);
        r.u(v);
        r
    }
    pub fn float(v: f32) -> Reply {
        let mut r = Reply::tag(ops::TAG_FLOAT);
        r.u(v.to_bits());
        r
    }
    pub fn boolean(v: bool) -> Reply {
        let mut r = Reply::tag(ops::TAG_BOOL);
        r.u(v as u32);
        r
    }
    pub fn null() -> Reply {
        Reply::tag(ops::TAG_NULL)
    }
    pub fn ints(v: &[i32]) -> Reply {
        let mut r = Reply::tag(ops::TAG_INTS);
        r.u(v.len() as u32);
        for x in v {
            r.u(*x as u32);
        }
        r
    }
    pub fn uints(v: &[u32]) -> Reply {
        let mut r = Reply::tag(ops::TAG_UINTS);
        r.u(v.len() as u32);
        for x in v {
            r.u(*x);
        }
        r
    }
    pub fn floats(v: &[f32]) -> Reply {
        let mut r = Reply::tag(ops::TAG_FLOATS);
        r.u(v.len() as u32);
        for x in v {
            r.u(x.to_bits());
        }
        r
    }
    pub fn bools(v: &[bool]) -> Reply {
        let mut r = Reply::tag(ops::TAG_BOOLS);
        r.u(v.len() as u32);
        for x in v {
            r.u(*x as u32);
        }
        r
    }
    pub fn string(s: &str) -> Reply {
        let mut r = Reply::tag(ops::TAG_STRING);
        r.u(s.len() as u32);
        r.data.extend_from_slice(s.as_bytes());
        r
    }
    pub fn object(kind: u32, id: u32) -> Reply {
        if id == 0 {
            return Reply::null();
        }
        let mut r = Reply::tag(ops::TAG_OBJECT);
        r.u(kind);
        r.u(id);
        r
    }
}

pub struct Buf {
    pub gpu: Option<wgpu::Buffer>,
    pub shadow: Vec<u8>,
    pub used_gen: u64,
    pub version: u64,
    /// ARRAY_BUFFER or ELEMENT_ARRAY_BUFFER once bound; WebGL forbids a buffer being both.
    pub kind: u32,
    pub usage: u32,
    pub deleted: bool,
    /// The largest index in a range of this buffer, for (offset, count, type), while its content does not change.
    pub max_index: HashMap<(u32, u32, u32), u32>,
    /// Vertex streams converted to what wgpu reads, by what describes them.
    pub converted: HashMap<(u32, u32, bool, u32, u32), (wgpu::Buffer, wgpu::VertexFormat, u32)>,
    /// Vertex attributes with a divisor above 1, written out per instance: by (offset, stride, size, divisor, instances).
    pub expanded: HashMap<(u32, u32, u32, u32, u32), (wgpu::Buffer, u32)>,
    /// Transform feedback wrote to the GPU's copy: the shadow is behind it (capture.rs, buffer_sync).
    pub gpu_newer: bool,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct SamplerState {
    pub min: u32,
    pub mag: u32,
    pub wrap_s: u32,
    pub wrap_t: u32,
    pub wrap_r: u32,
    pub compare_mode: u32,
    pub compare_func: u32,
    pub min_lod: u32, // bits of f32
    pub max_lod: u32,
    pub anisotropy: u32, // bits of f32
}

impl Default for SamplerState {
    fn default() -> Self {
        SamplerState {
            min: NEAREST_MIPMAP_LINEAR,
            mag: LINEAR,
            wrap_s: REPEAT,
            wrap_t: REPEAT,
            wrap_r: REPEAT,
            compare_mode: NONE,
            compare_func: 0x0203, // LEQUAL
            min_lod: (-1000.0f32).to_bits(),
            max_lod: 1000.0f32.to_bits(),
            anisotropy: 1.0f32.to_bits(),
        }
    }
}

pub struct Tex {
    pub target: u32,
    pub gpu: Option<wgpu::Texture>,
    pub fmt: Option<Fmt>,
    pub w: u32,
    pub h: u32,
    pub d: u32,
    pub levels: u32,
    pub immutable: u32,
    /// A bit per level, per layer group: all layers of a level (cube faces separately).
    pub defined: [u32; 6],
    pub params: SamplerState,
    pub base_level: u32,
    pub max_level: u32,
    pub used_gen: u64,
    pub generation: u64,
    pub views: HashMap<(u8, u32, u32), wgpu::TextureView>,
    pub deleted: bool,
    pub bytes: u64,
}

pub struct Rb {
    pub gpu: Option<wgpu::Texture>,
    pub view: Option<wgpu::TextureView>,
    pub fmt: Option<Fmt>,
    pub w: u32,
    pub h: u32,
    pub samples: u32,
    pub generation: u64,
    pub used_gen: u64,
    pub deleted: bool,
    pub bytes: u64,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Attach {
    Tex { id: u32, level: u32, layer: u32 },
    Rb { id: u32 },
}

#[derive(Clone)]
pub struct Fb {
    pub color: [Option<Attach>; MAX_COLOR_ATTACHMENTS],
    pub depth: Option<Attach>,
    pub stencil: Option<Attach>,
    pub draw_buffers: [u32; MAX_COLOR_ATTACHMENTS],
    pub read_buffer: u32,
    pub deleted: bool,
}

impl Default for Fb {
    fn default() -> Self {
        let mut draw_buffers = [NONE; MAX_COLOR_ATTACHMENTS];
        draw_buffers[0] = COLOR_ATTACHMENT0;
        Fb { color: [None; MAX_COLOR_ATTACHMENTS], depth: None, stencil: None, draw_buffers, read_buffer: COLOR_ATTACHMENT0, deleted: false }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Attr {
    pub enabled: bool,
    pub buffer: u32,
    pub size: u32,
    pub ty: u32,
    pub normalized: bool,
    pub integer: bool,
    pub stride: u32,
    pub offset: u32,
    pub divisor: u32,
}

impl Default for Attr {
    fn default() -> Self {
        Attr { enabled: false, buffer: 0, size: 4, ty: formats::FLOAT, normalized: false, integer: false, stride: 0, offset: 0, divisor: 0 }
    }
}

#[derive(Clone)]
pub struct Vao {
    pub attrs: [Attr; MAX_ATTRIBS],
    pub element: u32,
    pub deleted: bool,
}

impl Default for Vao {
    fn default() -> Self {
        Vao { attrs: [Attr::default(); MAX_ATTRIBS], element: 0, deleted: false }
    }
}

pub struct ShaderObj {
    pub stage: Stage,
    pub source: String,
    pub compiled: Option<Rc<Shader>>,
    pub log: String,
    pub deleted: bool,
    pub attached: u32,
}

#[derive(Clone, Debug)]
pub struct UniformInfo {
    pub name: String,
    pub ty: translate::BasicType,
    pub count: u32,
    pub vs: Option<(u32, u32)>,
    pub fs: Option<(u32, u32)>,
    /// A sampler: the first binding index (`count` of them, or 1).
    pub sampler: Option<u32>,
    /// A member of a block of uniforms (no location): (the block's index, offset, array stride, matrix stride).
    pub block: Option<(u32, u32, u32, u32)>,
}

#[derive(Clone, Copy, Debug)]
pub struct Location {
    pub uniform: u32,
    pub element: u32,
}

/// What a sampler of a program is bound as: decided per draw by the texture there.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum BindKind {
    Filterable,
    Unfilterable,
    Sint,
    Uint,
    Shadow,
}

pub struct Linked {
    pub vs: wgpu::ShaderModule,
    pub vs_points: std::cell::OnceCell<Option<wgpu::ShaderModule>>,
    pub fs: wgpu::ShaderModule,
    pub vs_shader: Rc<Shader>,
    pub map: LinkMap,
    pub attributes: Vec<(String, translate::BasicType, u32, u32, bool)>,
    pub uniforms: Vec<UniformInfo>,
    pub locations: Vec<Location>,
    pub names: HashMap<String, u32>,
    pub vs_image: Vec<u8>,
    pub fs_image: Vec<u8>,
    pub vs_dirty: bool,
    pub fs_dirty: bool,
    pub vs_at: u32,
    pub fs_at: u32,
    pub ring_epoch: u64,
    /// Per binding index: its view's dimension, what kind of sampler the shader says, and the texture unit it reads.
    pub sampler_dims: Vec<(wgpu::TextureViewDimension, SampleKind, bool)>,
    pub sampler_units: Vec<u32>,
    pub blocks: Vec<translate::BlockInfo>,
    pub block_bindings: Vec<u32>,
    pub stage_blocks: Vec<u32>,
    pub bgl0: Option<wgpu::BindGroupLayout>,
    pub bg0: Option<wgpu::BindGroup>,
    pub bgl2: Option<wgpu::BindGroupLayout>,
    pub layouts: HashMap<Vec<BindKind>, (wgpu::BindGroupLayout, wgpu::PipelineLayout)>,
    pub pipelines: HashMap<crate::draw::PipelineKey, Option<wgpu::RenderPipeline>>,
    pub tex_groups: HashMap<Vec<u64>, wgpu::BindGroup>,
    pub block_groups: HashMap<Vec<u64>, wgpu::BindGroup>,
    pub outputs: u32,
    pub int_outputs: u32,
    pub tf: crate::capture::TfProgram,
}

pub struct Program {
    pub vs: u32,
    pub fs: u32,
    pub bound: HashMap<String, u32>,
    pub linked: Option<Linked>,
    pub log: String,
    pub link_status: bool,
    pub validate_status: bool,
    pub deleted: bool,
    pub use_count: u32,
    pub generation: u32,
    /// transformFeedbackVaryings: what the next link captures.
    pub tf_names: Vec<String>,
    pub tf_mode: u32,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct StencilFace {
    pub func: u32,
    pub reference: i32,
    pub read_mask: u32,
    pub write_mask: u32,
    pub fail: u32,
    pub zfail: u32,
    pub zpass: u32,
}

impl Default for StencilFace {
    fn default() -> Self {
        StencilFace { func: 0x0207, reference: 0, read_mask: 0xFFFF_FFFF, write_mask: 0xFFFF_FFFF, fail: 0x1E00, zfail: 0x1E00, zpass: 0x1E00 }
    }
}

pub struct State {
    pub active_unit: u32,
    pub tex_2d: [u32; MAX_TEXTURE_UNITS],
    pub tex_cube: [u32; MAX_TEXTURE_UNITS],
    pub tex_3d: [u32; MAX_TEXTURE_UNITS],
    pub tex_array: [u32; MAX_TEXTURE_UNITS],
    pub samplers: [u32; MAX_TEXTURE_UNITS],
    pub array_buffer: u32,
    pub copy_read: u32,
    pub copy_write: u32,
    pub pixel_pack: u32,
    pub pixel_unpack: u32,
    pub tf_buffer: u32,
    pub tf_bound: u32,
    pub occlusion_query: u32,
    pub tf_query: u32,
    pub uniform_buffer: u32,
    pub ubo_ranges: [(u32, u64, u64); MAX_UNIFORM_BUFFER_BINDINGS],
    pub vao: u32,
    pub draw_fb: u32,
    pub read_fb: u32,
    pub renderbuffer: u32,
    pub program: u32,
    pub viewport: [i32; 4],
    pub scissor: [i32; 4],
    pub depth_range: [f32; 2],
    pub clear_color: [f32; 4],
    pub clear_depth: f32,
    pub clear_stencil: i32,
    pub color_mask: [bool; 4],
    pub depth_mask: bool,
    pub blend: bool,
    pub cull: bool,
    pub depth_test: bool,
    pub stencil_test: bool,
    pub scissor_test: bool,
    pub polygon_offset: bool,
    pub alpha_to_coverage: bool,
    pub sample_coverage: bool,
    pub dither: bool,
    pub rasterizer_discard: bool,
    pub blend_color: [f32; 4],
    pub blend_eq: [u32; 2],
    pub blend_func: [u32; 4],
    pub cull_face: u32,
    pub front_face: u32,
    pub depth_func: u32,
    pub stencil_front: StencilFace,
    pub stencil_back: StencilFace,
    pub polygon_factor: f32,
    pub polygon_units: f32,
    pub line_width: f32,
    pub coverage: (f32, bool),
    pub unpack: Unpack,
    pub pack_alignment: u32,
    pub pack_row_length: u32,
    pub pack_skip_rows: u32,
    pub pack_skip_pixels: u32,
    pub colorspace: u32,
    pub generate_mipmap_hint: u32,
    pub derivative_hint: u32,
    pub generic: [[u32; 4]; MAX_ATTRIBS],
    pub generic_kind: [u8; MAX_ATTRIBS],
}

/// The extensions a page enabled (getExtension), and what the device has.
#[derive(Clone, Copy, Default, Debug)]
pub struct Ext {
    pub element_index_uint: bool,
    pub standard_derivatives: bool,
    pub vao: bool,
    pub instanced: bool,
    pub texture_float: bool,
    pub texture_half_float: bool,
    pub texture_float_linear: bool,
    pub texture_half_float_linear: bool,
    pub blend_minmax: bool,
    pub depth_texture: bool,
    pub anisotropic: bool,
    pub frag_depth: bool,
    pub shader_texture_lod: bool,
    pub srgb: bool,
    pub color_buffer_float: bool,
    pub color_buffer_half_float: bool,
    pub draw_buffers: bool,
    pub s3tc: bool,
}

/// The default framebuffer's textures.
pub struct Backbuffer {
    pub color: wgpu::Texture,
    pub color_view: wgpu::TextureView,
    pub msaa_view: Option<wgpu::TextureView>,
    pub depth: Option<wgpu::Texture>,
    pub depth_view: Option<wgpu::TextureView>,
    pub w: u32,
    pub h: u32,
    pub format_ds: Option<wgpu::TextureFormat>,
}

/// A canvas frame on its way to the CPU.
pub struct FrameRead {
    pub buffer: wgpu::Buffer,
    pub mapped: Arc<AtomicBool>,
    pub failed: Arc<AtomicBool>,
    pub w: u32,
    pub h: u32,
    pub bpr: u32,
}

pub struct Limits {
    pub max_texture: u32,
    pub max_cube: u32,
    pub max_3d: u32,
    pub max_array_layers: u32,
    pub max_renderbuffer: u32,
    pub max_uniform_block: u32,
    pub max_samples: u32,
    pub max_anisotropy: f32,
    pub max_vertex_buffers: u32,
    pub ubo_align: u32,
}

pub struct Ctx {
    pub device: wgpu::Device,
    pub queue: wgpu::Queue,
    pub attrs: Attrs,
    pub caps: Caps,
    pub features: wgpu::Features,
    pub limits: Limits,
    pub flags: Arc<Flags>,
    pub ext: Ext,

    pub st: State,
    pub buffers: HashMap<u32, Buf>,
    pub textures: HashMap<u32, Tex>,
    pub rbs: HashMap<u32, Rb>,
    pub fbs: HashMap<u32, Fb>,
    pub vaos: HashMap<u32, Vao>,
    pub shaders: HashMap<u32, ShaderObj>,
    pub programs: HashMap<u32, Program>,
    pub sampler_objs: HashMap<u32, SamplerState>,
    pub error: u32,
    pub errors_pending: Vec<u32>,
    pub console: Vec<String>,

    pub bb: Backbuffer,
    pub needs_clear: bool,
    pub drew_since_present: bool,
    pub fb_gen: u64,

    pub encoder: Option<wgpu::CommandEncoder>,
    pub pass: Option<wgpu::RenderPass<'static>>,
    pub pass_fb: Option<u32>,
    pub enc_gen: u64,
    pub draws_in_submit: u32,
    pub belt: wgpu::util::StagingBelt,
    pub ring: wgpu::Buffer,
    pub ring_cpu: Vec<u8>,
    pub ring_epoch: u64,

    pub cur: crate::draw::PassState,
    pub samplers: HashMap<SamplerState, (wgpu::Sampler, u64)>,
    pub next_token: u64,
    pub fallback: HashMap<(wgpu::TextureViewDimension, BindKind), (wgpu::TextureView, u64)>,
    pub utility: crate::draw::Utility,
    pub bytes: u64,
    pub frames_free: Vec<wgpu::Buffer>,
    pub fallback_group: Option<(wgpu::BindGroupLayout, wgpu::BindGroup)>,
    pub errors_told: u32,
    pub tf_objects: HashMap<u32, crate::capture::TfObject>,
    pub queries: HashMap<u32, crate::capture::QueryObj>,
    pub occlusion: crate::capture::Occlusion,
    pub capture_target: Option<wgpu::TextureView>,
}

fn error_name(code: u32) -> &'static str {
    match code {
        INVALID_ENUM => "INVALID_ENUM",
        INVALID_VALUE => "INVALID_VALUE",
        INVALID_OPERATION => "INVALID_OPERATION",
        OUT_OF_MEMORY => "OUT_OF_MEMORY",
        INVALID_FRAMEBUFFER_OPERATION => "INVALID_FRAMEBUFFER_OPERATION",
        _ => "an error",
    }
}

fn base_limits(adapter: &wgpu::Adapter) -> wgpu::Limits {
    adapter.limits()
}

impl Ctx {
    /// A context with the device it was given and the device's own shaders. Err: nothing could be made of it (the page's getContext gives null).
    pub fn new(device: wgpu::Device, queue: wgpu::Queue, adapter: &wgpu::Adapter, utility: crate::draw::Utility, attrs: Attrs, flags: Arc<Flags>) -> Result<Ctx, String> {
        let lim = base_limits(adapter);
        let max_dim = attrs.max_dimension.max(1);
        let features = device.features();
        let limits = Limits {
            max_texture: lim.max_texture_dimension_2d.min(MAX_TEXTURE_SIZE_CAP).min(max_dim),
            max_cube: lim.max_texture_dimension_2d.min(MAX_TEXTURE_SIZE_CAP).min(max_dim),
            max_3d: lim.max_texture_dimension_3d.min(MAX_3D_TEXTURE_SIZE_CAP),
            max_array_layers: lim.max_texture_array_layers.min(MAX_ARRAY_LAYERS_CAP),
            max_renderbuffer: lim.max_texture_dimension_2d.min(MAX_TEXTURE_SIZE_CAP).min(max_dim),
            max_uniform_block: lim.max_uniform_buffer_binding_size.min(1 << 16) as u32,
            max_samples: if adapter.get_texture_format_features(wgpu::TextureFormat::Rgba8Unorm).flags.contains(wgpu::TextureFormatFeatureFlags::MULTISAMPLE_X4) { ANTIALIAS_SAMPLES } else { 1 },
            max_anisotropy: 16.0,
            max_vertex_buffers: lim.max_vertex_buffers,
            ubo_align: lim.min_uniform_buffer_offset_alignment.max(16),
        };
        let caps = Caps {
            webgl2: attrs.webgl2,
            standard_derivatives: attrs.webgl2,
            frag_depth: attrs.webgl2,
            shader_texture_lod: attrs.webgl2,
            draw_buffers: attrs.webgl2,
            max_vertex_attribs: (lim.max_vertex_attributes as usize).min(MAX_ATTRIBS) as u32,
            max_vertex_uniform_vectors: (limits.max_uniform_block / 16).min(4096) - 1,
            max_varying_vectors: lim.max_inter_stage_shader_variables.min(16) - 1,
            max_vertex_texture_units: lim.max_sampled_textures_per_shader_stage.min(16),
            max_combined_texture_units: (lim.max_sampled_textures_per_shader_stage.min(16) * 2).min(MAX_TEXTURE_UNITS as u32),
            max_texture_units: lim.max_sampled_textures_per_shader_stage.min(16),
            max_fragment_uniform_vectors: (limits.max_uniform_block / 16).min(4096),
            max_draw_buffers: if attrs.webgl2 { lim.max_color_attachments.min(MAX_COLOR_ATTACHMENTS as u32) } else { 1 },
        };
        let (w, h) = (attrs.width.min(limits.max_texture), attrs.height.min(limits.max_texture));
        let samples = if attrs.antialias { limits.max_samples } else { 1 };
        let bb = make_backbuffer(&device, w, h, attrs.depth, attrs.stencil, samples);
        let ring = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("wren webgl ring"),
            size: RING_BYTES as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::INDEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let belt = wgpu::util::StagingBelt::new(device.clone(), 1 << 20);
        let st = State {
            active_unit: 0,
            tex_2d: [0; MAX_TEXTURE_UNITS],
            tex_cube: [0; MAX_TEXTURE_UNITS],
            tex_3d: [0; MAX_TEXTURE_UNITS],
            tex_array: [0; MAX_TEXTURE_UNITS],
            samplers: [0; MAX_TEXTURE_UNITS],
            array_buffer: 0,
            copy_read: 0,
            copy_write: 0,
            pixel_pack: 0,
            pixel_unpack: 0,
            tf_buffer: 0,
            tf_bound: 0,
            occlusion_query: 0,
            tf_query: 0,
            uniform_buffer: 0,
            ubo_ranges: [(0, 0, 0); MAX_UNIFORM_BUFFER_BINDINGS],
            vao: 0,
            draw_fb: 0,
            read_fb: 0,
            renderbuffer: 0,
            program: 0,
            viewport: [0, 0, w as i32, h as i32],
            scissor: [0, 0, w as i32, h as i32],
            depth_range: [0.0, 1.0],
            clear_color: [0.0; 4],
            clear_depth: 1.0,
            clear_stencil: 0,
            color_mask: [true; 4],
            depth_mask: true,
            blend: false,
            cull: false,
            depth_test: false,
            stencil_test: false,
            scissor_test: false,
            polygon_offset: false,
            alpha_to_coverage: false,
            sample_coverage: false,
            dither: true,
            rasterizer_discard: false,
            blend_color: [0.0; 4],
            blend_eq: [0x8006, 0x8006],
            blend_func: [1, 0, 1, 0],
            cull_face: BACK,
            front_face: 0x0901,
            depth_func: 0x0201,
            stencil_front: StencilFace::default(),
            stencil_back: StencilFace::default(),
            polygon_factor: 0.0,
            polygon_units: 0.0,
            line_width: 1.0,
            coverage: (1.0, false),
            unpack: Unpack::default(),
            pack_alignment: 4,
            pack_row_length: 0,
            pack_skip_rows: 0,
            pack_skip_pixels: 0,
            colorspace: BROWSER_DEFAULT_WEBGL,
            generate_mipmap_hint: 0x1100,
            derivative_hint: 0x1100,
            generic: [[0, 0, 0, 1f32.to_bits()]; MAX_ATTRIBS],
            generic_kind: [0; MAX_ATTRIBS],
        };
        let mut vaos = HashMap::new();
        vaos.insert(0, Vao::default());
        let mut ctx = Ctx {
            device,
            queue,
            attrs,
            caps,
            features,
            limits,
            flags,
            ext: Ext::default(),
            st,
            buffers: HashMap::new(),
            textures: HashMap::new(),
            rbs: HashMap::new(),
            fbs: HashMap::new(),
            vaos,
            shaders: HashMap::new(),
            programs: HashMap::new(),
            sampler_objs: HashMap::new(),
            error: NO_ERROR,
            errors_pending: Vec::new(),
            console: Vec::new(),
            bb,
            needs_clear: true,
            drew_since_present: false,
            fb_gen: 1,
            encoder: None,
            pass: None,
            pass_fb: None,
            enc_gen: 1,
            draws_in_submit: 0,
            belt,
            ring,
            ring_cpu: Vec::with_capacity(1 << 16),
            ring_epoch: 1,
            cur: crate::draw::PassState::default(),
            samplers: HashMap::new(),
            next_token: 1,
            fallback: HashMap::new(),
            utility,
            bytes: 0,
            frames_free: Vec::new(),
            fallback_group: None,
            tf_objects: HashMap::new(),
            queries: HashMap::new(),
            occlusion: Default::default(),
            capture_target: None,
            errors_told: 0,
        };
        if ctx.attrs.webgl2 {
            ctx.ext.standard_derivatives = true;
            ctx.ext.element_index_uint = true;
            ctx.ext.vao = true;
            ctx.ext.instanced = true;
            ctx.ext.blend_minmax = true;
            ctx.ext.depth_texture = true;
            ctx.ext.frag_depth = true;
            ctx.ext.shader_texture_lod = true;
            ctx.ext.texture_float = true;
            ctx.ext.texture_half_float = true;
            ctx.ext.srgb = true;
            ctx.ext.draw_buffers = true;
            ctx.ext.texture_half_float_linear = true;
        }
        Ok(ctx)
    }

    pub fn set_error(&mut self, code: u32) {
        if self.error == NO_ERROR {
            self.error = code;
        } else if !self.errors_pending.contains(&code) && code != self.error {
            self.errors_pending.push(code);
        }
    }

    /// Something for the page's console.
    pub fn warn(&mut self, text: String) {
        if self.console.len() < 64 {
            self.console.push(text);
        }
    }

    pub fn take_error(&mut self) -> u32 {
        let e = self.error;
        self.error = if self.errors_pending.is_empty() { NO_ERROR } else { self.errors_pending.remove(0) };
        e
    }

    pub fn is_webgl2(&self) -> bool {
        self.attrs.webgl2
    }

    pub fn current_vao(&mut self) -> &mut Vao {
        let id = self.st.vao;
        self.vaos.entry(id).or_default()
    }

    /// The buffer id bound at a target; None: not a target of this version.
    pub fn buffer_binding(&mut self, target: u32) -> Option<u32> {
        Some(match target {
            ARRAY_BUFFER => self.st.array_buffer,
            ELEMENT_ARRAY_BUFFER => self.current_vao().element,
            COPY_READ_BUFFER if self.is_webgl2() => self.st.copy_read,
            COPY_WRITE_BUFFER if self.is_webgl2() => self.st.copy_write,
            PIXEL_PACK_BUFFER if self.is_webgl2() => self.st.pixel_pack,
            PIXEL_UNPACK_BUFFER if self.is_webgl2() => self.st.pixel_unpack,
            TRANSFORM_FEEDBACK_BUFFER if self.is_webgl2() => self.st.tf_buffer,
            UNIFORM_BUFFER if self.is_webgl2() => self.st.uniform_buffer,
            _ => return None,
        })
    }

    fn set_buffer_binding(&mut self, target: u32, id: u32) {
        match target {
            ARRAY_BUFFER => self.st.array_buffer = id,
            ELEMENT_ARRAY_BUFFER => self.current_vao().element = id,
            COPY_READ_BUFFER => self.st.copy_read = id,
            COPY_WRITE_BUFFER => self.st.copy_write = id,
            PIXEL_PACK_BUFFER => self.st.pixel_pack = id,
            PIXEL_UNPACK_BUFFER => self.st.pixel_unpack = id,
            TRANSFORM_FEEDBACK_BUFFER => self.st.tf_buffer = id,
            UNIFORM_BUFFER => self.st.uniform_buffer = id,
            _ => {}
        }
    }

    pub fn tex_binding(&self, target: u32) -> Option<u32> {
        let u = self.st.active_unit as usize;
        Some(match target {
            TEXTURE_2D => self.st.tex_2d[u],
            TEXTURE_CUBE_MAP => self.st.tex_cube[u],
            TEXTURE_3D if self.attrs.webgl2 => self.st.tex_3d[u],
            TEXTURE_2D_ARRAY if self.attrs.webgl2 => self.st.tex_array[u],
            _ => return None,
        })
    }

    /// (the bind target, the cube face) of a target texImage names.
    fn image_target(&self, target: u32) -> Option<(u32, u32)> {
        match target {
            TEXTURE_2D => Some((TEXTURE_2D, 0)),
            TEXTURE_CUBE_MAP_POSITIVE_X..=0x851A => Some((TEXTURE_CUBE_MAP, target - TEXTURE_CUBE_MAP_POSITIVE_X)),
            TEXTURE_3D | TEXTURE_2D_ARRAY if self.attrs.webgl2 => Some((target, 0)),
            _ => None,
        }
    }

    // ---- the stream ----

    /// Runs a batch. Err: the stream itself is bad (not from our script): the context stops.
    pub fn exec(&mut self, data: &[u8]) -> Result<(), String> {
        let mut r = Reader::new(data);
        while !r.done() {
            let op = r.u().ok_or("truncated")?;
            self.flags.ops.fetch_add(1, Ordering::Relaxed);
            let before = (self.error, self.errors_pending.len());
            self.step(op, &mut r).ok_or_else(|| format!("malformed command {op}"))?;
            if (self.error, self.errors_pending.len()) != before && self.errors_told < MAX_ERRORS_TOLD && op != ops::ERROR {
                self.errors_told += 1;
                let code = self.errors_pending.last().copied().unwrap_or(self.error);
                self.warn(format!("WebGL: {} in {}", error_name(code), ops::name(op)));
            }
            if self.draws_in_submit >= MAX_DRAWS_PER_SUBMIT {
                self.submit();
            }
            if self.flags.device_lost.load(Ordering::Relaxed) {
                return Err("the device was lost".to_string());
            }
        }
        Ok(())
    }

    fn step(&mut self, op: u32, r: &mut Reader<'_>) -> Option<()> {
        match op {
            ops::ACTIVE_TEXTURE => {
                let t = r.u()?;
                let n = t.wrapping_sub(0x84C0);
                if n as usize >= (self.caps.max_combined_texture_units as usize).min(MAX_TEXTURE_UNITS) {
                    self.set_error(INVALID_ENUM);
                } else {
                    self.st.active_unit = n;
                }
            }
            ops::ATTACH_SHADER => {
                let (p, s) = (r.u()?, r.u()?);
                self.attach_shader(p, s);
            }
            ops::DETACH_SHADER => {
                let (p, s) = (r.u()?, r.u()?);
                self.detach_shader(p, s);
            }
            ops::BIND_ATTRIB_LOCATION => {
                let (p, i) = (r.u()?, r.u()?);
                let name = r.bytes()?;
                self.bind_attrib_location(p, i, String::from_utf8_lossy(name).into_owned());
            }
            ops::BIND_BUFFER => {
                let (t, id) = (r.u()?, r.u()?);
                self.bind_buffer(t, id);
            }
            ops::BIND_FRAMEBUFFER => {
                let (t, id) = (r.u()?, r.u()?);
                match t {
                    FRAMEBUFFER => {
                        self.st.draw_fb = id;
                        self.st.read_fb = id;
                    }
                    READ_FRAMEBUFFER if self.is_webgl2() => self.st.read_fb = id,
                    DRAW_FRAMEBUFFER if self.is_webgl2() => self.st.draw_fb = id,
                    _ => return self.err(INVALID_ENUM),
                }
                if id != 0 {
                    self.fbs.entry(id).or_default();
                }
                self.fb_gen += 1;
            }
            ops::BIND_RENDERBUFFER => {
                let (t, id) = (r.u()?, r.u()?);
                if t != RENDERBUFFER {
                    return self.err(INVALID_ENUM);
                }
                self.st.renderbuffer = id;
                if id != 0 {
                    self.rbs.entry(id).or_insert_with(new_rb);
                }
            }
            ops::BIND_TEXTURE => {
                let (t, id) = (r.u()?, r.u()?);
                self.bind_texture(t, id);
            }
            ops::BLEND_COLOR => {
                self.st.blend_color = [r.f()?, r.f()?, r.f()?, r.f()?];
            }
            ops::BLEND_EQUATION => {
                let (a, b) = (r.u()?, r.u()?);
                let minmax = self.ext.blend_minmax;
                let ok = |e: u32| matches!(e, 0x8006 | 0x800A | 0x800B) || (minmax && matches!(e, 0x8007 | 0x8008));
                if !ok(a) || !ok(b) {
                    return self.err(INVALID_ENUM);
                }
                self.st.blend_eq = [a, b];
            }
            ops::BLEND_FUNC => {
                let f = [r.u()?, r.u()?, r.u()?, r.u()?];
                let ok_src = |e: u32| matches!(e, 0 | 1 | 0x300..=0x308 | 0x8001..=0x8004);
                if !f.iter().all(|e| ok_src(*e)) || f[1] == 0x308 && !self.is_webgl2() && false {
                    return self.err(INVALID_ENUM);
                }
                let c1 = |x: u32| matches!(x, 0x8001 | 0x8002);
                let c2 = |x: u32| matches!(x, 0x8003 | 0x8004);
                if (c1(f[0]) && c2(f[1])) || (c2(f[0]) && c1(f[1])) || (c1(f[2]) && c2(f[3])) || (c2(f[2]) && c1(f[3])) {
                    return self.err(INVALID_OPERATION);
                }
                self.st.blend_func = f;
            }
            ops::BUFFER_DATA => {
                let (t, usage, size, has) = (r.u()?, r.u()?, r.u()?, r.u()?);
                let d = r.bytes()?;
                self.buffer_data(t, usage, size as usize, if has != 0 { Some(d) } else { None });
            }
            ops::BUFFER_SUB_DATA => {
                let (t, off) = (r.u()?, r.u()?);
                let d = r.bytes()?;
                self.buffer_sub_data(t, off as usize, d);
            }
            ops::CLEAR => {
                let m = r.u()?;
                self.gl_clear(m);
            }
            ops::CLEAR_COLOR => self.st.clear_color = [r.f()?, r.f()?, r.f()?, r.f()?],
            ops::CLEAR_DEPTH => self.st.clear_depth = r.f()?.clamp(0.0, 1.0),
            ops::CLEAR_STENCIL => self.st.clear_stencil = r.i()?,
            ops::COLOR_MASK => self.st.color_mask = [r.u()? != 0, r.u()? != 0, r.u()? != 0, r.u()? != 0],
            ops::COMPILE_SHADER => {
                let id = r.u()?;
                self.compile_shader(id);
            }
            ops::SHADER_SOURCE => {
                let (id, stage) = (r.u()?, r.u()?);
                let s = r.bytes()?;
                self.shader_source(id, stage, s);
            }
            ops::COMPRESSED_TEX_IMAGE => {
                let (t, level, internal, w, h, d, border, is3d) = (r.u()?, r.i()?, r.u()?, r.i()?, r.i()?, r.i()?, r.i()?, r.u()?);
                let data = r.bytes()?;
                self.compressed_tex_image(t, level, internal, w, h, d, border, is3d != 0, data);
            }
            ops::COMPRESSED_TEX_SUB_IMAGE => {
                let (t, level, x, y, z, w, h, d, format) = (r.u()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.u()?);
                let data = r.bytes()?;
                self.compressed_tex_sub_image(t, level, x, y, z, w, h, d, format, data);
            }
            ops::COPY_TEX_IMAGE => {
                let (t, level, internal, x, y, w, h, border) = (r.u()?, r.i()?, r.u()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?);
                self.copy_tex_image(t, level, internal, x, y, w, h, border);
            }
            ops::COPY_TEX_SUB_IMAGE => {
                let (t, level, xo, yo, x, y, w, h) = (r.u()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?);
                self.copy_tex_sub_image(t, level, xo, yo, 0, x, y, w, h);
            }
            ops::COPY_TEX_SUB_IMAGE_3D => {
                let (t, level, xo, yo, zo, x, y, w, h) = (r.u()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?);
                self.copy_tex_sub_image(t, level, xo, yo, zo, x, y, w, h);
            }
            ops::DELETE_BUFFER => {
                let id = r.u()?;
                self.delete_buffer(id);
            }
            ops::DELETE_FRAMEBUFFER => {
                let id = r.u()?;
                self.fbs.remove(&id);
                if self.st.draw_fb == id {
                    self.st.draw_fb = 0;
                }
                if self.st.read_fb == id {
                    self.st.read_fb = 0;
                }
                self.fb_gen += 1;
            }
            ops::DELETE_PROGRAM => {
                let id = r.u()?;
                self.delete_program(id);
            }
            ops::DELETE_RENDERBUFFER => {
                let id = r.u()?;
                self.end_pass();
                if let Some(rb) = self.rbs.remove(&id) {
                    self.bytes = self.bytes.saturating_sub(rb.bytes);
                }
                if self.st.renderbuffer == id {
                    self.st.renderbuffer = 0;
                }
                self.detach_everywhere(|a| matches!(a, Attach::Rb { id: i } if *i == id));
            }
            ops::DELETE_SHADER => {
                let id = r.u()?;
                self.delete_shader(id);
            }
            ops::DELETE_TEXTURE => {
                let id = r.u()?;
                self.delete_texture(id);
            }
            ops::CULL_FACE => {
                let m = r.u()?;
                if !matches!(m, FRONT | BACK | FRONT_AND_BACK) {
                    return self.err(INVALID_ENUM);
                }
                self.st.cull_face = m;
            }
            ops::DEPTH_FUNC => {
                let m = r.u()?;
                if !(0x200..=0x207).contains(&m) {
                    return self.err(INVALID_ENUM);
                }
                self.st.depth_func = m;
            }
            ops::DEPTH_MASK => self.st.depth_mask = r.u()? != 0,
            ops::DEPTH_RANGE => {
                let (a, b) = (r.f()?, r.f()?);
                if a > b {
                    return self.err(INVALID_OPERATION);
                }
                self.st.depth_range = [a.clamp(0.0, 1.0), b.clamp(0.0, 1.0)];
            }
            ops::DISABLE | ops::ENABLE => {
                let cap = r.u()?;
                self.set_cap(cap, op == ops::ENABLE);
            }
            ops::DISABLE_ATTRIB | ops::ENABLE_ATTRIB => {
                let i = r.u()?;
                if i >= self.caps.max_vertex_attribs {
                    return self.err(INVALID_VALUE);
                }
                self.current_vao().attrs[i as usize].enabled = op == ops::ENABLE_ATTRIB;
            }
            ops::DRAW_ARRAYS => {
                let (m, first, count, inst) = (r.u()?, r.i()?, r.i()?, r.i()?);
                self.draw_arrays(m, first, count, inst);
            }
            ops::DRAW_ELEMENTS => {
                let (m, count, ty, off, inst) = (r.u()?, r.i()?, r.u()?, r.i()?, r.i()?);
                self.draw_elements(m, count, ty, off as i64, inst);
            }
            ops::FRAMEBUFFER_RENDERBUFFER => {
                let (t, a, rt, id) = (r.u()?, r.u()?, r.u()?, r.u()?);
                self.framebuffer_renderbuffer(t, a, rt, id);
            }
            ops::FRAMEBUFFER_TEXTURE => {
                let (t, a, tt, id, level) = (r.u()?, r.u()?, r.u()?, r.u()?, r.i()?);
                self.framebuffer_texture(t, a, tt, id, level);
            }
            ops::FRAMEBUFFER_TEXTURE_LAYER => {
                let (t, a, id, level, layer) = (r.u()?, r.u()?, r.u()?, r.i()?, r.i()?);
                self.framebuffer_texture_layer(t, a, id, level, layer);
            }
            ops::FRONT_FACE => {
                let m = r.u()?;
                if !matches!(m, 0x0900 | 0x0901) {
                    return self.err(INVALID_ENUM);
                }
                self.st.front_face = m;
            }
            ops::GENERATE_MIPMAP => {
                let t = r.u()?;
                self.generate_mipmap(t);
            }
            ops::HINT => {
                let (t, m) = (r.u()?, r.u()?);
                if !matches!(m, 0x1100 | 0x1101 | 0x1102) {
                    return self.err(INVALID_ENUM);
                }
                match t {
                    0x8192 => self.st.generate_mipmap_hint = m,
                    0x8B8B if self.ext.standard_derivatives => self.st.derivative_hint = m,
                    _ => return self.err(INVALID_ENUM),
                }
            }
            ops::LINE_WIDTH => {
                let w = r.f()?;
                if w <= 0.0 || w.is_nan() {
                    return self.err(INVALID_VALUE);
                }
                self.st.line_width = w;
            }
            ops::LINK_PROGRAM => {
                let id = r.u()?;
                self.link_program(id);
            }
            ops::PIXEL_STOREI => {
                let (p, v) = (r.u()?, r.i()?);
                self.pixel_store(p, v);
            }
            ops::POLYGON_OFFSET => {
                self.st.polygon_factor = r.f()?;
                self.st.polygon_units = r.f()?;
            }
            ops::RENDERBUFFER_STORAGE => {
                let (t, internal, w, h, samples) = (r.u()?, r.u()?, r.i()?, r.i()?, r.i()?);
                self.renderbuffer_storage(t, internal, w, h, samples);
            }
            ops::SAMPLE_COVERAGE => {
                let (v, inv) = (r.f()?, r.u()?);
                self.st.coverage = (v.clamp(0.0, 1.0), inv != 0);
            }
            ops::SCISSOR => {
                let b = [r.i()?, r.i()?, r.i()?, r.i()?];
                if b[2] < 0 || b[3] < 0 {
                    return self.err(INVALID_VALUE);
                }
                self.st.scissor = b;
            }
            ops::STENCIL_FUNC => {
                let (face, func, reference, mask) = (r.u()?, r.u()?, r.i()?, r.u()?);
                if !(0x200..=0x207).contains(&func) || !matches!(face, FRONT | BACK | FRONT_AND_BACK) {
                    return self.err(INVALID_ENUM);
                }
                if face != BACK {
                    self.st.stencil_front.func = func;
                    self.st.stencil_front.reference = reference;
                    self.st.stencil_front.read_mask = mask;
                }
                if face != FRONT {
                    self.st.stencil_back.func = func;
                    self.st.stencil_back.reference = reference;
                    self.st.stencil_back.read_mask = mask;
                }
            }
            ops::STENCIL_MASK => {
                let (face, mask) = (r.u()?, r.u()?);
                if !matches!(face, FRONT | BACK | FRONT_AND_BACK) {
                    return self.err(INVALID_ENUM);
                }
                if face != BACK {
                    self.st.stencil_front.write_mask = mask;
                }
                if face != FRONT {
                    self.st.stencil_back.write_mask = mask;
                }
            }
            ops::STENCIL_OP => {
                let (face, a, b, c) = (r.u()?, r.u()?, r.u()?, r.u()?);
                let ok = |e: u32| matches!(e, 0 | 0x1E00 | 0x1E01 | 0x1E02 | 0x1E03 | 0x150A | 0x8507 | 0x8508);
                if !ok(a) || !ok(b) || !ok(c) || !matches!(face, FRONT | BACK | FRONT_AND_BACK) {
                    return self.err(INVALID_ENUM);
                }
                if face != BACK {
                    self.st.stencil_front.fail = a;
                    self.st.stencil_front.zfail = b;
                    self.st.stencil_front.zpass = c;
                }
                if face != FRONT {
                    self.st.stencil_back.fail = a;
                    self.st.stencil_back.zfail = b;
                    self.st.stencil_back.zpass = c;
                }
            }
            ops::TEX_IMAGE => {
                let (t, level, internal, w, h, d, border, format, ty, has, is3d) = (r.u()?, r.i()?, r.u()?, r.i()?, r.i()?, r.i()?, r.i()?, r.u()?, r.u()?, r.u()?, r.u()?);
                let pbo_off = r.u()?;
                let data = r.bytes()?;
                self.tex_image(t, level, internal, w, h, d, border, format, ty, if has == 1 { Some(data) } else { None }, has == 2, pbo_off as usize, is3d != 0);
            }
            ops::TEX_SUB_IMAGE => {
                let (t, level, x, y, z, w, h, d, format, ty, is3d, has) = (r.u()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.u()?, r.u()?, r.u()?, r.u()?);
                let pbo_off = r.u()?;
                let data = r.bytes()?;
                self.tex_sub_image(t, level, x, y, z, w, h, d, format, ty, if has == 1 { Some(data) } else { None }, has == 2, pbo_off as usize, is3d != 0);
            }
            ops::TEX_IMAGE_SOURCE => {
                let (sw, sh, premult, t, level, internal, format, ty, sub, x, y, z) = (r.i()?, r.i()?, r.u()?, r.u()?, r.i()?, r.u()?, r.u()?, r.u()?, r.u()?, r.i()?, r.i()?, r.i()?);
                let data = r.bytes()?;
                self.tex_image_source(sw, sh, premult != 0, t, level, internal, format, ty, sub != 0, x, y, z, data);
            }
            ops::TEX_PARAMETER_I => {
                let (t, p, v) = (r.u()?, r.u()?, r.i()?);
                self.tex_parameter(t, p, v as f32, v as u32);
            }
            ops::TEX_PARAMETER_F => {
                let (t, p, v) = (r.u()?, r.u()?, r.f()?);
                self.tex_parameter(t, p, v, v as i64 as u32);
            }
            ops::UNIFORM => {
                let (loc, kind, count) = (r.i()?, r.u()?, r.u()?);
                let data = r.bytes()?;
                self.uniform(loc, kind, count, data);
            }
            ops::USE_PROGRAM => {
                let id = r.u()?;
                self.use_program(id);
            }
            ops::VERTEX_ATTRIB => {
                let (i, kind) = (r.u()?, r.u()?);
                let v = [r.u()?, r.u()?, r.u()?, r.u()?];
                if i >= self.caps.max_vertex_attribs {
                    return self.err(INVALID_VALUE);
                }
                self.st.generic[i as usize] = v;
                self.st.generic_kind[i as usize] = kind as u8;
            }
            ops::VERTEX_ATTRIB_POINTER => {
                let (i, size, ty, norm, stride, offset, integer) = (r.u()?, r.i()?, r.u()?, r.u()?, r.i()?, r.u()?, r.u()?);
                self.vertex_attrib_pointer(i, size, ty, norm != 0, stride, offset, integer != 0);
            }
            ops::VERTEX_ATTRIB_DIVISOR => {
                let (i, d) = (r.u()?, r.u()?);
                if i >= self.caps.max_vertex_attribs {
                    return self.err(INVALID_VALUE);
                }
                self.current_vao().attrs[i as usize].divisor = d;
            }
            ops::VIEWPORT => {
                let b = [r.i()?, r.i()?, r.i()?, r.i()?];
                if b[2] < 0 || b[3] < 0 {
                    return self.err(INVALID_VALUE);
                }
                self.st.viewport = b;
            }
            ops::BIND_VAO => {
                let id = r.u()?;
                self.st.vao = id;
                self.vaos.entry(id).or_default();
            }
            ops::DELETE_VAO => {
                let id = r.u()?;
                if id != 0 {
                    self.vaos.remove(&id);
                    if self.st.vao == id {
                        self.st.vao = 0;
                    }
                }
            }
            ops::ERROR => {
                let c = r.u()?;
                self.set_error(c);
            }
            ops::BLIT_FRAMEBUFFER => {
                let v = [r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?, r.i()?];
                let (mask, filter) = (r.u()?, r.u()?);
                self.blit_framebuffer(v, mask, filter);
            }
            ops::READ_BUFFER => {
                let m = r.u()?;
                self.read_buffer(m);
            }
            ops::DRAW_BUFFERS => {
                let n = r.u()? as usize;
                if n > 64 {
                    return None;
                }
                let mut list = Vec::with_capacity(n);
                for _ in 0..n {
                    list.push(r.u()?);
                }
                self.draw_buffers(&list);
            }
            ops::CLEAR_BUFFER => {
                let (buffer, index, kind) = (r.u()?, r.i()?, r.u()?);
                let v = [r.u()?, r.u()?, r.u()?, r.u()?];
                self.clear_buffer(buffer, index, kind, v);
            }
            ops::BIND_BUFFER_RANGE => {
                let (t, index, id, off, size) = (r.u()?, r.u()?, r.u()?, r.u()?, r.u()?);
                self.bind_buffer_range(t, index, id, off as u64, size as u64);
            }
            ops::TF_VARYINGS => {
                let (p, mode) = (r.u()?, r.u()?);
                let names = r.bytes()?;
                self.tf_varyings(p, mode, names);
            }
            ops::BIND_TF => {
                let (t, id) = (r.u()?, r.u()?);
                self.bind_tf(t, id);
            }
            ops::BEGIN_TF => {
                let mode = r.u()?;
                self.begin_tf(mode);
            }
            ops::END_TF => self.end_tf(),
            ops::PAUSE_TF => self.pause_tf(),
            ops::RESUME_TF => self.resume_tf(),
            ops::DELETE_TF => {
                let id = r.u()?;
                self.delete_tf(id);
            }
            ops::BEGIN_QUERY => {
                let (t, id) = (r.u()?, r.u()?);
                self.begin_query(t, id);
            }
            ops::END_QUERY => {
                let t = r.u()?;
                self.end_query(t);
            }
            ops::DELETE_QUERY => {
                let id = r.u()?;
                self.delete_query(id);
            }
            ops::UNIFORM_BLOCK_BINDING => {
                let (p, index, binding) = (r.u()?, r.u()?, r.u()?);
                self.uniform_block_binding(p, index, binding);
            }
            ops::TEX_STORAGE => {
                let (t, levels, internal, w, h, d, is3d) = (r.u()?, r.i()?, r.u()?, r.i()?, r.i()?, r.i()?, r.u()?);
                self.tex_storage(t, levels, internal, w, h, d, is3d != 0);
            }
            ops::COPY_BUFFER_SUB_DATA => {
                let (rt, wt, ro, wo, size) = (r.u()?, r.u()?, r.u()?, r.u()?, r.u()?);
                self.copy_buffer_sub_data(rt, wt, ro as usize, wo as usize, size as usize);
            }
            ops::BIND_SAMPLER => {
                let (unit, id) = (r.u()?, r.u()?);
                if unit as usize >= MAX_TEXTURE_UNITS {
                    return self.err(INVALID_VALUE);
                }
                self.st.samplers[unit as usize] = id;
                if id != 0 {
                    self.sampler_objs.entry(id).or_default();
                }
            }
            ops::DELETE_SAMPLER => {
                let id = r.u()?;
                self.sampler_objs.remove(&id);
                for s in &mut self.st.samplers {
                    if *s == id {
                        *s = 0;
                    }
                }
            }
            ops::SAMPLER_PARAMETER_I => {
                let (id, p, v) = (r.u()?, r.u()?, r.i()?);
                self.sampler_parameter(id, p, v as f32, v as u32);
            }
            ops::SAMPLER_PARAMETER_F => {
                let (id, p, v) = (r.u()?, r.u()?, r.f()?);
                self.sampler_parameter(id, p, v, v as i64 as u32);
            }
            ops::ENABLE_EXTENSION => {
                let e = r.u()?;
                self.enable_extension(e);
            }
            _ => return None,
        }
        Some(())
    }

    fn err(&mut self, code: u32) -> Option<()> {
        self.set_error(code);
        Some(())
    }

    fn enable_extension(&mut self, e: u32) {
        let x = &mut self.ext;
        match e {
            1 => x.element_index_uint = true,
            2 => {
                x.standard_derivatives = true;
                self.caps.standard_derivatives = true;
            }
            3 => x.vao = true,
            4 => x.instanced = true,
            5 => x.texture_float = true,
            6 => x.texture_half_float = true,
            7 => x.texture_float_linear = true,
            8 => x.texture_half_float_linear = true,
            9 => x.blend_minmax = true,
            10 => x.depth_texture = true,
            11 => x.anisotropic = true,
            12 => {
                x.frag_depth = true;
                self.caps.frag_depth = true;
            }
            13 => {
                x.shader_texture_lod = true;
                self.caps.shader_texture_lod = true;
            }
            14 => x.srgb = true,
            15 => x.color_buffer_float = true,
            16 => x.color_buffer_half_float = true,
            17 => {
                x.draw_buffers = true;
                self.caps.draw_buffers = true;
                self.caps.max_draw_buffers = self.device.limits().max_color_attachments.min(MAX_COLOR_ATTACHMENTS as u32);
            }
            18 => x.s3tc = true,
            _ => {}
        }
    }

    fn set_cap(&mut self, cap: u32, on: bool) {
        match cap {
            CULL_FACE => self.st.cull = on,
            BLEND => self.st.blend = on,
            DITHER => self.st.dither = on,
            STENCIL_TEST => self.st.stencil_test = on,
            DEPTH_TEST => self.st.depth_test = on,
            SCISSOR_TEST => self.st.scissor_test = on,
            POLYGON_OFFSET_FILL => self.st.polygon_offset = on,
            SAMPLE_ALPHA_TO_COVERAGE => self.st.alpha_to_coverage = on,
            SAMPLE_COVERAGE => self.st.sample_coverage = on,
            RASTERIZER_DISCARD if self.is_webgl2() => self.st.rasterizer_discard = on,
            PRIMITIVE_RESTART_FIXED if self.is_webgl2() => {}
            _ => self.set_error(INVALID_ENUM),
        }
    }

    fn pixel_store(&mut self, p: u32, v: i32) {
        let alignment_ok = matches!(v, 1 | 2 | 4 | 8);
        let w2 = self.is_webgl2();
        let u = &mut self.st.unpack;
        match p {
            UNPACK_ALIGNMENT => {
                if alignment_ok {
                    u.alignment = v as u32
                } else {
                    self.set_error(INVALID_VALUE)
                }
            }
            PACK_ALIGNMENT => {
                if alignment_ok {
                    self.st.pack_alignment = v as u32
                } else {
                    self.set_error(INVALID_VALUE)
                }
            }
            UNPACK_FLIP_Y_WEBGL => u.flip_y = v != 0,
            UNPACK_PREMULTIPLY_ALPHA_WEBGL => u.premultiply = v != 0,
            UNPACK_COLORSPACE_CONVERSION_WEBGL => {
                if v as u32 == BROWSER_DEFAULT_WEBGL || v == 0 {
                    self.st.colorspace = v as u32
                } else {
                    self.set_error(INVALID_ENUM)
                }
            }
            UNPACK_ROW_LENGTH | UNPACK_IMAGE_HEIGHT | UNPACK_SKIP_ROWS | UNPACK_SKIP_PIXELS | UNPACK_SKIP_IMAGES | PACK_ROW_LENGTH | PACK_SKIP_ROWS | PACK_SKIP_PIXELS if w2 => {
                if v < 0 {
                    self.set_error(INVALID_VALUE);
                    return;
                }
                let v = v as u32;
                match p {
                    UNPACK_ROW_LENGTH => u.row_length = v,
                    UNPACK_IMAGE_HEIGHT => u.image_height = v,
                    UNPACK_SKIP_ROWS => u.skip_rows = v,
                    UNPACK_SKIP_PIXELS => u.skip_pixels = v,
                    UNPACK_SKIP_IMAGES => u.skip_images = v,
                    PACK_ROW_LENGTH => self.st.pack_row_length = v,
                    PACK_SKIP_ROWS => self.st.pack_skip_rows = v,
                    _ => self.st.pack_skip_pixels = v,
                }
            }
            _ => self.set_error(INVALID_ENUM),
        }
    }

    // ---- buffers ----

    fn bind_buffer(&mut self, target: u32, id: u32) {
        if self.buffer_binding(target).is_none() {
            return self.set_error(INVALID_ENUM);
        }
        if id != 0 {
            let w2 = self.is_webgl2();
            let b = self.buffers.entry(id).or_insert_with(new_buf);
            let kind = if target == ELEMENT_ARRAY_BUFFER { ELEMENT_ARRAY_BUFFER } else { ARRAY_BUFFER };
            if !w2 || matches!(target, ARRAY_BUFFER | ELEMENT_ARRAY_BUFFER) {
                if b.kind != 0 && b.kind != kind {
                    return self.set_error(INVALID_OPERATION);
                }
            }
            if b.kind == 0 && matches!(target, ARRAY_BUFFER | ELEMENT_ARRAY_BUFFER) {
                b.kind = kind;
            } else if b.kind == 0 {
                b.kind = kind;
            }
        }
        self.set_buffer_binding(target, id);
    }

    fn buffer_data(&mut self, target: u32, usage: u32, size: usize, data: Option<&[u8]>) {
        let Some(id) = self.buffer_binding(target) else { return self.set_error(INVALID_ENUM) };
        if !matches!(usage, 0x88E0 | 0x88E4 | 0x88E8 | 0x88E1 | 0x88E2 | 0x88E5 | 0x88E6 | 0x88E9 | 0x88EA) {
            return self.set_error(INVALID_ENUM);
        }
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let size = data.map_or(size, |d| d.len());
        let old = self.buffers.get(&id).map_or(0, |b| b.shadow.len()) as u64;
        // (the shadow and the GPU's copy are charged)
        if self.bytes.saturating_sub(2 * old).saturating_add(2 * size as u64) > self.attrs.max_bytes {
            return self.set_error(OUT_OF_MEMORY);
        }
        self.bytes = self.bytes.saturating_sub(2 * old) + 2 * size as u64;
        let device = self.device.clone();
        let queue = self.queue.clone();
        let Some(b) = self.buffers.get_mut(&id) else { return };
        b.usage = usage;
        b.version += 1;
        b.max_index.clear();
        b.converted.clear();
        b.expanded.clear();
        // a new buffer: what the open encoder uses keeps the old one (and its contents)
        let mut shadow = Vec::new();
        if shadow.try_reserve_exact(size).is_err() {
            self.bytes = self.bytes.saturating_sub(2 * size as u64);
            return self.set_error(OUT_OF_MEMORY);
        }
        match data {
            Some(d) => shadow.extend_from_slice(d),
            None => shadow.resize(size, 0),
        }
        b.shadow = shadow;
        b.used_gen = 0;
        let gpu_size = ((size as u64 + 3) & !3).max(4);
        let gpu = device.create_buffer(&wgpu::BufferDescriptor { label: None, size: gpu_size, usage: buffer_usages(), mapped_at_creation: false });
        if data.is_some() && size > 0 {
            if size % 4 == 0 {
                queue.write_buffer(&gpu, 0, &b.shadow);
            } else {
                let mut padded = b.shadow.clone();
                padded.resize(gpu_size as usize, 0);
                queue.write_buffer(&gpu, 0, &padded);
            }
        }
        b.gpu = Some(gpu);
    }

    fn buffer_sub_data(&mut self, target: u32, off: usize, data: &[u8]) {
        let Some(id) = self.buffer_binding(target) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        self.buffer_sync(id);
        let Some(b) = self.buffers.get_mut(&id) else { return self.set_error(INVALID_OPERATION) };
        let Some(end) = off.checked_add(data.len()) else { return self.set_error(INVALID_VALUE) };
        if end > b.shadow.len() {
            return self.set_error(INVALID_VALUE);
        }
        if data.is_empty() {
            return;
        }
        b.shadow[off..end].copy_from_slice(data);
        b.version += 1;
        b.max_index.clear();
        b.converted.clear();
        b.expanded.clear();
        self.write_buffer_range(id, off, end);
    }

    /// Sends a range of a buffer's shadow to its GPU copy, in order with what is recorded.
    pub fn write_buffer_range(&mut self, id: u32, off: usize, end: usize) {
        let a = off & !3;
        let z = ((end + 3) & !3).min(self.buffers[&id].shadow.len().div_ceil(4) * 4);
        let used = self.buffers[&id].used_gen == self.enc_gen;
        if used {
            self.end_pass();
            self.ensure_encoder();
            let enc = self.encoder.as_mut().unwrap();
            let b = self.buffers.get_mut(&id).unwrap();
            let Some(gpu) = &b.gpu else { return };
            let size = (z - a) as u64;
            let Some(nz) = wgpu::BufferSize::new(size) else { return };
            let mut view = self.belt.write_buffer(enc, gpu, a as u64, nz);
            let have = b.shadow.len().min(z);
            view.slice(..have - a).copy_from_slice(&b.shadow[a..have]);
            drop(view);
        } else {
            let b = &self.buffers[&id];
            let Some(gpu) = &b.gpu else { return };
            if z <= b.shadow.len() {
                self.queue.write_buffer(gpu, a as u64, &b.shadow[a..z]);
            } else {
                let mut tmp = b.shadow[a..].to_vec();
                tmp.resize(z - a, 0);
                self.queue.write_buffer(gpu, a as u64, &tmp);
            }
        }
    }

    fn copy_buffer_sub_data(&mut self, rt: u32, wt: u32, ro: usize, wo: usize, size: usize) {
        let (Some(a), Some(b)) = (self.buffer_binding(rt), self.buffer_binding(wt)) else { return self.set_error(INVALID_ENUM) };
        if a == 0 || b == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        self.buffer_sync(a);
        self.buffer_sync(b);
        let la = self.buffers.get(&a).map_or(0, |x| x.shadow.len());
        let lb = self.buffers.get(&b).map_or(0, |x| x.shadow.len());
        if ro.saturating_add(size) > la || wo.saturating_add(size) > lb {
            return self.set_error(INVALID_VALUE);
        }
        if a == b && ro < wo + size && wo < ro + size {
            return self.set_error(INVALID_VALUE);
        }
        if size == 0 {
            return;
        }
        let chunk = self.buffers[&a].shadow[ro..ro + size].to_vec();
        let t = self.buffers.get_mut(&b).unwrap();
        t.shadow[wo..wo + size].copy_from_slice(&chunk);
        t.version += 1;
        t.max_index.clear();
        t.converted.clear();
        t.expanded.clear();
        self.write_buffer_range(b, wo, wo + size);
    }

    fn delete_buffer(&mut self, id: u32) {
        if let Some(b) = self.buffers.remove(&id) {
            self.bytes = self.bytes.saturating_sub(2 * b.shadow.len() as u64);
        }
        let s = &mut self.st;
        for b in [&mut s.array_buffer, &mut s.copy_read, &mut s.copy_write, &mut s.pixel_pack, &mut s.pixel_unpack, &mut s.tf_buffer, &mut s.uniform_buffer] {
            if *b == id {
                *b = 0;
            }
        }
        for r in &mut s.ubo_ranges {
            if r.0 == id {
                *r = (0, 0, 0);
            }
        }
        let cur = self.st.vao;
        if let Some(v) = self.vaos.get_mut(&cur) {
            if v.element == id {
                v.element = 0;
            }
            for a in &mut v.attrs {
                if a.buffer == id {
                    a.buffer = 0;
                }
            }
        }
    }

    fn bind_buffer_range(&mut self, target: u32, index: u32, id: u32, off: u64, size: u64) {
        if target == TRANSFORM_FEEDBACK_BUFFER {
            return self.bind_tf_buffer(index, id, off, size);
        }
        if target != UNIFORM_BUFFER {
            return self.set_error(INVALID_ENUM);
        }
        if index as usize >= MAX_UNIFORM_BUFFER_BINDINGS {
            return self.set_error(INVALID_VALUE);
        }
        if off % self.limits.ubo_align as u64 != 0 {
            return self.set_error(INVALID_VALUE);
        }
        if id != 0 {
            self.buffers.entry(id).or_insert_with(new_buf);
        }
        self.st.ubo_ranges[index as usize] = (id, off, size);
        self.st.uniform_buffer = id;
    }

    // ---- vertex attributes ----

    #[allow(clippy::too_many_arguments)]
    fn vertex_attrib_pointer(&mut self, i: u32, size: i32, ty: u32, normalized: bool, stride: i32, offset: u32, integer: bool) {
        if i >= self.caps.max_vertex_attribs {
            return self.set_error(INVALID_VALUE);
        }
        let w2 = self.is_webgl2();
        let valid = matches!(ty, formats::BYTE | formats::UNSIGNED_BYTE | formats::SHORT | formats::UNSIGNED_SHORT | formats::FLOAT)
            || (w2 && matches!(ty, formats::INT | formats::UNSIGNED_INT | formats::HALF_FLOAT | 0x8D9F | formats::UNSIGNED_INT_2_10_10_10_REV))
            || (ty == formats::HALF_FLOAT_OES && !w2);
        if !valid || (integer && matches!(ty, formats::FLOAT | formats::HALF_FLOAT | 0x8D9F | formats::UNSIGNED_INT_2_10_10_10_REV)) {
            return self.set_error(INVALID_ENUM);
        }
        if !(1..=4).contains(&size) || !(0..=255).contains(&stride) {
            return self.set_error(INVALID_VALUE);
        }
        let is_packed = matches!(ty, 0x8D9F | formats::UNSIGNED_INT_2_10_10_10_REV);
        if is_packed && size != 4 {
            return self.set_error(INVALID_OPERATION);
        }
        let ts = match ty {
            formats::BYTE | formats::UNSIGNED_BYTE => 1,
            formats::SHORT | formats::UNSIGNED_SHORT | formats::HALF_FLOAT | formats::HALF_FLOAT_OES => 2,
            _ => 4,
        };
        if offset % ts != 0 || stride as u32 % ts != 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let buffer = self.st.array_buffer;
        if buffer == 0 && offset != 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let a = &mut self.current_vao().attrs[i as usize];
        *a = Attr { enabled: a.enabled, buffer, size: size as u32, ty, normalized, integer, stride: stride as u32, offset, divisor: a.divisor };
    }

    // ---- textures ----

    fn bind_texture(&mut self, target: u32, id: u32) {
        if self.tex_binding(target).is_none() {
            return self.set_error(INVALID_ENUM);
        }
        if id != 0 {
            let t = self.textures.entry(id).or_insert_with(|| new_tex(target));
            if t.target != target {
                return self.set_error(INVALID_OPERATION);
            }
        }
        let u = self.st.active_unit as usize;
        match target {
            TEXTURE_2D => self.st.tex_2d[u] = id,
            TEXTURE_CUBE_MAP => self.st.tex_cube[u] = id,
            TEXTURE_3D => self.st.tex_3d[u] = id,
            _ => self.st.tex_array[u] = id,
        }
    }

    fn delete_texture(&mut self, id: u32) {
        self.end_pass();
        if let Some(t) = self.textures.remove(&id) {
            self.bytes = self.bytes.saturating_sub(t.bytes);
        }
        for u in 0..MAX_TEXTURE_UNITS {
            for t in [&mut self.st.tex_2d[u], &mut self.st.tex_cube[u], &mut self.st.tex_3d[u], &mut self.st.tex_array[u]] {
                if *t == id {
                    *t = 0;
                }
            }
        }
        self.detach_everywhere(|a| matches!(a, Attach::Tex { id: i, .. } if *i == id));
    }

    fn detach_everywhere(&mut self, pred: impl Fn(&Attach) -> bool) {
        // GL detaches from the bound framebuffers only; others keep a name that is gone, which reads as incomplete
        for fb in [self.st.draw_fb, self.st.read_fb] {
            if let Some(f) = self.fbs.get_mut(&fb) {
                for c in &mut f.color {
                    if c.as_ref().map_or(false, &pred) {
                        *c = None;
                    }
                }
                if f.depth.as_ref().map_or(false, &pred) {
                    f.depth = None;
                }
                if f.stencil.as_ref().map_or(false, &pred) {
                    f.stencil = None;
                }
            }
        }
        self.fb_gen += 1;
    }

    /// Gives a texture storage of a format and size, keeping it when it fits.
    #[allow(clippy::too_many_arguments)]
    fn ensure_storage(&mut self, id: u32, fmt: Fmt, w: u32, h: u32, d: u32, levels: Option<u32>) -> bool {
        let max_cap = self.attrs.max_bytes;
        let device = self.device.clone();
        let adapter_renderable = |f: wgpu::TextureFormat, features: wgpu::Features| -> bool {
            let ff = f.guaranteed_format_features(features);
            ff.allowed_usages.contains(wgpu::TextureUsages::RENDER_ATTACHMENT)
        };
        let features = self.features;
        let Some(t) = self.textures.get_mut(&id) else { return false };
        let same = t.gpu.is_some() && t.fmt.map(|f| f.wgpu) == Some(fmt.wgpu) && t.w == w && t.h == h && t.d == d;
        if same {
            t.fmt = Some(fmt);
            return true;
        }
        let dim = match t.target {
            TEXTURE_3D => wgpu::TextureDimension::D3,
            _ => wgpu::TextureDimension::D2,
        };
        let layers = match t.target {
            TEXTURE_CUBE_MAP => 6,
            TEXTURE_3D | TEXTURE_2D_ARRAY => d,
            _ => 1,
        };
        let is_3d = t.target == TEXTURE_3D;
        let full = if is_3d { full_levels(w, h, d) } else { full_levels(w, h, 1) };
        let levels = levels.unwrap_or(full).min(full);
        let mut usage = wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST | wgpu::TextureUsages::COPY_SRC;
        if adapter_renderable(fmt.wgpu, features) && !is_3d {
            usage |= wgpu::TextureUsages::RENDER_ATTACHMENT;
        }
        let texel = fmt.wgpu.block_copy_size(None).unwrap_or(4) as u64;
        let bytes = texel.saturating_mul(w as u64).saturating_mul(h as u64).saturating_mul(layers.max(1) as u64) * 4 / 3;
        let total = self.bytes.saturating_sub(t.bytes).saturating_add(bytes);
        if total > max_cap {
            self.error = if self.error == NO_ERROR { OUT_OF_MEMORY } else { self.error };
            return false;
        }
        let gpu = device.create_texture(&wgpu::TextureDescriptor {
            label: None,
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: layers },
            mip_level_count: levels,
            sample_count: 1,
            dimension: dim,
            format: fmt.wgpu,
            usage,
            view_formats: &[],
        });
        self.bytes = total;
        let t = self.textures.get_mut(&id).unwrap();
        t.bytes = bytes;
        t.gpu = Some(gpu);
        t.fmt = Some(fmt);
        t.w = w;
        t.h = h;
        t.d = d;
        t.levels = levels;
        t.defined = [0; 6];
        t.views.clear();
        t.generation += 1;
        t.used_gen = 0;
        self.fb_gen += 1;
        true
    }

    fn check_dims(&mut self, target: u32, level: i32, w: i32, h: i32, d: i32) -> bool {
        if level < 0 || w < 0 || h < 0 || d < 0 {
            self.set_error(INVALID_VALUE);
            return false;
        }
        let (max2d, max3d, maxl) = (self.limits.max_texture, self.limits.max_3d, self.limits.max_array_layers);
        let max = match target {
            TEXTURE_3D => max3d,
            _ => max2d,
        };
        if (w as u32) > (max >> level.min(31)) || (h as u32) > (max >> level.min(31)) {
            self.set_error(INVALID_VALUE);
            return false;
        }
        if (target == TEXTURE_3D && d as u32 > max3d) || (target == TEXTURE_2D_ARRAY && d as u32 > maxl) {
            self.set_error(INVALID_VALUE);
            return false;
        }
        if level > 31 - (max.max(1).leading_zeros() as i32) {
            self.set_error(INVALID_VALUE);
            return false;
        }
        true
    }

    #[allow(clippy::too_many_arguments)]
    fn tex_image(&mut self, target: u32, level: i32, internal: u32, w: i32, h: i32, d: i32, border: i32, format: u32, ty: u32, data: Option<&[u8]>, from_pbo: bool, pbo_off: usize, is3d: bool) {
        let Some((bind, face)) = self.image_target(target) else { return self.set_error(INVALID_ENUM) };
        if is3d != matches!(bind, TEXTURE_3D | TEXTURE_2D_ARRAY) {
            return self.set_error(INVALID_ENUM);
        }
        if border != 0 {
            return self.set_error(INVALID_VALUE);
        }
        if bind == TEXTURE_CUBE_MAP && w != h {
            return self.set_error(INVALID_VALUE);
        }
        if !self.check_dims(bind, level, w, h, d) {
            return;
        }
        let Some(id) = self.tex_binding(bind) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        if self.textures[&id].immutable > 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let Some(fmt) = self.validated_format(internal, format, ty) else { return };
        if fmt.is_depth_or_stencil() && (bind != TEXTURE_2D && !self.is_webgl2() || level != 0 && !self.is_webgl2() || data.is_some() && !self.is_webgl2()) {
            return self.set_error(INVALID_OPERATION);
        }
        let (w, h, d) = (w as u32, h as u32, d as u32);
        let (sw, sh, sd) = (w << level, h << level, if bind == TEXTURE_3D { d << level } else { d });
        // the storage: a level that does not fit what is there starts a new one at level 0, or (higher levels) is left undefined
        let t = &self.textures[&id];
        let has = t.gpu.is_some();
        let (cw, ch, cd) = (t.w, t.h, t.d);
        let same_format = t.fmt.map(|f| f.wgpu) == Some(fmt.wgpu);
        let fits = has && same_format && (cw >> level).max(1) == w.max(1) && (ch >> level).max(1) == h.max(1) && (bind != TEXTURE_3D || (cd >> level).max(1) == d.max(1)) && (bind != TEXTURE_2D_ARRAY || cd == d);
        if w == 0 || h == 0 || d == 0 {
            // an empty image: nothing to hold; the level is not defined
            if let Some(t) = self.textures.get_mut(&id) {
                if level == 0 {
                    t.defined[face as usize] = 0;
                    t.w = 0;
                    t.h = 0;
                    t.gpu = None;
                    t.fmt = None;
                }
            }
            return;
        }
        if !fits {
            if level != 0 && has && same_format {
                self.warn(format!("WebGL: texture level {level} has a size that does not follow level 0: it is ignored"));
                return;
            }
            if !self.ensure_storage(id, fmt, sw, sh, sd, None) {
                return;
            }
        } else if let Some(t) = self.textures.get_mut(&id) {
            t.fmt = Some(fmt);
        }
        let pixels = self.upload_source(data, from_pbo, pbo_off, format, ty, fmt, w, h, d);
        match pixels {
            Err(()) => {}
            Ok(px) => {
                if let Some(px) = px {
                    self.write_texture(id, level as u32, face, 0, 0, 0, w, h, d, &px);
                } else {
                    self.clear_level(id, level as u32, face);
                }
                self.mark_defined(id, level as u32, face);
            }
        }
    }

    /// Bytes for an upload: None when the page gave no data (the level starts as zeros).
    #[allow(clippy::too_many_arguments)]
    fn upload_source(&mut self, data: Option<&[u8]>, from_pbo: bool, pbo_off: usize, format: u32, ty: u32, fmt: Fmt, w: u32, h: u32, d: u32) -> Result<Option<Vec<u8>>, ()> {
        let Some(bpp) = formats::bytes_per_pixel(format, ty) else {
            self.set_error(INVALID_ENUM);
            return Err(());
        };
        let u = self.st.unpack;
        let Some((_, _, _, need)) = formats::layout(&u, bpp, w, h, d) else {
            self.set_error(INVALID_VALUE);
            return Err(());
        };
        let conv = |ctx: &mut Ctx, src: &[u8]| -> Result<Option<Vec<u8>>, ()> {
            match formats::convert_upload(src, &u, format, ty, fmt, w, h, d) {
                Some(v) => Ok(Some(v)),
                None => {
                    ctx.warn(format!("WebGL: uploading to this format (0x{:x}) from 0x{:x} / 0x{:x} is not supported", fmt.internal, format, ty));
                    ctx.set_error(INVALID_OPERATION);
                    Err(())
                }
            }
        };
        if from_pbo {
            let id = self.st.pixel_unpack;
            self.buffer_sync(id);
            let Some(b) = self.buffers.get(&id) else {
                self.set_error(INVALID_OPERATION);
                return Err(());
            };
            if pbo_off.saturating_add(need) > b.shadow.len() {
                self.set_error(INVALID_OPERATION);
                return Err(());
            }
            let copy = b.shadow[pbo_off..pbo_off + need].to_vec();
            return conv(self, &copy);
        }
        let Some(src) = data else { return Ok(None) };
        if src.len() < need {
            self.set_error(INVALID_OPERATION);
            return Err(());
        }
        conv(self, src)
    }

    fn validated_format(&mut self, internal: u32, format: u32, ty: u32) -> Option<Fmt> {
        let w2 = self.is_webgl2();
        let e = self.ext;
        let Some(fmt) = formats::texture_format(internal, format, ty, w2) else {
            // an enum no format knows is INVALID_ENUM; a bad combination INVALID_OPERATION
            let known_format = formats::format_components(format).is_some();
            let known_type = matches!(
                ty,
                formats::BYTE | formats::UNSIGNED_BYTE | formats::SHORT | formats::UNSIGNED_SHORT | formats::INT | formats::UNSIGNED_INT | formats::FLOAT | formats::HALF_FLOAT | formats::HALF_FLOAT_OES
                    | formats::UNSIGNED_SHORT_4_4_4_4 | formats::UNSIGNED_SHORT_5_5_5_1 | formats::UNSIGNED_SHORT_5_6_5 | formats::UNSIGNED_INT_2_10_10_10_REV | formats::UNSIGNED_INT_10F_11F_11F_REV
                    | formats::UNSIGNED_INT_5_9_9_9_REV | formats::UNSIGNED_INT_24_8 | formats::FLOAT_32_UNSIGNED_INT_24_8_REV
            );
            self.set_error(if !known_format || !known_type { INVALID_ENUM } else if internal == format { INVALID_OPERATION } else { INVALID_OPERATION });
            return None;
        };
        // each version has its own number for half floats
        if (w2 && ty == formats::HALF_FLOAT_OES) || (!w2 && ty == formats::HALF_FLOAT) {
            self.set_error(INVALID_ENUM);
            return None;
        }
        // what the extensions of WebGL 1 hold back
        if !w2 {
            let allowed = match ty {
                formats::FLOAT => e.texture_float,
                formats::HALF_FLOAT_OES => e.texture_half_float,
                formats::UNSIGNED_SHORT | formats::UNSIGNED_INT | formats::UNSIGNED_INT_24_8 => e.depth_texture,
                _ => true,
            };
            if !allowed {
                self.set_error(INVALID_ENUM);
                return None;
            }
            if matches!(format, formats::SRGB_EXT | formats::SRGB_ALPHA_EXT) && !e.srgb {
                self.set_error(INVALID_ENUM);
                return None;
            }
        } else if matches!(format, formats::SRGB_EXT | formats::SRGB_ALPHA_EXT) {
            self.set_error(INVALID_ENUM);
            return None;
        }
        Some(fmt)
    }

    /// For copyTexImage2D.
    pub fn storage_for_copy(&mut self, id: u32, fmt: Fmt, w: u32, h: u32) -> bool {
        self.ensure_storage(id, fmt, w, h, 1, None)
    }

    pub fn mark_level(&mut self, id: u32, level: u32, face: u32) {
        self.mark_defined(id, level, face);
    }

    fn mark_defined(&mut self, id: u32, level: u32, face: u32) {
        if let Some(t) = self.textures.get_mut(&id) {
            t.defined[face as usize] |= 1 << level.min(31);
        }
    }

    /// Zeros a level whose storage may be holding something else (the texture was there before).
    fn clear_level(&mut self, id: u32, level: u32, face: u32) {
        let t = &self.textures[&id];
        let Some(fmt) = t.fmt else { return };
        if t.defined[face as usize] & (1 << level.min(31)) == 0 {
            return; // never written: wgpu's zeros
        }
        if fmt.is_depth_or_stencil() {
            return;
        }
        let (w, h) = ((t.w >> level).max(1), (t.h >> level).max(1));
        let d = if t.target == TEXTURE_3D { (t.d >> level).max(1) } else { t.d.max(1) };
        let n = texel_size(fmt) as usize * w as usize * h as usize * d as usize;
        let zero = vec![0u8; n];
        self.write_texture(id, level, face, 0, 0, 0, w, h, d, &zero);
    }

    /// Writes tightly packed texels to a texture.
    #[allow(clippy::too_many_arguments)]
    pub fn write_texture(&mut self, id: u32, level: u32, face: u32, x: u32, y: u32, z: u32, w: u32, h: u32, d: u32, px: &[u8]) {
        if w == 0 || h == 0 || d == 0 {
            return;
        }
        if self.textures[&id].used_gen == self.enc_gen {
            self.submit();
        }
        let t = &self.textures[&id];
        let Some(gpu) = &t.gpu else { return };
        let Some(fmt) = t.fmt else { return };
        let bytes = texel_size(fmt);
        let (bw, _) = fmt.wgpu.block_dimensions();
        let origin_z = if t.target == TEXTURE_CUBE_MAP { face } else { z };
        let row = if bw > 1 { w.div_ceil(bw) * bytes } else { w * bytes };
        let (bh_rows, _) = {
            let (_, bh) = fmt.wgpu.block_dimensions();
            (if bh > 1 { h.div_ceil(bh) } else { h }, 0)
        };
        let aspect = if fmt.is_depth_or_stencil() { wgpu::TextureAspect::DepthOnly } else { wgpu::TextureAspect::All };
        self.queue.write_texture(
            wgpu::TexelCopyTextureInfo { texture: gpu, mip_level: level, origin: wgpu::Origin3d { x, y, z: origin_z }, aspect },
            px,
            wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(row), rows_per_image: Some(bh_rows) },
            wgpu::Extent3d { width: w, height: h, depth_or_array_layers: d },
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn tex_sub_image(&mut self, target: u32, level: i32, x: i32, y: i32, z: i32, w: i32, h: i32, d: i32, format: u32, ty: u32, data: Option<&[u8]>, from_pbo: bool, pbo_off: usize, is3d: bool) {
        let Some((bind, face)) = self.image_target(target) else { return self.set_error(INVALID_ENUM) };
        if is3d != matches!(bind, TEXTURE_3D | TEXTURE_2D_ARRAY) {
            return self.set_error(INVALID_ENUM);
        }
        if level < 0 || x < 0 || y < 0 || z < 0 || w < 0 || h < 0 || d < 0 {
            return self.set_error(INVALID_VALUE);
        }
        let Some(id) = self.tex_binding(bind) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let t = &self.textures[&id];
        let Some(fmt) = t.fmt else { return self.set_error(INVALID_OPERATION) };
        if t.defined[face as usize] & (1 << (level as u32).min(31)) == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let (tw, th) = ((t.w >> level).max(1), (t.h >> level).max(1));
        let td = if t.target == TEXTURE_3D { (t.d >> level).max(1) } else { t.d.max(1) };
        if x as u32 + w as u32 > tw || y as u32 + h as u32 > th || z as u32 + d as u32 > td {
            return self.set_error(INVALID_VALUE);
        }
        if formats::bytes_per_pixel(format, ty).is_none() {
            return self.set_error(INVALID_ENUM);
        }
        if !sub_format_ok(fmt, format, ty) {
            return self.set_error(INVALID_OPERATION);
        }
        if w == 0 || h == 0 || d == 0 {
            return;
        }
        if data.is_none() && !from_pbo {
            return self.set_error(INVALID_VALUE);
        }
        match self.upload_source(data, from_pbo, pbo_off, format, ty, fmt, w as u32, h as u32, d as u32) {
            Ok(Some(px)) => self.write_texture(id, level as u32, face, x as u32, y as u32, z as u32, w as u32, h as u32, d as u32, &px),
            _ => {}
        }
    }

    /// texImage2D / texSubImage2D of an element: bytes already RGBA8 from the host.
    #[allow(clippy::too_many_arguments)]
    fn tex_image_source(&mut self, sw: i32, sh: i32, premultiplied: bool, target: u32, level: i32, internal: u32, format: u32, ty: u32, sub: bool, x: i32, y: i32, z: i32, data: &[u8]) {
        let Some((bind, face)) = self.image_target(target) else { return self.set_error(INVALID_ENUM) };
        if sw < 0 || sh < 0 || level < 0 || x < 0 || y < 0 || z < 0 {
            return self.set_error(INVALID_VALUE);
        }
        let (w, h) = (sw as u32, sh as u32);
        if (w as usize).saturating_mul(h as usize).saturating_mul(4) > data.len() {
            return self.set_error(INVALID_VALUE);
        }
        let Some(id) = self.tex_binding(bind) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let fmt = if sub {
            match self.textures[&id].fmt {
                Some(f) => f,
                None => return self.set_error(INVALID_OPERATION),
            }
        } else {
            if bind == TEXTURE_CUBE_MAP && w != h {
                return self.set_error(INVALID_VALUE);
            }
            if !self.check_dims(bind, level, sw, sh, 1) {
                return;
            }
            if self.textures[&id].immutable > 0 {
                return self.set_error(INVALID_OPERATION);
            }
            let Some(fmt) = self.validated_format(internal, format, ty) else { return };
            if fmt.is_depth_or_stencil() || fmt.is_integer() {
                return self.set_error(INVALID_OPERATION);
            }
            fmt
        };
        if !sub {
            if w == 0 || h == 0 {
                return;
            }
            let t = &self.textures[&id];
            let has = t.gpu.is_some();
            let same = t.fmt.map(|f| f.wgpu) == Some(fmt.wgpu);
            let fits = has && same && (t.w >> level).max(1) == w && (t.h >> level).max(1) == h;
            if !fits {
                if level != 0 && has && same {
                    return;
                }
                if !self.ensure_storage(id, fmt, w << level, h << level, 1, None) {
                    return;
                }
            } else if let Some(t) = self.textures.get_mut(&id) {
                t.fmt = Some(fmt);
            }
        } else {
            let t = &self.textures[&id];
            let (tw, th) = ((t.w >> level).max(1), (t.h >> level).max(1));
            if x as u32 + w > tw || y as u32 + h > th {
                return self.set_error(INVALID_VALUE);
            }
        }
        let u = self.st.unpack;
        let Some(px) = formats::convert_image(data, premultiplied, &u, format, fmt, w, h) else {
            return self.set_error(INVALID_OPERATION);
        };
        self.write_texture(id, level as u32, face, x as u32, y as u32, z as u32, w, h, 1, &px);
        if !sub {
            self.mark_defined(id, level as u32, face);
        }
    }

    fn compressed_format(&mut self, internal: u32) -> Option<Fmt> {
        let f = match internal {
            0x83F0 | 0x83F1 => wgpu::TextureFormat::Bc1RgbaUnorm,
            0x83F2 => wgpu::TextureFormat::Bc2RgbaUnorm,
            0x83F3 => wgpu::TextureFormat::Bc3RgbaUnorm,
            _ => {
                self.set_error(INVALID_ENUM);
                return None;
            }
        };
        if !self.ext.s3tc || !self.features.contains(wgpu::Features::TEXTURE_COMPRESSION_BC) {
            self.set_error(INVALID_ENUM);
            return None;
        }
        Some(Fmt { wgpu: f, internal, channels: Channels::Same })
    }

    #[allow(clippy::too_many_arguments)]
    fn compressed_tex_image(&mut self, target: u32, level: i32, internal: u32, w: i32, h: i32, d: i32, border: i32, is3d: bool, data: &[u8]) {
        let Some((bind, face)) = self.image_target(target) else { return self.set_error(INVALID_ENUM) };
        if is3d || border != 0 {
            return self.set_error(if is3d { INVALID_ENUM } else { INVALID_VALUE });
        }
        let Some(fmt) = self.compressed_format(internal) else { return };
        if !self.check_dims(bind, level, w, h, d) {
            return;
        }
        let Some(id) = self.tex_binding(bind) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let (w, h) = (w as u32, h as u32);
        let block = fmt.wgpu.block_copy_size(None).unwrap_or(16) as usize;
        let need = (w as usize).div_ceil(4) * (h as usize).div_ceil(4) * block;
        if data.len() != need {
            return self.set_error(INVALID_VALUE);
        }
        let (sw, sh) = (w << level, h << level);
        // wgpu requires block-sized dimensions at level 0
        if sw % 4 != 0 || sh % 4 != 0 {
            return self.set_error(INVALID_OPERATION);
        }
        if !self.ensure_storage(id, fmt, sw, sh, 1, None) {
            return;
        }
        let (mw, mh) = (((w.max(1) + 3) & !3).max(4), ((h.max(1) + 3) & !3).max(4));
        self.write_texture(id, level as u32, face, 0, 0, 0, mw, mh, 1, data);
        self.mark_defined(id, level as u32, face);
    }

    #[allow(clippy::too_many_arguments)]
    fn compressed_tex_sub_image(&mut self, target: u32, level: i32, x: i32, y: i32, z: i32, w: i32, h: i32, d: i32, format: u32, data: &[u8]) {
        let Some((bind, face)) = self.image_target(target) else { return self.set_error(INVALID_ENUM) };
        let Some(id) = self.tex_binding(bind) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        if level < 0 || x < 0 || y < 0 || z < 0 || w < 0 || h < 0 || d < 0 {
            return self.set_error(INVALID_VALUE);
        }
        let Some(fmt) = self.textures[&id].fmt else { return self.set_error(INVALID_OPERATION) };
        if fmt.internal != format {
            return self.set_error(INVALID_OPERATION);
        }
        self.write_texture(id, level as u32, face, x as u32, y as u32, z as u32, ((w as u32) + 3) & !3, ((h as u32) + 3) & !3, 1, data);
    }

    #[allow(clippy::too_many_arguments)]
    fn tex_storage(&mut self, target: u32, levels: i32, internal: u32, w: i32, h: i32, d: i32, is3d: bool) {
        if !matches!(target, TEXTURE_2D | TEXTURE_CUBE_MAP | TEXTURE_3D | TEXTURE_2D_ARRAY) || is3d != matches!(target, TEXTURE_3D | TEXTURE_2D_ARRAY) {
            return self.set_error(INVALID_ENUM);
        }
        let Some(id) = self.tex_binding(target) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        if self.textures[&id].immutable > 0 {
            return self.set_error(INVALID_OPERATION);
        }
        if levels < 1 || w < 1 || h < 1 || d < 1 {
            return self.set_error(INVALID_VALUE);
        }
        if target == TEXTURE_CUBE_MAP && w != h {
            return self.set_error(INVALID_VALUE);
        }
        if !self.check_dims(target, 0, w, h, d) {
            return;
        }
        let Some(fmt) = formats::sized_format(internal) else { return self.set_error(INVALID_ENUM) };
        let (w, h, d) = (w as u32, h as u32, d as u32);
        let full = if target == TEXTURE_3D { full_levels(w, h, d) } else { full_levels(w, h, 1) };
        if levels as u32 > full {
            return self.set_error(INVALID_OPERATION);
        }
        if !self.ensure_storage(id, fmt, w, h, d, Some(levels as u32)) {
            return;
        }
        let t = self.textures.get_mut(&id).unwrap();
        t.immutable = levels as u32;
        t.defined = [(1u32 << levels.min(31)) - 1; 6];
    }

    fn tex_parameter(&mut self, target: u32, p: u32, f: f32, v: u32) {
        let Some(id) = self.tex_binding(target) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let aniso_ok = self.ext.anisotropic;
        let w2 = self.is_webgl2();
        let t = self.textures.get_mut(&id).unwrap();
        match p {
            TEXTURE_BASE_LEVEL if w2 => {
                t.base_level = v;
                t.views.clear();
                return;
            }
            TEXTURE_MAX_LEVEL if w2 => {
                t.max_level = v;
                t.views.clear();
                return;
            }
            _ => {}
        }
        let params = &mut t.params;
        if !set_sampler_param(params, p, f, v, w2, aniso_ok) {
            let bad_value = matches!(p, TEXTURE_MAX_ANISOTROPY) && aniso_ok;
            self.set_error(if bad_value { INVALID_VALUE } else { INVALID_ENUM });
        }
    }

    fn sampler_parameter(&mut self, id: u32, p: u32, f: f32, v: u32) {
        let aniso_ok = self.ext.anisotropic;
        let params = self.sampler_objs.entry(id).or_default();
        if !set_sampler_param(params, p, f, v, true, aniso_ok) {
            self.set_error(INVALID_ENUM);
        }
    }

    fn generate_mipmap(&mut self, target: u32) {
        let Some(id) = self.tex_binding(target) else { return self.set_error(INVALID_ENUM) };
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let t = &self.textures[&id];
        let Some(fmt) = t.fmt else { return self.set_error(INVALID_OPERATION) };
        if !self.is_webgl2() && !(t.w.is_power_of_two() && t.h.is_power_of_two()) {
            return self.set_error(INVALID_OPERATION);
        }
        if target == TEXTURE_CUBE_MAP && (t.defined[..6].iter().any(|d| d & 1 == 0) || t.w != t.h) {
            return self.set_error(INVALID_OPERATION);
        }
        if t.defined[0] & 1 == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let ff = fmt.wgpu.guaranteed_format_features(self.features);
        if !ff.flags.contains(wgpu::TextureFormatFeatureFlags::FILTERABLE) || !ff.allowed_usages.contains(wgpu::TextureUsages::RENDER_ATTACHMENT) || target == TEXTURE_3D {
            if target == TEXTURE_3D {
                self.warn("WebGL: generateMipmap of a 3D texture does nothing here".to_string());
                return;
            }
            return self.set_error(INVALID_OPERATION);
        }
        crate::draw::generate_mipmaps(self, id);
    }

    // ---- framebuffers ----

    fn framebuffer_binding(&self, target: u32) -> Option<u32> {
        match target {
            FRAMEBUFFER | DRAW_FRAMEBUFFER if target == FRAMEBUFFER || self.attrs.webgl2 => Some(self.st.draw_fb),
            READ_FRAMEBUFFER if self.attrs.webgl2 => Some(self.st.read_fb),
            _ => None,
        }
    }

    fn set_attachment(&mut self, fb: u32, attachment: u32, a: Option<Attach>) -> bool {
        let max = self.caps.max_draw_buffers;
        let Some(f) = self.fbs.get_mut(&fb) else { return false };
        match attachment {
            COLOR_ATTACHMENT0..=0x8CEF if attachment - COLOR_ATTACHMENT0 < max.max(1) => f.color[(attachment - COLOR_ATTACHMENT0) as usize] = a,
            DEPTH_ATTACHMENT => f.depth = a,
            STENCIL_ATTACHMENT => f.stencil = a,
            DEPTH_STENCIL_ATTACHMENT => {
                f.depth = a;
                f.stencil = a;
            }
            _ => return false,
        }
        self.fb_gen += 1;
        true
    }

    fn framebuffer_renderbuffer(&mut self, target: u32, attachment: u32, rt: u32, id: u32) {
        let Some(fb) = self.framebuffer_binding(target) else { return self.set_error(INVALID_ENUM) };
        if rt != RENDERBUFFER {
            return self.set_error(INVALID_ENUM);
        }
        if fb == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let a = if id == 0 {
            None
        } else {
            self.rbs.entry(id).or_insert_with(new_rb);
            Some(Attach::Rb { id })
        };
        if !self.set_attachment(fb, attachment, a) {
            self.set_error(INVALID_ENUM);
        }
    }

    fn framebuffer_texture(&mut self, target: u32, attachment: u32, tt: u32, id: u32, level: i32) {
        let Some(fb) = self.framebuffer_binding(target) else { return self.set_error(INVALID_ENUM) };
        if fb == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let Some((bind, face)) = self.image_target(tt) else { return self.set_error(INVALID_ENUM) };
        if matches!(bind, TEXTURE_3D | TEXTURE_2D_ARRAY) {
            return self.set_error(INVALID_ENUM);
        }
        if level != 0 && !self.is_webgl2() {
            return self.set_error(INVALID_VALUE);
        }
        if level < 0 {
            return self.set_error(INVALID_VALUE);
        }
        let a = if id == 0 {
            None
        } else {
            match self.textures.get(&id) {
                Some(t) if t.target == bind => {}
                Some(_) => return self.set_error(INVALID_OPERATION),
                None => return self.set_error(INVALID_OPERATION),
            }
            Some(Attach::Tex { id, level: level as u32, layer: face })
        };
        if !self.set_attachment(fb, attachment, a) {
            self.set_error(INVALID_ENUM);
        }
    }

    fn framebuffer_texture_layer(&mut self, target: u32, attachment: u32, id: u32, level: i32, layer: i32) {
        let Some(fb) = self.framebuffer_binding(target) else { return self.set_error(INVALID_ENUM) };
        if fb == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        if level < 0 || layer < 0 {
            return self.set_error(INVALID_VALUE);
        }
        let a = if id == 0 {
            None
        } else {
            match self.textures.get(&id) {
                Some(t) if matches!(t.target, TEXTURE_2D_ARRAY | TEXTURE_3D) => {}
                _ => return self.set_error(INVALID_OPERATION),
            }
            Some(Attach::Tex { id, level: level as u32, layer: layer as u32 })
        };
        if !self.set_attachment(fb, attachment, a) {
            self.set_error(INVALID_ENUM);
        }
    }

    /// Size and format of an attachment.
    pub fn attachment_info(&self, a: &Attach) -> Option<(u32, u32, Fmt, u32)> {
        match a {
            Attach::Tex { id, level, .. } => {
                let t = self.textures.get(id)?;
                let fmt = t.fmt?;
                if t.gpu.is_none() || *level >= t.levels {
                    return None;
                }
                Some(((t.w >> level).max(1), (t.h >> level).max(1), fmt, 1))
            }
            Attach::Rb { id } => {
                let r = self.rbs.get(id)?;
                Some((r.w, r.h, r.fmt?, r.samples))
            }
        }
    }

    /// checkFramebufferStatus of a framebuffer's name.
    pub fn fb_status(&self, id: u32) -> u32 {
        const COMPLETE: u32 = 0x8CD5;
        const INCOMPLETE_ATTACHMENT: u32 = 0x8CD6;
        const INCOMPLETE_MISSING: u32 = 0x8CD7;
        const INCOMPLETE_DIMENSIONS: u32 = 0x8CD9;
        const UNSUPPORTED: u32 = 0x8CDD;
        const INCOMPLETE_MULTISAMPLE: u32 = 0x8D56;
        if id == 0 {
            return COMPLETE;
        }
        let Some(f) = self.fbs.get(&id) else { return UNSUPPORTED };
        let mut size = None;
        let mut samples = None;
        let mut any = false;
        let features = self.features;
        let check = |a: &Attach, want_depth: bool, want_stencil: bool, size: &mut Option<(u32, u32)>, samples: &mut Option<u32>| -> u32 {
            let Some((w, h, fmt, s)) = self.attachment_info(a) else { return INCOMPLETE_ATTACHMENT };
            if w == 0 || h == 0 {
                return INCOMPLETE_ATTACHMENT;
            }
            let renderable = fmt.wgpu.guaranteed_format_features(features).allowed_usages.contains(wgpu::TextureUsages::RENDER_ATTACHMENT);
            if !renderable {
                return INCOMPLETE_ATTACHMENT;
            }
            if want_depth && !fmt.is_depth() {
                return INCOMPLETE_ATTACHMENT;
            }
            if want_stencil && !fmt.has_stencil() {
                return INCOMPLETE_ATTACHMENT;
            }
            if !want_depth && !want_stencil && fmt.is_depth_or_stencil() {
                return INCOMPLETE_ATTACHMENT;
            }
            if let Some(sz) = size {
                if *sz != (w, h) {
                    return INCOMPLETE_DIMENSIONS;
                }
            }
            *size = Some((w, h));
            if let Some(x) = samples {
                if *x != s {
                    return INCOMPLETE_MULTISAMPLE;
                }
            }
            *samples = Some(s);
            COMPLETE
        };
        for a in f.color.iter().flatten() {
            any = true;
            let c = check(a, false, false, &mut size, &mut samples);
            if c != COMPLETE {
                return c;
            }
        }
        if let Some(a) = &f.depth {
            any = true;
            let c = check(a, true, false, &mut size, &mut samples);
            if c != COMPLETE {
                return c;
            }
        }
        if let Some(a) = &f.stencil {
            any = true;
            let c = check(a, false, true, &mut size, &mut samples);
            if c != COMPLETE {
                return c;
            }
        }
        // wgpu has a single depth-stencil attachment
        if let (Some(d), Some(s)) = (&f.depth, &f.stencil) {
            if d != s {
                return UNSUPPORTED;
            }
        }
        if !any {
            return INCOMPLETE_MISSING;
        }
        COMPLETE
    }

    fn renderbuffer_storage(&mut self, target: u32, internal: u32, w: i32, h: i32, samples: i32) {
        if target != RENDERBUFFER {
            return self.set_error(INVALID_ENUM);
        }
        if samples > 0 && !self.is_webgl2() {
            return self.set_error(INVALID_ENUM);
        }
        let id = self.st.renderbuffer;
        if id == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        if w < 0 || h < 0 || samples < 0 {
            return self.set_error(INVALID_VALUE);
        }
        if w as u32 > self.limits.max_renderbuffer || h as u32 > self.limits.max_renderbuffer {
            return self.set_error(INVALID_VALUE);
        }
        let Some(fmt) = formats::renderbuffer_format(internal, self.is_webgl2()) else { return self.set_error(INVALID_ENUM) };
        if samples > self.limits.max_samples as i32 {
            return self.set_error(INVALID_OPERATION);
        }
        let s = if samples > 1 { self.limits.max_samples } else { 1 };
        let texel = fmt.wgpu.block_copy_size(None).unwrap_or(4) as u64;
        let bytes = (w as u64) * (h as u64) * texel * s as u64;
        let old = self.rbs.get(&id).map_or(0, |r| r.bytes);
        if self.bytes.saturating_sub(old).saturating_add(bytes) > self.attrs.max_bytes {
            return self.set_error(OUT_OF_MEMORY);
        }
        self.end_pass();
        self.bytes = self.bytes.saturating_sub(old) + bytes;
        let rb = self.rbs.entry(id).or_insert_with(new_rb);
        rb.bytes = bytes;
        rb.generation += 1;
        rb.fmt = Some(fmt);
        rb.w = w as u32;
        rb.h = h as u32;
        rb.samples = s;
        rb.used_gen = 0;
        if w == 0 || h == 0 {
            rb.gpu = None;
            rb.view = None;
        } else {
            let gpu = self.device.create_texture(&wgpu::TextureDescriptor {
                label: None,
                size: wgpu::Extent3d { width: w as u32, height: h as u32, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: s,
                dimension: wgpu::TextureDimension::D2,
                format: fmt.wgpu,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            rb.view = Some(gpu.create_view(&wgpu::TextureViewDescriptor::default()));
            rb.gpu = Some(gpu);
        }
        self.fb_gen += 1;
    }

    fn read_buffer(&mut self, m: u32) {
        if !self.is_webgl2() {
            return self.set_error(INVALID_OPERATION);
        }
        let id = self.st.read_fb;
        if id == 0 {
            if !matches!(m, BACK | NONE) {
                return self.set_error(INVALID_OPERATION);
            }
            return;
        }
        let ok = m == NONE || (COLOR_ATTACHMENT0..COLOR_ATTACHMENT0 + self.caps.max_draw_buffers).contains(&m);
        if !ok {
            return self.set_error(INVALID_ENUM);
        }
        if let Some(f) = self.fbs.get_mut(&id) {
            f.read_buffer = m;
        }
    }

    fn draw_buffers(&mut self, list: &[u32]) {
        let max = self.caps.max_draw_buffers as usize;
        if list.len() > max {
            return self.set_error(INVALID_VALUE);
        }
        let id = self.st.draw_fb;
        if id == 0 {
            if list.len() != 1 || !matches!(list[0], BACK | NONE) {
                return self.set_error(INVALID_OPERATION);
            }
            return;
        }
        let Some(f) = self.fbs.get_mut(&id) else { return };
        for (i, m) in list.iter().enumerate() {
            let ok = *m == NONE || *m == COLOR_ATTACHMENT0 + i as u32;
            if !ok {
                self.set_error(INVALID_OPERATION);
                return;
            }
        }
        f.draw_buffers = [NONE; MAX_COLOR_ATTACHMENTS];
        f.draw_buffers[..list.len()].copy_from_slice(list);
        self.fb_gen += 1;
    }

    // ---- shaders and programs ----

    fn shader_source(&mut self, id: u32, stage: u32, src: &[u8]) {
        let e = self.shaders.entry(id).or_insert_with(|| ShaderObj {
            stage: if stage == 0x8B31 { Stage::Vertex } else { Stage::Fragment },
            source: String::new(),
            compiled: None,
            log: String::new(),
            deleted: false,
            attached: 0,
        });
        e.source = String::from_utf8_lossy(src).into_owned();
    }

    fn compile_shader(&mut self, id: u32) {
        let caps = self.caps.clone();
        let Some(s) = self.shaders.get_mut(&id) else { return self.set_error(INVALID_OPERATION) };
        match translate::compile(s.stage, &s.source, &caps) {
            Ok(sh) => {
                s.log = sh.warnings.concat();
                s.compiled = Some(Rc::new(sh));
            }
            Err(log) => {
                s.log = log;
                s.compiled = None;
            }
        }
    }

    fn attach_shader(&mut self, p: u32, s: u32) {
        let stage = self.shaders.entry(s).or_insert_with(|| ShaderObj { stage: Stage::Vertex, source: String::new(), compiled: None, log: String::new(), deleted: false, attached: 0 }).stage;
        let Some(prog) = self.programs.get_mut(&p) else {
            let mut np = new_program();
            match stage {
                Stage::Vertex => np.vs = s,
                Stage::Fragment => np.fs = s,
            }
            self.programs.insert(p, np);
            self.shaders.get_mut(&s).unwrap().attached += 1;
            return;
        };
        let slot = match stage {
            Stage::Vertex => &mut prog.vs,
            Stage::Fragment => &mut prog.fs,
        };
        if *slot != 0 {
            return self.set_error(INVALID_OPERATION);
        }
        *slot = s;
        self.shaders.get_mut(&s).unwrap().attached += 1;
    }

    fn detach_shader(&mut self, p: u32, s: u32) {
        let Some(prog) = self.programs.get_mut(&p) else { return self.set_error(INVALID_OPERATION) };
        if prog.vs == s {
            prog.vs = 0;
        } else if prog.fs == s {
            prog.fs = 0;
        } else {
            return self.set_error(INVALID_OPERATION);
        }
        if let Some(sh) = self.shaders.get_mut(&s) {
            sh.attached = sh.attached.saturating_sub(1);
            if sh.deleted && sh.attached == 0 {
                self.shaders.remove(&s);
            }
        }
    }

    fn bind_attrib_location(&mut self, p: u32, i: u32, name: String) {
        if i >= self.caps.max_vertex_attribs {
            return self.set_error(INVALID_VALUE);
        }
        if name.starts_with("gl_") || name.starts_with("webgl_") || name.starts_with("_webgl_") {
            return self.set_error(INVALID_OPERATION);
        }
        let prog = self.programs.entry(p).or_insert_with(new_program);
        prog.bound.insert(name, i);
    }

    fn delete_shader(&mut self, id: u32) {
        if let Some(s) = self.shaders.get_mut(&id) {
            s.deleted = true;
            if s.attached == 0 {
                self.shaders.remove(&id);
            }
        }
    }

    fn delete_program(&mut self, id: u32) {
        if let Some(p) = self.programs.get_mut(&id) {
            p.deleted = true;
            if self.st.program == id {
                return;
            }
            self.free_program(id);
        }
    }

    fn free_program(&mut self, id: u32) {
        self.end_pass();
        if let Some(p) = self.programs.remove(&id) {
            for s in [p.vs, p.fs] {
                if let Some(sh) = self.shaders.get_mut(&s) {
                    sh.attached = sh.attached.saturating_sub(1);
                    if sh.deleted && sh.attached == 0 {
                        self.shaders.remove(&s);
                    }
                }
            }
        }
    }

    fn use_program(&mut self, id: u32) {
        if self.tf_capturing() {
            return self.set_error(INVALID_OPERATION);
        }
        if id != 0 {
            let Some(p) = self.programs.get(&id) else { return self.set_error(INVALID_OPERATION) };
            if !p.link_status {
                return self.set_error(INVALID_OPERATION);
            }
        }
        let old = self.st.program;
        self.st.program = id;
        if old != 0 && old != id && self.programs.get(&old).map_or(false, |p| p.deleted) {
            self.free_program(old);
        }
    }

    fn link_program(&mut self, id: u32) {
        self.end_pass();
        // (the program a feedback is active with stays linked: OpenGL ES 3.0)
        if self.tf_capturing() && self.st.program == id {
            return self.set_error(INVALID_OPERATION);
        }
        let caps = self.caps.clone();
        let prog = self.programs.entry(id).or_insert_with(new_program);
        prog.link_status = false;
        prog.linked = None;
        prog.generation += 1;
        let (vs_id, fs_id, bound) = (prog.vs, prog.fs, prog.bound.clone());
        let vs = self.shaders.get(&vs_id).and_then(|s| s.compiled.clone());
        let fs = self.shaders.get(&fs_id).and_then(|s| s.compiled.clone());
        let (Some(vs), Some(fs)) = (vs, fs) else {
            let log = if vs_id == 0 || fs_id == 0 { "ERROR: a program needs a vertex and a fragment shader\n" } else { "ERROR: a shader of the program is not compiled\n" };
            self.programs.get_mut(&id).unwrap().log = log.to_string();
            return;
        };
        let result = translate::link(&vs, &fs, &bound, &caps);
        match result {
            Err(log) => {
                self.programs.get_mut(&id).unwrap().log = log;
            }
            Ok(l) => {
                let vs_mod = crate::draw::shader_module(&self.device, l.vertex);
                let fs_mod = crate::draw::shader_module(&self.device, l.fragment);
                let (Some(vs_mod), Some(fs_mod)) = (vs_mod, fs_mod) else {
                    let why = crate::draw::LAST_SHADER_ERROR.with(|s| s.borrow().clone());
                    self.programs.get_mut(&id).unwrap().log = format!("ERROR: the device refused the program: {why}\n");
                    return;
                };
                let mut uniforms: Vec<UniformInfo> = Vec::new();
                for leaf in &vs.leaves {
                    uniforms.push(UniformInfo { name: leaf.name.clone(), ty: leaf.ty, count: leaf.count, vs: Some((leaf.offset, leaf.stride)), fs: None, sampler: None, block: None });
                }
                for leaf in &fs.leaves {
                    if let Some(u) = uniforms.iter_mut().find(|u| u.name == leaf.name) {
                        u.fs = Some((leaf.offset, leaf.stride));
                    } else {
                        uniforms.push(UniformInfo { name: leaf.name.clone(), ty: leaf.ty, count: leaf.count, vs: None, fs: Some((leaf.offset, leaf.stride)), sampler: None, block: None });
                    }
                }
                let mut seen = Vec::new();
                let mut sampler_dims = vec![(wgpu::TextureViewDimension::D2, SampleKind::Float, false); l.map.samplers.len()];
                for d in vs.samplers.iter().chain(fs.samplers.iter()) {
                    let (dim, kind, shadow) = sampler_binding_kind(d.kind.gl);
                    let first = if d.count == 0 { l.map.samplers[&d.name] } else { l.map.samplers[&format!("{}[0]", d.name)] };
                    for i in 0..d.count.max(1) {
                        sampler_dims[(first + i) as usize] = (dim, kind, shadow);
                    }
                    if seen.contains(&d.name) || !d.active {
                        continue;
                    }
                    seen.push(d.name.clone());
                    let name = if d.count == 0 { d.name.clone() } else { format!("{}[0]", d.name) };
                    uniforms.push(UniformInfo { name, ty: translate::BasicType { gl: d.kind.gl, cols: 1, rows: 1 }, count: d.count, vs: None, fs: None, sampler: Some(first), block: None });
                }
                let mut locations = Vec::new();
                let mut names = HashMap::new();
                for (ui, u) in uniforms.iter().enumerate() {
                    let n = u.count.max(1);
                    if u.block.is_some() {
                        continue;
                    }
                    let base = u.name.strip_suffix("[0]").unwrap_or(&u.name).to_string();
                    for e in 0..n {
                        let loc = locations.len() as u32;
                        locations.push(Location { uniform: ui as u32, element: e });
                        if u.count > 0 {
                            names.insert(format!("{}[{}]", base, e), loc);
                        }
                        if e == 0 {
                            names.insert(base.clone(), loc);
                        }
                    }
                }
                let attrs = l.attributes.iter().map(|(n, t, a, loc)| {
                    let used = vs.inputs.iter().find(|i| &i.name == n).map_or(true, |i| i.active);
                    (n.clone(), *t, *a, *loc, used)
                }).collect();
                let mut blocks: Vec<translate::BlockInfo> = Vec::new();
                for b in vs.blocks.iter().chain(fs.blocks.iter()) {
                    if !blocks.iter().any(|x| x.name == b.name) {
                        blocks.push(b.clone());
                    }
                }
                // (after the locations were given: the members of blocks are active, and have none)
                for (bi, b) in blocks.iter().enumerate() {
                    for m in &b.members {
                        uniforms.push(UniformInfo { name: m.name.clone(), ty: m.ty, count: m.count, vs: None, fs: None, sampler: None, block: Some((bi as u32, m.offset, m.array_stride, m.matrix_stride)) });
                    }
                }
                let outs = fs.outputs.iter().filter(|o| o.ty.scalar() != translate::Scalar::Float).fold(0u32, |m, o| m | 1 << o.location.unwrap_or(0));
                let outputs = if fs.es3 {
                    let mut m = 0u32;
                    let mut next = 0;
                    for o in &fs.outputs {
                        let l = o.location.unwrap_or(next);
                        for k in 0..o.slots().max(1) {
                            m |= 1 << (l + k);
                        }
                        next = l + o.slots();
                    }
                    m
                } else {
                    fs.es1_outputs()
                };
                let (tf_names, tf_mode) = self.programs.get(&id).map(|p| (p.tf_names.clone(), p.tf_mode)).unwrap_or_default();
                let tf_program = match translate::capture_layout(&vs, &tf_names, tf_mode == crate::capture::SEPARATE_ATTRIBS) {
                    Ok((vars, stride_words)) => crate::capture::TfProgram { vars, stride_words, separate: tf_mode == crate::capture::SEPARATE_ATTRIBS, ..Default::default() },
                    Err(e) => {
                        let prog = self.programs.get_mut(&id).unwrap();
                        prog.log = e;
                        return;
                    }
                };
                let (mut vs_image, mut fs_image) = (vec![0u8; l.vs_size as usize], vec![0u8; l.fs_size as usize]);
                vs_image.resize(l.vs_size.max(16) as usize, 0);
                fs_image.resize(l.fs_size as usize, 0);
                let block_bindings = vec![0; blocks.len()];
                let stage_blocks = blocks.iter().map(|b| l.map.blocks[&b.name]).collect();
                let linked = Linked {
                    vs: vs_mod,
                    vs_points: std::cell::OnceCell::new(),
                    fs: fs_mod,
                    vs_shader: vs.clone(),
                    map: l.map.clone(),
                    attributes: attrs,
                    uniforms,
                    locations,
                    names,
                    vs_image,
                    fs_image,
                    vs_dirty: true,
                    fs_dirty: true,
                    vs_at: 0,
                    fs_at: 0,
                    ring_epoch: 0,
                    sampler_units: vec![0; sampler_dims.len()],
                    sampler_dims,
                    blocks,
                    block_bindings,
                    stage_blocks,
                    bgl0: None,
                    bg0: None,
                    bgl2: None,
                    layouts: HashMap::new(),
                    pipelines: HashMap::new(),
                    tex_groups: HashMap::new(),
                    block_groups: HashMap::new(),
                    tf: tf_program,
                    outputs,
                    int_outputs: outs,
                };
                let p = self.programs.get_mut(&id).unwrap();
                p.log = l.warnings;
                p.link_status = true;
                p.linked = Some(linked);
            }
        }
    }

    fn uniform_block_binding(&mut self, p: u32, index: u32, binding: u32) {
        let Some(prog) = self.programs.get_mut(&p) else { return self.set_error(INVALID_OPERATION) };
        let Some(l) = prog.linked.as_mut() else { return self.set_error(INVALID_OPERATION) };
        if index as usize >= l.blocks.len() || binding as usize >= MAX_UNIFORM_BUFFER_BINDINGS {
            return self.set_error(INVALID_VALUE);
        }
        l.block_bindings[index as usize] = binding;
    }

    fn uniform(&mut self, loc: i32, kind: u32, count: u32, data: &[u8]) {
        // kind: bits 0-3 components (or matrix: cols * 16 + rows, with bit 8), bits 4-5 base (0 float, 1 int, 2 uint)
        let pid = self.st.program;
        if pid == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        if loc == -1 {
            return;
        }
        let Some(p) = self.programs.get_mut(&pid) else { return self.set_error(INVALID_OPERATION) };
        let Some(l) = p.linked.as_mut() else { return self.set_error(INVALID_OPERATION) };
        let Some(&Location { uniform, element }) = l.locations.get(loc as usize) else { return self.set_error(INVALID_OPERATION) };
        let u = &l.uniforms[uniform as usize];
        let (ty, arr) = (u.ty, u.count);
        let matrix = kind & 0x100 != 0;
        let base = (kind >> 4) & 3;
        let comps = if matrix { 0 } else { kind & 15 };
        let (mc, mr) = if matrix { ((kind >> 4) & 15, kind & 15) } else { (0, 0) };
        let base = if matrix { 0 } else { base };
        // the type must fit
        let scalar = ty.scalar();
        let is_sampler = u.sampler.is_some();
        let ok = if matrix {
            ty.cols == mc && ty.rows == mr
        } else if is_sampler {
            comps == 1 && base == 1
        } else {
            ty.cols == 1
                && ty.rows == comps
                && match scalar {
                    translate::Scalar::Float => base == 0,
                    translate::Scalar::Int => base == 1,
                    translate::Scalar::Uint => base == 2,
                    translate::Scalar::Bool => true,
                }
        };
        if !ok {
            return self.set_error(INVALID_OPERATION);
        }
        let (each_words, cols, rows) = if matrix { ((mc * mr) as usize, mc as usize, mr as usize) } else { (comps as usize, 1, comps as usize) };
        if each_words == 0 || data.len() % 4 != 0 || count == 0 || data.len() / 4 < each_words * count as usize {
            return self.set_error(INVALID_VALUE);
        }
        if count > 1 && arr == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let (vs, fs, sampler) = (u.vs, u.fs, u.sampler);
        let room = arr.max(1).saturating_sub(element);
        let n = (count.min(room)) as usize;
        let words = |w: usize| -> [u8; 4] { [data[w * 4], data[w * 4 + 1], data[w * 4 + 2], data[w * 4 + 3]] };
        if let Some(first) = sampler {
            let units = self.caps.max_combined_texture_units;
            for i in 0..n {
                let v = i32::from_ne_bytes(words(i));
                if v < 0 || v as u32 >= units {
                    self.set_error(INVALID_VALUE);
                    return;
                }
                l.sampler_units[(first + element + i as u32) as usize] = v as u32;
            }
            return;
        }
        let is_bool = scalar == translate::Scalar::Bool;
        let write = |image: &mut Vec<u8>, at: (u32, u32)| {
            let (offset, stride) = at;
            for i in 0..n {
                let base_off = offset as usize + (element as usize + i) * stride.max(16) as usize;
                let from = i * each_words;
                if matrix {
                    for c in 0..cols {
                        for r in 0..rows {
                            let to = base_off + c * 16 + r * 4;
                            if to + 4 <= image.len() {
                                image[to..to + 4].copy_from_slice(&words(from + c * rows + r));
                            }
                        }
                    }
                } else {
                    for k in 0..rows {
                        let to = base_off + k * 4;
                        if to + 4 > image.len() {
                            continue;
                        }
                        let mut w = words(from + k);
                        if is_bool {
                            let nz = if base == 0 { f32::from_ne_bytes(w) != 0.0 } else { u32::from_ne_bytes(w) != 0 };
                            w = (nz as u32).to_ne_bytes();
                        }
                        image[to..to + 4].copy_from_slice(&w);
                    }
                }
            }
        };
        if let Some(at) = vs {
            write(&mut l.vs_image, at);
            l.vs_dirty = true;
        }
        if let Some(at) = fs {
            write(&mut l.fs_image, at);
            l.fs_dirty = true;
        }
    }

    // ---- passes and submits ----

    pub fn ensure_encoder(&mut self) {
        if self.encoder.is_none() {
            self.encoder = Some(self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None }));
        }
    }

    pub fn end_pass(&mut self) {
        self.occlusion_close();
        self.pass = None;
        self.pass_fb = None;
    }

    /// Sends everything recorded.
    pub fn submit(&mut self) {
        self.end_pass();
        self.draws_in_submit = 0;
        if !self.ring_cpu.is_empty() {
            self.queue.write_buffer(&self.ring, 0, &self.ring_cpu);
            self.ring_cpu.clear();
            self.ring_epoch += 1;
        }
        self.belt.finish();
        let occlusion = self.occlusion_resolve();
        if let Some(enc) = self.encoder.take() {
            self.queue.submit(Some(enc.finish()));
        }
        if let Some((staging, slots)) = occlusion {
            self.occlusion_submitted(staging, slots);
        }
        self.belt.recall();
        self.enc_gen += 1;
        // Lets wgpu finish its housekeeping; a long session never waits for it otherwise.
        let _ = self.device.poll(wgpu::PollType::Poll);
    }

    /// The canvas was resized: a new drawing buffer, cleared.
    pub fn resize(&mut self, w: u32, h: u32) {
        let (w, h) = (w.min(self.limits.max_texture), h.min(self.limits.max_texture));
        if self.bb.w == w && self.bb.h == h {
            return;
        }
        self.submit();
        let samples = if self.attrs.antialias { self.limits.max_samples } else { 1 };
        self.bb = make_backbuffer(&self.device, w, h, self.attrs.depth, self.attrs.stencil, samples);
        self.needs_clear = true;
        self.fb_gen += 1;
        self.frames_free.clear();
    }

    pub fn fallback_view(&mut self, dim: wgpu::TextureViewDimension, kind: BindKind) -> (wgpu::TextureView, u64) {
        if let Some(v) = self.fallback.get(&(dim, kind)) {
            return v.clone();
        }
        let format = match kind {
            BindKind::Filterable | BindKind::Unfilterable => wgpu::TextureFormat::Rgba8Unorm,
            BindKind::Sint => wgpu::TextureFormat::Rgba8Sint,
            BindKind::Uint => wgpu::TextureFormat::Rgba8Uint,
            BindKind::Shadow => wgpu::TextureFormat::Depth32Float,
        };
        let cube = matches!(dim, wgpu::TextureViewDimension::Cube);
        let layers = if cube { 6 } else { 1 };
        let dimension = if dim == wgpu::TextureViewDimension::D3 { wgpu::TextureDimension::D3 } else { wgpu::TextureDimension::D2 };
        let tex = self.device.create_texture(&wgpu::TextureDescriptor {
            label: None,
            size: wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: layers },
            mip_level_count: 1,
            sample_count: 1,
            dimension,
            format,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        if matches!(kind, BindKind::Filterable | BindKind::Unfilterable) {
            // opaque black, as GL's incomplete texture reads
            for z in 0..layers {
                self.queue.write_texture(
                    wgpu::TexelCopyTextureInfo { texture: &tex, mip_level: 0, origin: wgpu::Origin3d { x: 0, y: 0, z }, aspect: wgpu::TextureAspect::All },
                    &[0, 0, 0, 255],
                    wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(4), rows_per_image: Some(1) },
                    wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
                );
            }
        }
        let view = tex.create_view(&wgpu::TextureViewDescriptor { dimension: Some(dim), ..Default::default() });
        self.next_token += 1;
        let token = self.next_token | (1 << 62);
        self.fallback.insert((dim, kind), (view.clone(), token));
        (view, token)
    }

    pub fn sampler_for(&mut self, s: SamplerState) -> (wgpu::Sampler, u64) {
        if let Some(x) = self.samplers.get(&s) {
            return x.clone();
        }
        let address = |m: u32| match m {
            CLAMP_TO_EDGE => wgpu::AddressMode::ClampToEdge,
            MIRRORED_REPEAT => wgpu::AddressMode::MirrorRepeat,
            _ => wgpu::AddressMode::Repeat,
        };
        let (min_f, mip_f, uses_mip) = match s.min {
            NEAREST => (wgpu::FilterMode::Nearest, wgpu::MipmapFilterMode::Nearest, false),
            LINEAR => (wgpu::FilterMode::Linear, wgpu::MipmapFilterMode::Nearest, false),
            NEAREST_MIPMAP_NEAREST => (wgpu::FilterMode::Nearest, wgpu::MipmapFilterMode::Nearest, true),
            LINEAR_MIPMAP_NEAREST => (wgpu::FilterMode::Linear, wgpu::MipmapFilterMode::Nearest, true),
            NEAREST_MIPMAP_LINEAR => (wgpu::FilterMode::Nearest, wgpu::MipmapFilterMode::Linear, true),
            _ => (wgpu::FilterMode::Linear, wgpu::MipmapFilterMode::Linear, true),
        };
        let mag_f = if s.mag == NEAREST { wgpu::FilterMode::Nearest } else { wgpu::FilterMode::Linear };
        let (mut lod_min, mut lod_max) = (f32::from_bits(s.min_lod).max(0.0), f32::from_bits(s.max_lod).max(0.0));
        if !uses_mip {
            lod_min = 0.0;
            lod_max = 0.25;
        }
        if lod_max < lod_min {
            lod_max = lod_min;
        }
        let mut anis = f32::from_bits(s.anisotropy).round().clamp(1.0, self.limits.max_anisotropy) as u16;
        if !(min_f == wgpu::FilterMode::Linear && mag_f == wgpu::FilterMode::Linear && mip_f == wgpu::MipmapFilterMode::Linear) {
            anis = 1;
        }
        let compare = if s.compare_mode == COMPARE_REF_TO_TEXTURE { Some(compare_fn(s.compare_func)) } else { None };
        let sampler = self.device.create_sampler(&wgpu::SamplerDescriptor {
            label: None,
            address_mode_u: address(s.wrap_s),
            address_mode_v: address(s.wrap_t),
            address_mode_w: address(s.wrap_r),
            mag_filter: mag_f,
            min_filter: min_f,
            mipmap_filter: mip_f,
            lod_min_clamp: lod_min,
            lod_max_clamp: lod_max,
            compare,
            anisotropy_clamp: anis,
            border_color: None,
        });
        self.next_token += 1;
        let token = self.next_token;
        self.samplers.insert(s, (sampler.clone(), token));
        (sampler, token)
    }
}

pub fn compare_fn(f: u32) -> wgpu::CompareFunction {
    match f {
        0x200 => wgpu::CompareFunction::Never,
        0x201 => wgpu::CompareFunction::Less,
        0x202 => wgpu::CompareFunction::Equal,
        0x203 => wgpu::CompareFunction::LessEqual,
        0x204 => wgpu::CompareFunction::Greater,
        0x205 => wgpu::CompareFunction::NotEqual,
        0x206 => wgpu::CompareFunction::GreaterEqual,
        _ => wgpu::CompareFunction::Always,
    }
}

pub fn buffer_usages() -> wgpu::BufferUsages {
    wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::INDEX | wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::STORAGE
}

pub fn new_buf() -> Buf {
    Buf { gpu: None, shadow: Vec::new(), used_gen: 0, version: 0, kind: 0, usage: 0x88E4, deleted: false, max_index: HashMap::new(), converted: HashMap::new(), expanded: HashMap::new(), gpu_newer: false }
}

pub fn new_tex(target: u32) -> Tex {
    let mut params = SamplerState::default();
    if target == 0 {
        params.min = LINEAR;
    }
    Tex { target, gpu: None, fmt: None, w: 0, h: 0, d: 1, levels: 0, immutable: 0, defined: [0; 6], params, base_level: 0, max_level: 1000, used_gen: 0, generation: 0, views: HashMap::new(), deleted: false, bytes: 0 }
}

pub fn new_rb() -> Rb {
    Rb { gpu: None, view: None, fmt: None, w: 0, h: 0, samples: 1, generation: 0, used_gen: 0, deleted: false, bytes: 0 }
}

pub fn new_program() -> Program {
    Program { vs: 0, fs: 0, bound: HashMap::new(), linked: None, log: String::new(), link_status: false, validate_status: false, deleted: false, use_count: 0, generation: 0, tf_names: Vec::new(), tf_mode: crate::capture::INTERLEAVED_ATTRIBS, }
}

pub fn texel_size(fmt: Fmt) -> u32 {
    fmt.wgpu.block_copy_size(Some(if fmt.is_depth_or_stencil() { wgpu::TextureAspect::DepthOnly } else { wgpu::TextureAspect::All })).unwrap_or(4)
}

pub fn full_levels(w: u32, h: u32, d: u32) -> u32 {
    32 - w.max(h).max(d).max(1).leading_zeros()
}

/// The upload's format and type must be a way to fill this texture.
fn sub_format_ok(fmt: Fmt, format: u32, _ty: u32) -> bool {
    use formats::*;
    match fmt.channels {
        Channels::Rgb => format == RGB || format == RGB_INTEGER || format == SRGB_EXT,
        Channels::Luminance => format == LUMINANCE,
        Channels::LuminanceAlpha => format == LUMINANCE_ALPHA,
        Channels::Alpha => format == ALPHA,
        Channels::Same => match sample_kind(fmt.wgpu) {
            SampleKind::Sint | SampleKind::Uint => matches!(format, RED_INTEGER | RG_INTEGER | RGBA_INTEGER),
            SampleKind::Depth => matches!(format, DEPTH_COMPONENT | DEPTH_STENCIL),
            _ => matches!(format, RED | RG | RGB | RGBA | SRGB_ALPHA_EXT),
        },
    }
}

/// `sampler2D` and friends: the view's dimension, the kind of its texels, shadow.
pub fn sampler_binding_kind(gl: u32) -> (wgpu::TextureViewDimension, SampleKind, bool) {
    use translate::*;
    use wgpu::TextureViewDimension as D;
    match gl {
        GL_SAMPLER_2D => (D::D2, SampleKind::Float, false),
        GL_SAMPLER_CUBE => (D::Cube, SampleKind::Float, false),
        GL_SAMPLER_3D => (D::D3, SampleKind::Float, false),
        GL_SAMPLER_2D_ARRAY => (D::D2Array, SampleKind::Float, false),
        GL_SAMPLER_2D_SHADOW => (D::D2, SampleKind::Depth, true),
        GL_SAMPLER_CUBE_SHADOW => (D::Cube, SampleKind::Depth, true),
        GL_SAMPLER_2D_ARRAY_SHADOW => (D::D2Array, SampleKind::Depth, true),
        GL_INT_SAMPLER_2D => (D::D2, SampleKind::Sint, false),
        GL_INT_SAMPLER_3D => (D::D3, SampleKind::Sint, false),
        GL_INT_SAMPLER_CUBE => (D::Cube, SampleKind::Sint, false),
        GL_INT_SAMPLER_2D_ARRAY => (D::D2Array, SampleKind::Sint, false),
        GL_UNSIGNED_INT_SAMPLER_2D => (D::D2, SampleKind::Uint, false),
        GL_UNSIGNED_INT_SAMPLER_3D => (D::D3, SampleKind::Uint, false),
        GL_UNSIGNED_INT_SAMPLER_CUBE => (D::Cube, SampleKind::Uint, false),
        GL_UNSIGNED_INT_SAMPLER_2D_ARRAY => (D::D2Array, SampleKind::Uint, false),
        _ => (D::D2, SampleKind::Float, false),
    }
}

fn set_sampler_param(s: &mut SamplerState, p: u32, f: f32, v: u32, w2: bool, aniso: bool) -> bool {
    match p {
        TEXTURE_MAG_FILTER => {
            if !matches!(v, NEAREST | LINEAR) {
                return false;
            }
            s.mag = v;
        }
        TEXTURE_MIN_FILTER => {
            if !matches!(v, NEAREST | LINEAR | NEAREST_MIPMAP_NEAREST | LINEAR_MIPMAP_NEAREST | NEAREST_MIPMAP_LINEAR | LINEAR_MIPMAP_LINEAR) {
                return false;
            }
            s.min = v;
        }
        TEXTURE_WRAP_S | TEXTURE_WRAP_T | TEXTURE_WRAP_R => {
            if !matches!(v, REPEAT | CLAMP_TO_EDGE | MIRRORED_REPEAT) || (p == TEXTURE_WRAP_R && !w2) {
                return false;
            }
            match p {
                TEXTURE_WRAP_S => s.wrap_s = v,
                TEXTURE_WRAP_T => s.wrap_t = v,
                _ => s.wrap_r = v,
            }
        }
        TEXTURE_COMPARE_MODE if w2 => {
            if !matches!(v, NONE | COMPARE_REF_TO_TEXTURE) {
                return false;
            }
            s.compare_mode = v;
        }
        TEXTURE_COMPARE_FUNC if w2 => {
            if !(0x200..=0x207).contains(&v) {
                return false;
            }
            s.compare_func = v;
        }
        TEXTURE_MIN_LOD if w2 => s.min_lod = f.to_bits(),
        TEXTURE_MAX_LOD if w2 => s.max_lod = f.to_bits(),
        TEXTURE_MAX_ANISOTROPY if aniso => {
            if f < 1.0 {
                return false;
            }
            s.anisotropy = f.to_bits();
        }
        _ => return false,
    }
    true
}

pub fn make_backbuffer(device: &wgpu::Device, w: u32, h: u32, depth: bool, stencil: bool, samples: u32) -> Backbuffer {
    let (cw, ch) = (w.max(1), h.max(1));
    let size = wgpu::Extent3d { width: cw, height: ch, depth_or_array_layers: 1 };
    let color = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("canvas"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC | wgpu::TextureUsages::COPY_DST | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    });
    let color_view = color.create_view(&wgpu::TextureViewDescriptor::default());
    let msaa_view = if samples > 1 {
        let t = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("canvas msaa"),
            size,
            mip_level_count: 1,
            sample_count: samples,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        Some(t.create_view(&wgpu::TextureViewDescriptor::default()))
    } else {
        None
    };
    let format_ds = if depth || stencil {
        Some(if stencil { wgpu::TextureFormat::Depth24PlusStencil8 } else { wgpu::TextureFormat::Depth24Plus })
    } else {
        None
    };
    let (depth_t, depth_view) = match format_ds {
        Some(f) => {
            let t = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("canvas depth"),
                size,
                mip_level_count: 1,
                sample_count: samples,
                dimension: wgpu::TextureDimension::D2,
                format: f,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            let v = t.create_view(&wgpu::TextureViewDescriptor::default());
            (Some(t), Some(v))
        }
        None => (None, None),
    };
    Backbuffer { color, color_view, msaa_view, depth: depth_t, depth_view, w: cw, h: ch, format_ds }
}
