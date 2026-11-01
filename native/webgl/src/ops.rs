//! The command stream of a realm (native/js/odin/web_webgl.js writes it, gl.rs reads it): 32-bit words, an operation's number
//! then its arguments; bytes are a length in bytes then the bytes, padded to a word. The numbers are the same in both places.

pub const ACTIVE_TEXTURE: u32 = 1;
pub const ATTACH_SHADER: u32 = 2;
pub const DETACH_SHADER: u32 = 3;
pub const BIND_ATTRIB_LOCATION: u32 = 4;
pub const BIND_BUFFER: u32 = 5;
pub const BIND_FRAMEBUFFER: u32 = 6;
pub const BIND_RENDERBUFFER: u32 = 7;
pub const BIND_TEXTURE: u32 = 8;
pub const BLEND_COLOR: u32 = 9;
pub const BLEND_EQUATION: u32 = 10;
pub const BLEND_FUNC: u32 = 11;
pub const BUFFER_DATA: u32 = 12;
pub const BUFFER_SUB_DATA: u32 = 13;
pub const CLEAR: u32 = 14;
pub const CLEAR_COLOR: u32 = 15;
pub const CLEAR_DEPTH: u32 = 16;
pub const CLEAR_STENCIL: u32 = 17;
pub const COLOR_MASK: u32 = 18;
pub const COMPILE_SHADER: u32 = 19;
pub const SHADER_SOURCE: u32 = 20;
pub const COMPRESSED_TEX_IMAGE: u32 = 21;
pub const COMPRESSED_TEX_SUB_IMAGE: u32 = 22;
pub const COPY_TEX_IMAGE: u32 = 23;
pub const COPY_TEX_SUB_IMAGE: u32 = 24;
pub const DELETE_BUFFER: u32 = 25;
pub const DELETE_FRAMEBUFFER: u32 = 26;
pub const DELETE_PROGRAM: u32 = 27;
pub const DELETE_RENDERBUFFER: u32 = 28;
pub const DELETE_SHADER: u32 = 29;
pub const DELETE_TEXTURE: u32 = 30;
pub const CULL_FACE: u32 = 31;
pub const DEPTH_FUNC: u32 = 32;
pub const DEPTH_MASK: u32 = 33;
pub const DEPTH_RANGE: u32 = 34;
pub const DISABLE: u32 = 35;
pub const ENABLE: u32 = 36;
pub const DISABLE_ATTRIB: u32 = 37;
pub const ENABLE_ATTRIB: u32 = 38;
pub const DRAW_ARRAYS: u32 = 39;
pub const DRAW_ELEMENTS: u32 = 40;
pub const FRAMEBUFFER_RENDERBUFFER: u32 = 42;
pub const FRAMEBUFFER_TEXTURE: u32 = 43;
pub const FRONT_FACE: u32 = 44;
pub const GENERATE_MIPMAP: u32 = 45;
pub const HINT: u32 = 46;
pub const LINE_WIDTH: u32 = 47;
pub const LINK_PROGRAM: u32 = 48;
pub const PIXEL_STOREI: u32 = 49;
pub const POLYGON_OFFSET: u32 = 50;
pub const RENDERBUFFER_STORAGE: u32 = 51;
pub const SAMPLE_COVERAGE: u32 = 52;
pub const SCISSOR: u32 = 53;
pub const STENCIL_FUNC: u32 = 54;
pub const STENCIL_MASK: u32 = 55;
pub const STENCIL_OP: u32 = 56;
pub const TEX_IMAGE: u32 = 57;
pub const TEX_SUB_IMAGE: u32 = 58;
pub const TEX_IMAGE_SOURCE: u32 = 59;
pub const TEX_PARAMETER_I: u32 = 60;
pub const TEX_PARAMETER_F: u32 = 61;
pub const UNIFORM: u32 = 62;
pub const USE_PROGRAM: u32 = 63;
pub const VERTEX_ATTRIB: u32 = 65;
pub const VERTEX_ATTRIB_POINTER: u32 = 66;
pub const VERTEX_ATTRIB_DIVISOR: u32 = 67;
pub const VIEWPORT: u32 = 68;
pub const BIND_VAO: u32 = 69;
pub const DELETE_VAO: u32 = 70;
pub const ERROR: u32 = 71;
pub const BLIT_FRAMEBUFFER: u32 = 72;
pub const FRAMEBUFFER_TEXTURE_LAYER: u32 = 73;
pub const READ_BUFFER: u32 = 75;
pub const DRAW_BUFFERS: u32 = 76;
pub const CLEAR_BUFFER: u32 = 77;
pub const BIND_BUFFER_RANGE: u32 = 78;
pub const UNIFORM_BLOCK_BINDING: u32 = 79;
pub const TEX_STORAGE: u32 = 80;
pub const COPY_BUFFER_SUB_DATA: u32 = 81;
pub const BIND_SAMPLER: u32 = 82;
pub const DELETE_SAMPLER: u32 = 83;
pub const SAMPLER_PARAMETER_I: u32 = 84;
pub const SAMPLER_PARAMETER_F: u32 = 85;
pub const ENABLE_EXTENSION: u32 = 86;
pub const COPY_TEX_SUB_IMAGE_3D: u32 = 87;

// Queries: the first word of a query; they answer with bytes.
pub const Q_ERROR: u32 = 1;
pub const Q_PARAMETER: u32 = 2;
pub const Q_SHADER: u32 = 3;
pub const Q_SHADER_LOG: u32 = 4;
pub const Q_PROGRAM: u32 = 5;
pub const Q_PROGRAM_LOG: u32 = 6;
pub const Q_ACTIVE_ATTRIB: u32 = 7;
pub const Q_ACTIVE_UNIFORM: u32 = 8;
pub const Q_ATTRIB_LOCATION: u32 = 9;
pub const Q_UNIFORM_LOCATION: u32 = 10;
pub const Q_UNIFORM: u32 = 11;
pub const Q_FRAMEBUFFER_STATUS: u32 = 12;
pub const Q_READ_PIXELS: u32 = 13;
pub const Q_TEX_PARAMETER: u32 = 14;
pub const Q_BUFFER_PARAMETER: u32 = 15;
pub const Q_RENDERBUFFER_PARAMETER: u32 = 16;
pub const Q_ATTACHMENT_PARAMETER: u32 = 17;
pub const Q_VERTEX_ATTRIB: u32 = 18;
pub const Q_SAMPLER_PARAMETER: u32 = 19;
pub const Q_INDEXED: u32 = 20;
pub const Q_BUFFER_SUB_DATA: u32 = 21;
pub const Q_BLOCK: u32 = 22;
pub const Q_UNIFORM_INDICES: u32 = 23;
pub const Q_ACTIVE_UNIFORMS: u32 = 24;
pub const Q_FINISH: u32 = 25;
pub const Q_SNAPSHOT: u32 = 26;
pub const Q_VALIDATE: u32 = 27;
pub const Q_FORMAT_SAMPLES: u32 = 28;
pub const Q_FRAG_DATA_LOCATION: u32 = 29;

// How a value travels in the answer of a query.
pub const TAG_NULL: u32 = 0;
pub const TAG_INT: u32 = 1;
pub const TAG_FLOAT: u32 = 2;
pub const TAG_BOOL: u32 = 3;
pub const TAG_INTS: u32 = 4;
pub const TAG_FLOATS: u32 = 5;
pub const TAG_BOOLS: u32 = 6;
pub const TAG_STRING: u32 = 7;
pub const TAG_OBJECT: u32 = 8;
pub const TAG_UINT: u32 = 9;
pub const TAG_UINTS: u32 = 10;

// The kinds of object a query can name (TAG_OBJECT).
pub const OBJ_BUFFER: u32 = 1;
pub const OBJ_FRAMEBUFFER: u32 = 2;
pub const OBJ_RENDERBUFFER: u32 = 3;
pub const OBJ_TEXTURE: u32 = 4;
pub const OBJ_PROGRAM: u32 = 5;
pub const OBJ_VAO: u32 = 6;
pub const OBJ_SAMPLER: u32 = 7;
pub const OBJ_SHADER: u32 = 8;

/// Reads a stream. A truncated or malformed one comes from something other than our JavaScript (a Wasm module of the page can
/// call the host function): the context stops.
pub struct Reader<'a> {
    pub d: &'a [u8],
    pub i: usize,
}

impl<'a> Reader<'a> {
    pub fn new(d: &'a [u8]) -> Self {
        Reader { d, i: 0 }
    }
    pub fn done(&self) -> bool {
        self.i >= self.d.len()
    }
    pub fn u(&mut self) -> Option<u32> {
        let s = self.d.get(self.i..self.i + 4)?;
        self.i += 4;
        Some(u32::from_ne_bytes([s[0], s[1], s[2], s[3]]))
    }
    pub fn i(&mut self) -> Option<i32> {
        self.u().map(|v| v as i32)
    }
    pub fn f(&mut self) -> Option<f32> {
        self.u().map(f32::from_bits)
    }
    pub fn bytes(&mut self) -> Option<&'a [u8]> {
        let n = self.u()? as usize;
        let s = self.d.get(self.i..self.i.checked_add(n)?)?;
        self.i += n.checked_add(3)? & !3;
        Some(s)
    }
}
