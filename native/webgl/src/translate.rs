//! GLSL ES 1.00 and 3.00 to what naga's GLSL front end reads (Vulkan-flavoured GLSL 450), and what WebGL needs to know of a
//! shader: its attributes, varyings, uniforms and samplers.
//!
//! naga has the type checker and the lowering, it does not read GLSL ES: the source goes through the preprocessor (pp-rs,
//! naga's own), then a rewrite of the token stream. No expression is parsed here; what is done is at the level of
//! declarations:
//!   - attribute / varying / in / out get locations (the link decides them: a shader is translated again when linked);
//!   - uniforms outside blocks go into a block per stage (binding 0: vertex, 1: fragment), std140: the context keeps the bytes
//!     of each block and writes them to a ring per draw. Structures, global constants and uniforms are hoisted above the code
//!     (GL lets them come in any order, a block is one declaration);
//!   - a sampler becomes a texture and a sampler (naga has no combined ones), `texture2D(map, uv)` becomes
//!     `texture(sampler2D(map_t, map_s), uv)`, and a sampler passed to a function of the shader two parameters;
//!   - what std140 or naga's uniforms cannot hold (bool, matrices of 2 rows) is held as uint and vec4 in the block and copied to a
//!     private variable of the declared type when `main` starts;
//!   - `main` is wrapped: the wrapper turns GL's clip space (z in -w..w, y up with row 0 at the bottom) into wgpu's. Everything
//!     rendered is stored bottom row first, as GL thinks of it, so that textures rendered to read back the same way;
//!   - gl_PointSize and gl_PointCoord exist on neither backend: a variant of the vertex shader draws each point as a quad.
//!
//! Hostile input: the source length, the tokens after macro expansion and the nesting are bounded (naga recurses), and
//! this code runs on the context's own thread with a large stack, its panics caught.

use naga::front::glsl::{Frontend, Options};
use naga::{ShaderStage, TypeInner};
use pp_rs::pp::Preprocessor;
use pp_rs::token::{Punct, TokenValue};
use std::collections::{HashMap, HashSet};
use std::fmt::Write;

/// The longest source a shader may have, in bytes.
pub const MAX_SOURCE_BYTES: usize = 2 * 1024 * 1024;
/// The most tokens after macro expansion (a macro can double what it is given).
pub const MAX_TOKENS: usize = 2_000_000;
/// The deepest nesting of parentheses, brackets and braces (naga's parser and lowering recurse).
pub const MAX_NESTING: usize = 128;
/// The longest statement in tokens (`a+a+a+...` builds an expression as deep as it is long, recursion again).
pub const MAX_STATEMENT_TOKENS: usize = 60_000;
/// The most members a block of default uniforms may flatten to.
pub const MAX_UNIFORM_LEAVES: usize = 16 * 1024;
/// The longest identifier (WebGL: 256 for GLSL ES 1.00, 1024 for GLSL ES 3.00).
pub const MAX_IDENT_ES1: usize = 256;
pub const MAX_IDENT_ES3: usize = 1024;
/// How deep structures may nest (GLSL ES 1.00 requires 4; WebGL 1 limits it there).
pub const MAX_STRUCT_NESTING: usize = 16;

/// Binding of the block of default uniforms of a stage, in group 0.
pub const GROUP_UNIFORMS: u32 = 0;
pub const GROUP_TEXTURES: u32 = 1;
pub const GROUP_BLOCKS: u32 = 2;
pub const BINDING_VS_UNIFORMS: u32 = 0;
pub const BINDING_FS_UNIFORMS: u32 = 1;
/// Offset of the viewport's size in the vertex stage's block: its first member, reserved (the quads of points need it).
pub const VS_VIEWPORT_MEMBER: &str = "_wr_viewport";

/// Prefix of what this translator adds; a shader may not declare it.
const PREFIX: &str = "_wr_";

// GL's enum values of types (getActiveUniform, getActiveAttrib).
pub const GL_FLOAT: u32 = 0x1406;
pub const GL_INT: u32 = 0x1404;
pub const GL_UNSIGNED_INT: u32 = 0x1405;
pub const GL_BOOL: u32 = 0x8B56;
pub const GL_FLOAT_VEC2: u32 = 0x8B50;
pub const GL_FLOAT_VEC3: u32 = 0x8B51;
pub const GL_FLOAT_VEC4: u32 = 0x8B52;
pub const GL_INT_VEC2: u32 = 0x8B53;
pub const GL_INT_VEC3: u32 = 0x8B54;
pub const GL_INT_VEC4: u32 = 0x8B55;
pub const GL_BOOL_VEC2: u32 = 0x8B57;
pub const GL_BOOL_VEC3: u32 = 0x8B58;
pub const GL_BOOL_VEC4: u32 = 0x8B59;
pub const GL_FLOAT_MAT2: u32 = 0x8B5A;
pub const GL_FLOAT_MAT3: u32 = 0x8B5B;
pub const GL_FLOAT_MAT4: u32 = 0x8B5C;
pub const GL_SAMPLER_2D: u32 = 0x8B5E;
pub const GL_SAMPLER_CUBE: u32 = 0x8B60;
pub const GL_SAMPLER_3D: u32 = 0x8B5F;
pub const GL_SAMPLER_2D_SHADOW: u32 = 0x8B62;
pub const GL_UNSIGNED_INT_VEC2: u32 = 0x8DC6;
pub const GL_UNSIGNED_INT_VEC3: u32 = 0x8DC7;
pub const GL_UNSIGNED_INT_VEC4: u32 = 0x8DC8;
pub const GL_FLOAT_MAT2X3: u32 = 0x8B65;
pub const GL_FLOAT_MAT2X4: u32 = 0x8B66;
pub const GL_FLOAT_MAT3X2: u32 = 0x8B67;
pub const GL_FLOAT_MAT3X4: u32 = 0x8B68;
pub const GL_FLOAT_MAT4X2: u32 = 0x8B69;
pub const GL_FLOAT_MAT4X3: u32 = 0x8B6A;
pub const GL_SAMPLER_2D_ARRAY: u32 = 0x8DC1;
pub const GL_SAMPLER_2D_ARRAY_SHADOW: u32 = 0x8DC4;
pub const GL_SAMPLER_CUBE_SHADOW: u32 = 0x8DC5;
pub const GL_INT_SAMPLER_2D: u32 = 0x8DCA;
pub const GL_INT_SAMPLER_3D: u32 = 0x8DCB;
pub const GL_INT_SAMPLER_CUBE: u32 = 0x8DCC;
pub const GL_INT_SAMPLER_2D_ARRAY: u32 = 0x8DCF;
pub const GL_UNSIGNED_INT_SAMPLER_2D: u32 = 0x8DD2;
pub const GL_UNSIGNED_INT_SAMPLER_3D: u32 = 0x8DD3;
pub const GL_UNSIGNED_INT_SAMPLER_CUBE: u32 = 0x8DD4;
pub const GL_UNSIGNED_INT_SAMPLER_2D_ARRAY: u32 = 0x8DD7;

/// The stage of a shader in this crate's terms.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stage {
    Vertex,
    Fragment,
}

/// What a context may offer to shaders (its version, the extensions the page enabled, its limits).
#[derive(Clone, Debug)]
pub struct Caps {
    pub webgl2: bool,
    pub standard_derivatives: bool,
    pub frag_depth: bool,
    pub shader_texture_lod: bool,
    pub draw_buffers: bool,
    pub max_vertex_attribs: u32,
    pub max_vertex_uniform_vectors: u32,
    pub max_varying_vectors: u32,
    pub max_vertex_texture_units: u32,
    pub max_combined_texture_units: u32,
    pub max_texture_units: u32,
    pub max_fragment_uniform_vectors: u32,
    pub max_draw_buffers: u32,
}

impl Default for Caps {
    fn default() -> Self {
        Caps {
            webgl2: true,
            standard_derivatives: true,
            frag_depth: true,
            shader_texture_lod: true,
            draw_buffers: true,
            max_vertex_attribs: 16,
            max_vertex_uniform_vectors: 1024,
            max_varying_vectors: 15,
            max_vertex_texture_units: 16,
            max_combined_texture_units: 32,
            max_texture_units: 16,
            max_fragment_uniform_vectors: 1024,
            max_draw_buffers: 8,
        }
    }
}

/// A sampler type: its GL value and what it becomes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SamplerKind {
    pub gl: u32,
    pub texture: &'static str,
    pub sampler: &'static str,
    pub combined: &'static str,
}

fn sampler_kind(name: &str) -> Option<SamplerKind> {
    let k = |gl, texture, sampler, combined| Some(SamplerKind { gl, texture, sampler, combined });
    match name {
        "sampler2D" => k(GL_SAMPLER_2D, "texture2D", "sampler", "sampler2D"),
        "samplerCube" => k(GL_SAMPLER_CUBE, "textureCube", "sampler", "samplerCube"),
        "sampler3D" => k(GL_SAMPLER_3D, "texture3D", "sampler", "sampler3D"),
        "sampler2DArray" => k(GL_SAMPLER_2D_ARRAY, "texture2DArray", "sampler", "sampler2DArray"),
        "sampler2DShadow" => k(GL_SAMPLER_2D_SHADOW, "texture2D", "samplerShadow", "sampler2DShadow"),
        "samplerCubeShadow" => k(GL_SAMPLER_CUBE_SHADOW, "textureCube", "samplerShadow", "samplerCubeShadow"),
        "sampler2DArrayShadow" => k(GL_SAMPLER_2D_ARRAY_SHADOW, "texture2DArray", "samplerShadow", "sampler2DArrayShadow"),
        "isampler2D" => k(GL_INT_SAMPLER_2D, "itexture2D", "sampler", "isampler2D"),
        "isampler3D" => k(GL_INT_SAMPLER_3D, "itexture3D", "sampler", "isampler3D"),
        "isamplerCube" => k(GL_INT_SAMPLER_CUBE, "itextureCube", "sampler", "isamplerCube"),
        "isampler2DArray" => k(GL_INT_SAMPLER_2D_ARRAY, "itexture2DArray", "sampler", "isampler2DArray"),
        "usampler2D" => k(GL_UNSIGNED_INT_SAMPLER_2D, "utexture2D", "sampler", "usampler2D"),
        "usampler3D" => k(GL_UNSIGNED_INT_SAMPLER_3D, "utexture3D", "sampler", "usampler3D"),
        "usamplerCube" => k(GL_UNSIGNED_INT_SAMPLER_CUBE, "utextureCube", "sampler", "usamplerCube"),
        "usampler2DArray" => k(GL_UNSIGNED_INT_SAMPLER_2D_ARRAY, "utexture2DArray", "sampler", "usampler2DArray"),
        _ => None,
    }
}

/// A type of a uniform, attribute or varying: its GL value, columns and rows (1 and n for vectors, 1 and 1 for scalars).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BasicType {
    pub gl: u32,
    pub cols: u32,
    pub rows: u32,
}

/// The scalar kind of a type's components.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scalar {
    Float,
    Int,
    Uint,
    Bool,
}

impl BasicType {
    pub fn scalar(&self) -> Scalar {
        match self.gl {
            GL_INT | GL_INT_VEC2 | GL_INT_VEC3 | GL_INT_VEC4 => Scalar::Int,
            GL_UNSIGNED_INT | GL_UNSIGNED_INT_VEC2 | GL_UNSIGNED_INT_VEC3 | GL_UNSIGNED_INT_VEC4 => Scalar::Uint,
            GL_BOOL | GL_BOOL_VEC2 | GL_BOOL_VEC3 | GL_BOOL_VEC4 => Scalar::Bool,
            _ => Scalar::Float,
        }
    }
}

fn basic_type(name: &str) -> Option<BasicType> {
    let t = |gl, cols, rows| Some(BasicType { gl, cols, rows });
    match name {
        "float" => t(GL_FLOAT, 1, 1),
        "int" => t(GL_INT, 1, 1),
        "uint" => t(GL_UNSIGNED_INT, 1, 1),
        "bool" => t(GL_BOOL, 1, 1),
        "vec2" => t(GL_FLOAT_VEC2, 1, 2),
        "vec3" => t(GL_FLOAT_VEC3, 1, 3),
        "vec4" => t(GL_FLOAT_VEC4, 1, 4),
        "ivec2" => t(GL_INT_VEC2, 1, 2),
        "ivec3" => t(GL_INT_VEC3, 1, 3),
        "ivec4" => t(GL_INT_VEC4, 1, 4),
        "uvec2" => t(GL_UNSIGNED_INT_VEC2, 1, 2),
        "uvec3" => t(GL_UNSIGNED_INT_VEC3, 1, 3),
        "uvec4" => t(GL_UNSIGNED_INT_VEC4, 1, 4),
        "bvec2" => t(GL_BOOL_VEC2, 1, 2),
        "bvec3" => t(GL_BOOL_VEC3, 1, 3),
        "bvec4" => t(GL_BOOL_VEC4, 1, 4),
        "mat2" | "mat2x2" => t(GL_FLOAT_MAT2, 2, 2),
        "mat3" | "mat3x3" => t(GL_FLOAT_MAT3, 3, 3),
        "mat4" | "mat4x4" => t(GL_FLOAT_MAT4, 4, 4),
        "mat2x3" => t(GL_FLOAT_MAT2X3, 2, 3),
        "mat2x4" => t(GL_FLOAT_MAT2X4, 2, 4),
        "mat3x2" => t(GL_FLOAT_MAT3X2, 3, 2),
        "mat3x4" => t(GL_FLOAT_MAT3X4, 3, 4),
        "mat4x2" => t(GL_FLOAT_MAT4X2, 4, 2),
        "mat4x3" => t(GL_FLOAT_MAT4X3, 4, 3),
        _ => None,
    }
}

/// Names that are ordinary identifiers in GLSL ES but keywords or types of naga's front end: renamed everywhere.
fn clashes_with_naga(name: &str, es3: bool) -> bool {
    match name {
        "sampler" | "samplerShadow" | "buffer" | "shared" | "restrict" | "readonly" | "writeonly" | "noperspective" | "double"
        | "float16_t" | "sample" | "common" | "partition" | "active" | "filter" | "input" | "output" | "hvec2" | "hvec3"
        | "hvec4" | "fvec2" | "fvec3" | "fvec4" | "dvec2" | "dvec3" | "dvec4" | "dmat2" | "dmat3" | "dmat4" | "image1D"
        | "image2D" | "image3D" | "texture1D" | "texture3D" | "texture1DArray" | "texture2DArray" | "texture2DMS"
        | "textureCubeArray" | "itexture2D" | "utexture2D" | "itexture3D" | "utexture3D" | "itextureCube" | "utextureCube" => true,
        "uint" | "uvec2" | "uvec3" | "uvec4" | "texture" | "flat" | "smooth" | "centroid" | "layout" | "switch" | "case" | "default" => !es3,
        _ => false,
    }
}

/// Words reserved by GLSL ES itself: a shader that uses one does not compile.
fn reserved_word(name: &str, es3: bool) -> bool {
    let both = matches!(
        name,
        "asm" | "class" | "union" | "enum" | "typedef" | "template" | "this" | "goto" | "inline" | "noinline" | "volatile"
            | "public" | "static" | "extern" | "external" | "interface" | "long" | "short" | "half" | "fixed" | "unsigned"
            | "superp" | "input" | "output" | "hvec2" | "hvec3" | "hvec4" | "fvec2" | "fvec3" | "fvec4" | "sampler3DRect"
            | "sizeof" | "cast" | "namespace" | "using"
    );
    if both {
        return true;
    }
    if es3 {
        return matches!(name, "attribute" | "varying" | "coherent" | "restrict" | "readonly" | "writeonly" | "resource"
            | "atomic_uint" | "noperspective" | "patch" | "sample" | "subroutine" | "common" | "partition" | "active"
            | "filter" | "image1D" | "image2D" | "image3D" | "imageCube" | "dvec2" | "dvec3" | "dvec4" | "dmat2" | "dmat3"
            | "dmat4" | "double" | "sampler1D" | "sampler1DShadow" | "samplerBuffer" | "gl_FragColor" | "gl_FragData");
    }
    false
}

// ---- tokens ----

#[derive(Clone, Debug, PartialEq)]
enum T {
    Id(String),
    Int(u64, bool),
    Float(f32),
    P(Punct),
}

#[derive(Clone, Debug)]
struct Tok {
    t: T,
    line: u32,
}

fn punct_text(p: Punct) -> &'static str {
    use Punct::*;
    match p {
        AddAssign => "+=",
        SubAssign => "-=",
        MulAssign => "*=",
        DivAssign => "/=",
        ModAssign => "%=",
        LeftShiftAssign => "<<=",
        RightShiftAssign => ">>=",
        AndAssign => "&=",
        XorAssign => "^=",
        OrAssign => "|=",
        Increment => "++",
        Decrement => "--",
        LogicalAnd => "&&",
        LogicalOr => "||",
        LogicalXor => "^^",
        LessEqual => "<=",
        GreaterEqual => ">=",
        EqualEqual => "==",
        NotEqual => "!=",
        LeftShift => "<<",
        RightShift => ">>",
        LeftBrace => "{",
        RightBrace => "}",
        LeftParen => "(",
        RightParen => ")",
        LeftBracket => "[",
        RightBracket => "]",
        LeftAngle => "<",
        RightAngle => ">",
        Semicolon => ";",
        Comma => ",",
        Colon => ":",
        Dot => ".",
        Equal => "=",
        Bang => "!",
        Minus => "-",
        Tilde => "~",
        Plus => "+",
        Star => "*",
        Slash => "/",
        Percent => "%",
        Pipe => "|",
        Caret => "^",
        Ampersand => "&",
        Question => "?",
    }
}

fn is_p(t: Option<&Tok>, p: Punct) -> bool {
    matches!(t, Some(Tok { t: T::P(q), .. }) if *q == p)
}

fn id_of(t: Option<&Tok>) -> Option<&str> {
    match t {
        Some(Tok { t: T::Id(s), .. }) => Some(s.as_str()),
        _ => None,
    }
}

fn is_precision_word(s: &str) -> bool {
    matches!(s, "highp" | "mediump" | "lowp")
}

// ---- what a shader declares ----

/// A declared variable's type: a basic type or a structure's name.
#[derive(Clone, Debug, PartialEq)]
pub enum TypeRef {
    Basic(BasicType, String),
    Struct(String),
}

#[derive(Clone, Debug)]
struct Field {
    ty: TypeRef,
    name: String,
    array: Vec<Tok>,
}

#[derive(Clone, Debug)]
struct StructDef {
    name: String,
    fields: Vec<Field>,
    needs_copy: bool,
}

/// An attribute, varying or output.
#[derive(Clone, Debug)]
pub struct InOut {
    pub name: String,
    pub ty: BasicType,
    /// The array's length; 0 when it is not an array.
    pub array: u32,
    /// `layout(location = n)`
    pub location: Option<u32>,
    pub flat: bool,
    pub centroid: bool,
    pub active: bool,
    qualifiers: Vec<String>,
    type_name: String,
    array_toks: Vec<Tok>,
}

impl InOut {
    /// How many locations it takes.
    pub fn slots(&self) -> u32 {
        self.ty.cols * self.array.max(1)
    }
}

/// A default uniform as declared.
#[derive(Clone, Debug)]
struct UniformDecl {
    name: String,
    mangled: String,
    ty: TypeRef,
    array: Vec<Tok>,
    active: bool,
}

/// A sampler uniform: `count` 0 when it is not an array.
#[derive(Clone, Debug)]
pub struct SamplerDecl {
    pub name: String,
    pub mangled: String,
    pub kind: SamplerKind,
    pub count: u32,
    pub active: bool,
}

/// A leaf of a default uniform: what a location names.
#[derive(Clone, Debug, PartialEq)]
pub struct UniformLeaf {
    /// The name as getActiveUniform gives it (`a.b[0].c`, `d[0]` for an array of basic things).
    pub name: String,
    pub ty: BasicType,
    /// The array's length; 0 when it is not an array.
    pub count: u32,
    /// Byte offset in the stage's block.
    pub offset: u32,
    /// Bytes between the elements of an array.
    pub stride: u32,
}

/// A member of a block of uniforms (GLSL ES 3.00).
#[derive(Clone, Debug, PartialEq)]
pub struct BlockMember {
    pub name: String,
    pub ty: BasicType,
    pub count: u32,
    pub offset: u32,
    pub array_stride: u32,
    pub matrix_stride: u32,
}

/// A block of uniforms as a page sees it.
#[derive(Clone, Debug)]
pub struct BlockInfo {
    pub name: String,
    pub size: u32,
    pub members: Vec<BlockMember>,
    pub active: bool,
}

#[derive(Clone, Debug)]
struct BlockDecl {
    name: String,
    instance: Option<String>,
    body: Vec<Tok>,
    array: Vec<Tok>,
}

/// Choices of a link: where attributes, varyings, samplers and blocks go.
#[derive(Clone, Debug, Default)]
pub struct LinkMap {
    pub attributes: HashMap<String, u32>,
    pub varyings: HashMap<String, u32>,
    /// A sampler's name (`s`, or `s[1]`) to its index in group 1 (the texture is at 2 * i, the sampler at 2 * i + 1).
    pub samplers: HashMap<String, u32>,
    pub blocks: HashMap<String, u32>,
    /// Where gl_PointCoord travels.
    pub point_coord: u32,
    /// The vertex stage: draw each vertex as the quad of a point.
    pub points: bool,
}

/// A shader read and rewritten, ready to be translated for a link. Immutable.
#[derive(Clone, Debug)]
pub struct Shader {
    pub stage: Stage,
    pub es3: bool,
    pub inputs: Vec<InOut>,
    pub outputs: Vec<InOut>,
    pub samplers: Vec<SamplerDecl>,
    pub uses_frag_coord_point: bool,
    pub uses_point_size: bool,
    /// Non-fatal remarks for the info log.
    pub warnings: Vec<String>,
    pub leaves: Vec<UniformLeaf>,
    pub block_size: u32,
    pub blocks: Vec<BlockInfo>,
    toks: Vec<Tok>,
    uniforms: Vec<UniformDecl>,
    block_decls: Vec<BlockDecl>,
    structs: Vec<StructDef>,
    consts: HashMap<String, i64>,
    frag_data_used: Vec<u32>,
    hoisted: Vec<(usize, usize)>,
    decl_ranges: Vec<(usize, usize)>,
    renames: HashMap<String, String>,
}

/// One log line, as `ERROR: 0:line: message`.
fn log_line(line: u32, msg: &str) -> String {
    format!("ERROR: 0:{}: {}\n", line, msg)
}

/// Line number of a byte offset of the source.
fn line_starts(src: &str) -> Vec<u32> {
    let mut v = vec![0u32];
    for (i, b) in src.bytes().enumerate() {
        if b == b'\n' {
            v.push(i as u32 + 1);
        }
    }
    v
}

fn line_of(starts: &[u32], off: u32) -> u32 {
    match starts.binary_search(&off) {
        Ok(i) => i as u32 + 1,
        Err(i) => i as u32,
    }
}

/// `#version` of a source: true for 300 es. Anything before the directive other than white space and comments is the
/// preprocessor's or the parser's business. GLSL ES 3.00 requires it on the first line.
fn detect_es3(src: &str) -> Result<bool, String> {
    let mut rest = src;
    let mut line = 1;
    loop {
        let t = rest.trim_start_matches([' ', '\t', '\r']);
        if let Some(r) = t.strip_prefix('\n') {
            rest = r;
            line += 1;
            continue;
        }
        if let Some(r) = t.strip_prefix("//") {
            rest = r.find('\n').map(|i| &r[i..]).unwrap_or("");
            continue;
        }
        if let Some(r) = t.strip_prefix("/*") {
            match r.find("*/") {
                Some(i) => {
                    line += r[..i].matches('\n').count();
                    rest = &r[i + 2..];
                    continue;
                }
                None => return Ok(false),
            }
        }
        let Some(r) = t.strip_prefix('#') else { return Ok(false) };
        let r = r.trim_start_matches([' ', '\t']);
        let Some(r) = r.strip_prefix("version") else { return Ok(false) };
        let directive = r.split('\n').next().unwrap_or("");
        let words: Vec<&str> = directive.split_whitespace().collect();
        return match words.as_slice() {
            ["100"] => Ok(false),
            ["300", "es"] => {
                if line != 1 {
                    Err(log_line(line as u32, "#version 300 es must be on the first line"))
                } else {
                    Ok(true)
                }
            }
            _ => Err(log_line(line as u32, "unsupported shader version")),
        };
    }
}

/// Runs the preprocessor: tokens with their lines. `#version` and `#extension` are consumed here.
fn preprocess(src: &str, stage: Stage, caps: &Caps, es3: bool) -> Result<(Vec<Tok>, Vec<String>), String> {
    let mut pp = Preprocessor::new(src);
    let ok = pp.add_define("GL_ES", "1").is_ok()
        && pp.add_define("__VERSION__", if es3 { "300" } else { "100" }).is_ok()
        && pp.add_define("GL_FRAGMENT_PRECISION_HIGH", "1").is_ok();
    if !ok {
        return Err(log_line(0, "the preprocessor did not start"));
    }
    let starts = line_starts(src);
    let mut toks = Vec::new();
    let mut warnings = Vec::new();
    for item in &mut pp {
        let token = match item {
            Ok(t) => t,
            Err((e, loc)) => return Err(log_line(line_of(&starts, loc.start), &format!("preprocessor: {:?}", e))),
        };
        if toks.len() >= MAX_TOKENS {
            return Err(log_line(line_of(&starts, token.location.start), "the shader is too long after macro expansion"));
        }
        let line = line_of(&starts, token.location.start);
        match token.value {
            TokenValue::Ident(s) => {
                if is_precision_word(&s) {
                    continue;
                }
                toks.push(Tok { t: T::Id(s), line })
            }
            TokenValue::Integer(i) => toks.push(Tok { t: T::Int(i.value, i.signed), line }),
            TokenValue::Float(f) => toks.push(Tok { t: T::Float(f.value), line }),
            TokenValue::Punct(p) => toks.push(Tok { t: T::P(p), line }),
            TokenValue::Version(_) | TokenValue::Pragma(_) => {}
            TokenValue::Extension(e) => {
                let words: Vec<String> = e
                    .tokens
                    .iter()
                    .filter_map(|t| match &t.value {
                        TokenValue::Ident(s) => Some(s.clone()),
                        _ => None,
                    })
                    .collect();
                if words.len() == 2 {
                    let (name, behavior) = (&words[0], &words[1]);
                    let known = match name.as_str() {
                        "GL_OES_standard_derivatives" => caps.standard_derivatives || es3,
                        "GL_EXT_frag_depth" => caps.frag_depth || es3,
                        "GL_EXT_shader_texture_lod" => caps.shader_texture_lod || es3,
                        "GL_EXT_draw_buffers" => caps.draw_buffers,
                        "all" => true,
                        _ => false,
                    };
                    if !known && behavior == "require" {
                        return Err(log_line(line, &format!("extension {} is not supported", name)));
                    }
                    if !known && behavior != "disable" {
                        warnings.push(format!("WARNING: 0:{}: extension {} is not supported\n", line, name));
                    }
                }
            }
        }
    }
    let _ = stage;
    Ok((toks, warnings))
}

// ---- the first pass: what is declared ----

struct Reader<'a> {
    toks: &'a [Tok],
    i: usize,
}

impl Reader<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.i)
    }
    fn at(&self, n: usize) -> Option<&Tok> {
        self.toks.get(self.i + n)
    }
    /// Index of the closing punctuation matching the opening one at `from`.
    fn matching(&self, from: usize, open: Punct, close: Punct) -> Option<usize> {
        let mut depth = 0usize;
        let mut j = from;
        while let Some(t) = self.toks.get(j) {
            if let T::P(p) = t.t {
                if p == open {
                    depth += 1;
                } else if p == close {
                    depth -= 1;
                    if depth == 0 {
                        return Some(j);
                    }
                }
            }
            j += 1;
        }
        None
    }
    fn find_semicolon(&self, from: usize) -> Option<usize> {
        let mut depth = 0i32;
        let mut j = from;
        while let Some(t) = self.toks.get(j) {
            if let T::P(p) = t.t {
                match p {
                    Punct::LeftBrace | Punct::LeftParen | Punct::LeftBracket => depth += 1,
                    Punct::RightBrace | Punct::RightParen | Punct::RightBracket => depth -= 1,
                    Punct::Semicolon if depth == 0 => return Some(j),
                    _ => {}
                }
            }
            j += 1;
        }
        None
    }
}

/// Evaluates an integral constant expression of tokens: numbers, known constants, + - * / % and parentheses.
fn eval_int(toks: &[Tok], consts: &HashMap<String, i64>) -> Option<i64> {
    struct P<'a> {
        t: &'a [Tok],
        i: usize,
        consts: &'a HashMap<String, i64>,
        depth: u32,
    }
    impl P<'_> {
        fn atom(&mut self) -> Option<i64> {
            self.depth += 1;
            if self.depth > MAX_NESTING as u32 {
                return None;
            }
            let t = self.t.get(self.i)?.t.clone();
            self.i += 1;
            let r = match t {
                T::Int(v, _) => Some(v as i64),
                T::Id(s) => self.consts.get(&s).copied(),
                T::P(Punct::LeftParen) => {
                    let v = self.add();
                    if !matches!(self.t.get(self.i), Some(Tok { t: T::P(Punct::RightParen), .. })) {
                        return None;
                    }
                    self.i += 1;
                    v
                }
                T::P(Punct::Minus) => self.atom().map(|v| -v),
                T::P(Punct::Plus) => self.atom(),
                _ => None,
            };
            self.depth -= 1;
            r
        }
        fn mul(&mut self) -> Option<i64> {
            let mut v = self.atom()?;
            while let Some(Tok { t: T::P(p), .. }) = self.t.get(self.i) {
                let p = *p;
                if p != Punct::Star && p != Punct::Slash && p != Punct::Percent {
                    break;
                }
                self.i += 1;
                let r = self.atom()?;
                v = match p {
                    Punct::Star => v.checked_mul(r)?,
                    Punct::Slash => v.checked_div(r)?,
                    _ => v.checked_rem(r)?,
                };
            }
            Some(v)
        }
        fn add(&mut self) -> Option<i64> {
            let mut v = self.mul()?;
            while let Some(Tok { t: T::P(p), .. }) = self.t.get(self.i) {
                let p = *p;
                if p != Punct::Plus && p != Punct::Minus {
                    break;
                }
                self.i += 1;
                let r = self.mul()?;
                v = if p == Punct::Plus { v.checked_add(r)? } else { v.checked_sub(r)? };
            }
            Some(v)
        }
    }
    let mut p = P { t: toks, i: 0, consts, depth: 0 };
    let v = p.add()?;
    if p.i == toks.len() {
        Some(v)
    } else {
        None
    }
}

fn parse_location(layout: &[Tok]) -> Option<u32> {
    let mut i = 0;
    while i + 2 < layout.len() {
        if id_of(layout.get(i)) == Some("location") && is_p(layout.get(i + 1), Punct::Equal) {
            if let Some(Tok { t: T::Int(v, _), .. }) = layout.get(i + 2) {
                return Some(*v as u32);
            }
        }
        i += 1;
    }
    None
}

impl Shader {
    fn struct_def(&self, name: &str) -> Option<&StructDef> {
        self.structs.iter().find(|s| s.name == name)
    }

    fn type_ref(&self, name: &str) -> Option<TypeRef> {
        if let Some(b) = basic_type(name) {
            return Some(TypeRef::Basic(b, name.to_string()));
        }
        self.struct_def(name).map(|_| TypeRef::Struct(name.to_string()))
    }

    /// Does this type hold something a block cannot (bool, a matrix of 2 rows)?
    fn needs_copy(&self, ty: &TypeRef) -> bool {
        match ty {
            TypeRef::Basic(b, _) => b.scalar() == Scalar::Bool || (b.cols > 1 && b.rows == 2),
            TypeRef::Struct(n) => self.struct_def(n).map_or(false, |s| s.needs_copy),
        }
    }
}

/// Reads and checks a source. The rewrite runs once with default choices so that naga's errors are in the info log and the
/// layout of the blocks is known.
pub fn compile(stage: Stage, src: &str, caps: &Caps) -> Result<Shader, String> {
    if src.len() > MAX_SOURCE_BYTES {
        return Err(log_line(0, "the shader is too long"));
    }
    let es3 = detect_es3(src)?;
    if es3 && !caps.webgl2 {
        return Err(log_line(1, "GLSL ES 3.00 needs a WebGL 2 context"));
    }
    let (toks, warnings) = preprocess(src, stage, caps, es3)?;
    let mut s = read_declarations(stage, es3, toks, warnings, caps)?;
    let map = default_link_map(&s);
    let text = s.emit(&map, caps)?;
    let module = parse_glsl(stage, &text)?;
    s.reflect(&module)?;
    check_limits(&s, caps)?;
    Ok(s)
}

/// Locations and bindings in order of declaration, for the first translation of a shader by itself.
fn default_link_map(s: &Shader) -> LinkMap {
    let mut map = LinkMap::default();
    let mut loc = 0;
    for v in &s.inputs {
        let key = &v.name;
        let l = v.location.unwrap_or(loc);
        if s.stage == Stage::Vertex {
            map.attributes.insert(key.clone(), l);
        } else {
            map.varyings.insert(key.clone(), l);
        }
        loc = l + v.slots();
    }
    if s.stage == Stage::Vertex {
        let mut loc = 0;
        for v in &s.outputs {
            map.varyings.insert(v.name.clone(), loc);
            loc += v.slots();
        }
        map.point_coord = loc;
    } else {
        map.point_coord = loc;
    }
    let mut n = 0;
    for d in &s.samplers {
        if d.count == 0 {
            map.samplers.insert(d.name.clone(), n);
            n += 1;
        } else {
            for i in 0..d.count {
                map.samplers.insert(format!("{}[{}]", d.name, i), n);
                n += 1;
            }
        }
    }
    for (i, b) in s.block_decls.iter().enumerate() {
        map.blocks.insert(b.name.clone(), i as u32);
    }
    map
}

fn check_limits(s: &Shader, caps: &Caps) -> Result<(), String> {
    let vectors: u32 = s
        .leaves
        .iter()
        .map(|l| {
            let n = l.count.max(1);
            n * l.ty.cols
        })
        .sum();
    let max = if s.stage == Stage::Vertex { caps.max_vertex_uniform_vectors } else { caps.max_fragment_uniform_vectors };
    if vectors > max {
        return Err(log_line(0, &format!("too many uniform vectors: {} (at most {})", vectors, max)));
    }
    let tex: u32 = s.samplers.iter().map(|d| d.count.max(1)).sum();
    let max = if s.stage == Stage::Vertex { caps.max_vertex_texture_units } else { caps.max_texture_units };
    if tex > max {
        return Err(log_line(0, &format!("too many samplers: {} (at most {})", tex, max)));
    }
    let slots: u32 = if s.stage == Stage::Vertex { s.outputs.iter().map(|v| v.slots()).sum() } else { s.inputs.iter().map(|v| v.slots()).sum() };
    if slots > caps.max_varying_vectors {
        return Err(log_line(0, &format!("too many varying vectors: {} (at most {})", slots, caps.max_varying_vectors)));
    }
    if s.stage == Stage::Vertex {
        let slots: u32 = s.inputs.iter().map(|v| v.slots()).sum();
        if slots > caps.max_vertex_attribs {
            return Err(log_line(0, &format!("too many attributes: {} (at most {})", slots, caps.max_vertex_attribs)));
        }
    }
    Ok(())
}

fn read_declarations(stage: Stage, es3: bool, toks: Vec<Tok>, warnings: Vec<String>, caps: &Caps) -> Result<Shader, String> {
    let mut s = Shader {
        stage,
        es3,
        inputs: Vec::new(),
        outputs: Vec::new(),
        samplers: Vec::new(),
        uses_frag_coord_point: false,
        uses_point_size: false,
        warnings,
        leaves: Vec::new(),
        block_size: 0,
        blocks: Vec::new(),
        toks: Vec::new(),
        uniforms: Vec::new(),
        block_decls: Vec::new(),
        structs: Vec::new(),
        consts: HashMap::new(),
        frag_data_used: Vec::new(),
        hoisted: Vec::new(),
        decl_ranges: Vec::new(),
        renames: HashMap::new(),
    };
    // checks over all the tokens: names, nesting, the size of statements
    let max_ident = if es3 { MAX_IDENT_ES3 } else { MAX_IDENT_ES1 };
    let mut depth = 0usize;
    let mut statement = 0usize;
    for t in &toks {
        statement += 1;
        match &t.t {
            T::Id(name) => {
                if name.len() > max_ident {
                    return Err(log_line(t.line, "identifier too long"));
                }
                if name.starts_with("webgl_") || name.starts_with("_webgl_") {
                    return Err(log_line(t.line, &format!("{}: reserved identifier", name)));
                }
                if name.starts_with(PREFIX) {
                    return Err(log_line(t.line, &format!("{}: reserved identifier", name)));
                }
                if reserved_word(name, es3) {
                    return Err(log_line(t.line, &format!("{}: reserved word", name)));
                }
                if !es3 {
                    let missing = match name.as_str() {
                        "dFdx" | "dFdy" | "fwidth" => {
                            if stage == Stage::Vertex {
                                true
                            } else {
                                !caps.standard_derivatives
                            }
                        }
                        "gl_FragDepthEXT" => !caps.frag_depth,
                        "texture2DLodEXT" | "texture2DProjLodEXT" | "textureCubeLodEXT" | "texture2DGradEXT" | "texture2DProjGradEXT"
                        | "textureCubeGradEXT" => !caps.shader_texture_lod,
                        _ => false,
                    };
                    if missing {
                        return Err(log_line(t.line, &format!("{}: needs an extension that is not enabled", name)));
                    }
                }
                if es3 && matches!(name.as_str(), "texture2D" | "textureCube" | "texture2DProj" | "texture2DLod") {
                    return Err(log_line(t.line, &format!("{}: not in GLSL ES 3.00", name)));
                }
            }
            T::P(p) => match p {
                Punct::LeftBrace | Punct::LeftParen | Punct::LeftBracket => {
                    depth += 1;
                    if depth > MAX_NESTING {
                        return Err(log_line(t.line, "nested too deep"));
                    }
                }
                Punct::RightBrace | Punct::RightParen | Punct::RightBracket => {
                    if depth == 0 {
                        return Err(log_line(t.line, "unbalanced brackets"));
                    }
                    depth -= 1;
                    statement = 0;
                }
                Punct::Semicolon => statement = 0,
                _ => {}
            },
            _ => {}
        }
        if statement > MAX_STATEMENT_TOKENS {
            return Err(log_line(t.line, "statement too long"));
        }
    }
    if depth != 0 {
        return Err(log_line(toks.last().map_or(0, |t| t.line), "unbalanced brackets"));
    }

    let mut used: HashMap<String, u32> = HashMap::new();
    let mut r = Reader { toks: &toks, i: 0 };
    let mut body_ranges: Vec<(usize, usize)> = Vec::new();
    let mut have_main = false;
    while r.i < toks.len() {
        let start = r.i;
        // storage and interpolation qualifiers, a layout
        let mut layout: Vec<Tok> = Vec::new();
        let mut quals: Vec<String> = Vec::new();
        let mut struct_seen = false;
        loop {
            match id_of(r.peek()) {
                Some("layout") if es3 => {
                    let open = r.i + 1;
                    let Some(close) = r.matching(open, Punct::LeftParen, Punct::RightParen) else {
                        return Err(log_line(toks[start].line, "bad layout"));
                    };
                    layout = toks[open + 1..close].to_vec();
                    r.i = close + 1;
                }
                Some(q @ ("attribute" | "varying" | "uniform" | "in" | "out" | "flat" | "smooth" | "centroid" | "invariant" | "const")) => {
                    if q == "attribute" && (es3 || stage != Stage::Vertex) {
                        return Err(log_line(toks[r.i].line, "attribute: not allowed here"));
                    }
                    if q == "varying" && es3 {
                        return Err(log_line(toks[r.i].line, "varying: not in GLSL ES 3.00"));
                    }
                    quals.push(q.to_string());
                    r.i += 1;
                }
                _ => break,
            }
        }
        let has = |w: &str| quals.iter().any(|q| q == w);
        if id_of(r.peek()) == Some("precision") {
            let Some(end) = r.find_semicolon(r.i) else { return Err(log_line(toks[start].line, "bad precision statement")) };
            r.i = end + 1;
            s.decl_ranges.push((start, r.i));
            continue;
        }
        // `invariant gl_Position;` and `invariant varying x;`: nothing to do
        if has("invariant") && quals.len() == 1 {
            let Some(end) = r.find_semicolon(r.i) else { return Err(log_line(toks[start].line, "bad invariant statement")) };
            r.i = end + 1;
            s.decl_ranges.push((start, r.i));
            continue;
        }
        if id_of(r.peek()) == Some("struct") {
            struct_seen = true;
        }
        if struct_seen {
            // struct Name { ... } [declarators] ;
            let name_at = r.i + 1;
            let (name, open) = match id_of(toks.get(name_at)) {
                Some(n) => (n.to_string(), name_at + 1),
                None => (format!("{}anon{}", PREFIX, s.structs.len()), name_at),
            };
            if !is_p(toks.get(open), Punct::LeftBrace) {
                return Err(log_line(toks[r.i].line, "bad structure"));
            }
            let Some(close) = r.matching(open, Punct::LeftBrace, Punct::RightBrace) else {
                return Err(log_line(toks[r.i].line, "bad structure"));
            };
            let def = read_struct(&s, &name, &toks[open + 1..close])?;
            s.structs.push(def);
            r.i = close + 1;
            let anon_or_plain = is_p(r.peek(), Punct::Semicolon);
            if anon_or_plain && !has("uniform") {
                r.i += 1;
                s.hoisted.push((name_at - 1, close + 2));
                s.decl_ranges.push((start, r.i));
                continue;
            }
            // declarators after the structure
            let Some(end) = r.find_semicolon(r.i) else { return Err(log_line(toks[close].line, "bad structure")) };
            let declarators = toks[r.i..end].to_vec();
            s.hoisted.push((name_at - 1, close + 1));
            read_declarators(&mut s, &quals, &layout, &name, &declarators, toks[close].line, es3, caps)?;
            r.i = end + 1;
            s.decl_ranges.push((start, r.i));
            continue;
        }
        let storage = has("attribute") || has("varying") || has("uniform") || has("in") || has("out");
        if storage {
            // a block?
            if has("uniform") && is_p(r.at(1), Punct::LeftBrace) {
                if !es3 {
                    return Err(log_line(toks[r.i].line, "uniform blocks need GLSL ES 3.00"));
                }
                let name = id_of(r.peek()).unwrap_or("").to_string();
                let open = r.i + 1;
                let Some(close) = r.matching(open, Punct::LeftBrace, Punct::RightBrace) else {
                    return Err(log_line(toks[r.i].line, "bad block"));
                };
                let Some(end) = r.find_semicolon(close + 1) else { return Err(log_line(toks[close].line, "bad block")) };
                let mut instance = None;
                let mut array = Vec::new();
                if let Some(n) = id_of(toks.get(close + 1)) {
                    instance = Some(n.to_string());
                    if is_p(toks.get(close + 2), Punct::LeftBracket) {
                        array = toks[close + 3..end - 1].to_vec();
                    }
                }
                if !array.is_empty() {
                    return Err(log_line(toks[close].line, "arrays of uniform blocks are not supported"));
                }
                s.block_decls.push(BlockDecl { name, instance, body: toks[open + 1..close].to_vec(), array });
                r.i = end + 1;
                s.decl_ranges.push((start, r.i));
                continue;
            }
            let Some(type_name) = id_of(r.peek()).map(str::to_string) else {
                return Err(log_line(toks[start].line, "a type is expected"));
            };
            let Some(end) = r.find_semicolon(r.i) else { return Err(log_line(toks[start].line, "a ; is expected")) };
            let declarators = toks[r.i + 1..end].to_vec();
            read_declarators(&mut s, &quals, &layout, &type_name, &declarators, toks[start].line, es3, caps)?;
            r.i = end + 1;
            s.decl_ranges.push((start, r.i));
            continue;
        }
        // a global constant: hoisted (array sizes and block members may name it)
        if has("const") {
            let Some(end) = r.find_semicolon(r.i) else { return Err(log_line(toks[start].line, "a ; is expected")) };
            if id_of(r.peek()) == Some("int") || id_of(r.peek()) == Some("uint") {
                if let Some(n) = id_of(r.at(1)) {
                    if is_p(r.at(2), Punct::Equal) {
                        if let Some(v) = eval_int(&toks[r.i + 3..end], &s.consts) {
                            s.consts.insert(n.to_string(), v);
                        }
                    }
                }
            }
            s.hoisted.push((start, end + 1));
            r.i = end + 1;
            s.decl_ranges.push((start, r.i));
            continue;
        }
        // the rest: a function or a global variable, up to its ; or the end of its body
        let mut j = r.i;
        let mut paren = 0;
        let mut end = toks.len();
        while let Some(t) = toks.get(j) {
            if let T::P(p) = t.t {
                match p {
                    Punct::LeftParen => paren += 1,
                    Punct::RightParen => paren -= 1,
                    Punct::Semicolon if paren == 0 => {
                        end = j + 1;
                        break;
                    }
                    Punct::LeftBrace if paren == 0 => {
                        let Some(close) = r.matching(j, Punct::LeftBrace, Punct::RightBrace) else {
                            return Err(log_line(t.line, "unbalanced braces"));
                        };
                        end = close + 1;
                        break;
                    }
                    _ => {}
                }
            }
            j += 1;
        }
        if id_of(toks.get(start + 1)) == Some("main") && is_p(toks.get(start + 2), Punct::LeftParen) && id_of(toks.get(start)) == Some("void") {
            if is_p(toks.get(end - 1), Punct::RightBrace) {
                have_main = true;
            }
        }
        body_ranges.push((start, end));
        r.i = end;
    }
    let _ = have_main;
    // uses, in everything that is not a declaration of this pass
    for (a, b) in &body_ranges {
        for t in &toks[*a..*b] {
            if let T::Id(n) = &t.t {
                *used.entry(n.clone()).or_insert(0) += 1;
            }
        }
    }
    for b in &s.hoisted {
        for t in &toks[b.0..b.1] {
            if let T::Id(n) = &t.t {
                *used.entry(n.clone()).or_insert(0) += 1;
            }
        }
    }
    let is_used = |n: &str| used.contains_key(n);
    if stage == Stage::Fragment && !have_main {
        return Err(log_line(0, "no definition of main"));
    }
    if stage == Stage::Vertex && !have_main {
        return Err(log_line(0, "no definition of main"));
    }
    s.uses_point_size = is_used("gl_PointSize");
    s.uses_frag_coord_point = is_used("gl_PointCoord");
    for u in &mut s.uniforms {
        u.active = is_used(&u.name);
    }
    for d in &mut s.samplers {
        d.active = is_used(&d.name);
    }
    for v in &mut s.inputs {
        v.active = is_used(&v.name);
    }
    for v in &mut s.outputs {
        v.active = is_used(&v.name);
    }
    if is_used("gl_FragColor") && (0..toks.len()).any(|i| id_of(toks.get(i)) == Some("gl_FragData")) {
        return Err(log_line(0, "a shader cannot write both gl_FragColor and gl_FragData"));
    }
    if stage == Stage::Fragment && !es3 {
        for i in 0..toks.len() {
            if id_of(toks.get(i)) == Some("gl_FragData") {
                if !is_p(toks.get(i + 1), Punct::LeftBracket) {
                    return Err(log_line(toks[i].line, "gl_FragData needs an index"));
                }
                let Some(close) = (Reader { toks: &toks, i: 0 }).matching(i + 1, Punct::LeftBracket, Punct::RightBracket) else {
                    return Err(log_line(toks[i].line, "gl_FragData needs an index"));
                };
                match eval_int(&toks[i + 2..close], &s.consts) {
                    Some(v) if v >= 0 && (v as u32) < if caps.draw_buffers { caps.max_draw_buffers } else { 1 } => {
                        if !s.frag_data_used.contains(&(v as u32)) {
                            s.frag_data_used.push(v as u32);
                        }
                    }
                    _ => return Err(log_line(toks[i].line, "gl_FragData: its index must be a constant in range")),
                }
            }
        }
        s.frag_data_used.sort_unstable();
    }
    // names that collide with naga's words
    for t in &toks {
        if let T::Id(n) = &t.t {
            if clashes_with_naga(n, es3) && !s.renames.contains_key(n) {
                s.renames.insert(n.clone(), format!("{}n_{}", PREFIX, n));
            }
        }
    }
    s.toks = toks;
    s.decl_ranges.sort_unstable();
    Ok(s)
}

fn read_struct(s: &Shader, name: &str, body: &[Tok]) -> Result<StructDef, String> {
    let mut fields = Vec::new();
    let mut needs_copy = false;
    let mut i = 0;
    while i < body.len() {
        let line = body[i].line;
        let Some(tn) = id_of(body.get(i)) else { return Err(log_line(line, "a type is expected in the structure")) };
        if sampler_kind(tn).is_some() {
            return Err(log_line(line, "samplers in structures are not supported"));
        }
        let Some(ty) = s.type_ref(tn) else { return Err(log_line(line, &format!("{}: unknown type in the structure", tn))) };
        if s.needs_copy(&ty) {
            needs_copy = true;
        }
        i += 1;
        loop {
            let Some(n) = id_of(body.get(i)) else { return Err(log_line(line, "a name is expected in the structure")) };
            let n = n.to_string();
            i += 1;
            let mut array = Vec::new();
            if is_p(body.get(i), Punct::LeftBracket) {
                let close = (Reader { toks: body, i: 0 }).matching(i, Punct::LeftBracket, Punct::RightBracket).ok_or_else(|| log_line(line, "bad array"))?;
                array = body[i + 1..close].to_vec();
                i = close + 1;
            }
            fields.push(Field { ty: ty.clone(), name: n, array });
            if is_p(body.get(i), Punct::Comma) {
                i += 1;
                continue;
            }
            if is_p(body.get(i), Punct::Semicolon) {
                i += 1;
                break;
            }
            return Err(log_line(line, "a ; is expected in the structure"));
        }
    }
    Ok(StructDef { name: name.to_string(), fields, needs_copy })
}

#[allow(clippy::too_many_arguments)]
fn read_declarators(s: &mut Shader, quals: &[String], layout: &[Tok], type_name: &str, decls: &[Tok], line: u32, es3: bool, caps: &Caps) -> Result<(), String> {
    let has = |w: &str| quals.iter().any(|q| q == w);
    let mut i = 0;
    while i < decls.len() {
        let Some(name) = id_of(decls.get(i)).map(str::to_string) else { return Err(log_line(line, "a name is expected")) };
        i += 1;
        let mut array = Vec::new();
        if is_p(decls.get(i), Punct::LeftBracket) {
            let close = (Reader { toks: decls, i: 0 }).matching(i, Punct::LeftBracket, Punct::RightBracket).ok_or_else(|| log_line(line, "bad array"))?;
            array = decls[i + 1..close].to_vec();
            i = close + 1;
        }
        if is_p(decls.get(i), Punct::Equal) {
            return Err(log_line(line, "this declaration cannot have an initializer"));
        }
        if has("uniform") {
            if let Some(kind) = sampler_kind(type_name) {
                let count = if array.is_empty() {
                    0
                } else {
                    match eval_int(&array, &s.consts) {
                        Some(v) if v > 0 && v < 1 << 16 => v as u32,
                        _ => return Err(log_line(line, "the size of a sampler array must be a constant")),
                    }
                };
                s.samplers.push(SamplerDecl { name: name.clone(), mangled: mangle(&name), kind, count, active: false });
            } else {
                let Some(ty) = s.type_ref(type_name) else { return Err(log_line(line, &format!("{}: unknown type", type_name))) };
                if !array.is_empty() {
                    match eval_int(&array, &s.consts) {
                        Some(v) if v > 0 && v < 1 << 16 => {}
                        _ => return Err(log_line(line, "the size of a uniform array must be a positive constant")),
                    }
                }
                s.uniforms.push(UniformDecl { name: name.clone(), mangled: mangle(&name), ty, array, active: false });
            }
        } else {
            let Some(ty) = basic_type(type_name) else { return Err(log_line(line, &format!("{}: this type cannot be an input or an output here", type_name))) };
            let count = if array.is_empty() {
                0
            } else {
                match eval_int(&array, &s.consts) {
                    Some(v) if v > 0 && v < 1 << 16 => v as u32,
                    _ => return Err(log_line(line, "the size of the array must be a positive constant")),
                }
            };
            let qualifiers: Vec<String> = quals.iter().filter(|q| matches!(q.as_str(), "flat" | "smooth" | "centroid")).cloned().collect();
            let v = InOut {
                name: name.clone(),
                ty,
                array: count,
                location: parse_location(layout),
                flat: has("flat"),
                centroid: has("centroid"),
                active: false,
                qualifiers,
                type_name: type_name.to_string(),
                array_toks: array.clone(),
            };
            if ty.scalar() != Scalar::Float && !has("flat") && !has("attribute") && !(s.stage == Stage::Vertex && has("in")) && !(s.stage == Stage::Fragment && has("out")) {
                return Err(log_line(line, "integer varyings must be flat"));
            }
            if ty.scalar() == Scalar::Bool {
                return Err(log_line(line, "bool cannot be an input or an output"));
            }
            let input = has("attribute") || has("in") || (has("varying") && s.stage == Stage::Fragment);
            if input {
                if !es3 && !has("attribute") && !has("varying") {
                    return Err(log_line(line, "in: not in GLSL ES 1.00 at this scope"));
                }
                s.inputs.push(v);
            } else {
                if !es3 && !has("varying") {
                    return Err(log_line(line, "out: not in GLSL ES 1.00 at this scope"));
                }
                s.outputs.push(v);
            }
            let _ = caps;
        }
        if i >= decls.len() {
            break;
        }
        if !is_p(decls.get(i), Punct::Comma) {
            return Err(log_line(line, "a , or a ; is expected"));
        }
        i += 1;
    }
    Ok(())
}

fn mangle(name: &str) -> String {
    format!("{}u_{}", PREFIX, name)
}

// ---- writing ----

/// What is written: the text, and for each of its lines the line of the source (for naga's errors).
#[derive(Default)]
struct Out {
    text: String,
    lines: Vec<u32>,
    line: u32,
}

impl Out {
    fn raw(&mut self, s: &str) {
        for part in s.split_inclusive('\n') {
            self.text.push_str(part);
            if part.ends_with('\n') {
                self.lines.push(self.line);
            }
        }
    }
    fn at_line(&mut self, line: u32) {
        if line != self.line {
            self.text.push('\n');
            self.lines.push(self.line);
            self.line = line;
        }
    }
    fn tok(&mut self, s: &str) {
        self.text.push_str(s);
        self.text.push(' ');
    }
}

fn tok_text(t: &T, out: &mut String) {
    match t {
        T::Id(s) => out.push_str(s),
        T::Int(v, signed) => {
            let _ = write!(out, "{}{}", v, if *signed { "" } else { "u" });
        }
        T::Float(f) => {
            if f.is_infinite() || f.is_nan() {
                out.push_str("1e38");
            } else {
                let _ = write!(out, "{:?}", f);
            }
        }
        T::P(p) => out.push_str(punct_text(*p)),
    }
}

/// One frame of the stack of open parentheses: the function called, when it is a call.
struct Call {
    callee: Option<String>,
}

fn is_texture_builtin(name: &str) -> bool {
    matches!(
        name,
        "texture" | "textureLod" | "textureGrad" | "textureOffset" | "textureLodOffset" | "textureGradOffset" | "textureProj" | "textureProjLod"
            | "textureProjGrad" | "textureProjOffset" | "textureProjLodOffset" | "textureProjGradOffset" | "textureSize" | "texelFetch" | "texelFetchOffset"
            | "texture2D" | "textureCube" | "texture2DProj" | "texture2DLod" | "textureCubeLod" | "texture2DProjLod" | "texture2DLodEXT"
            | "textureCubeLodEXT" | "texture2DProjLodEXT" | "texture2DGradEXT" | "textureCubeGradEXT" | "texture2DProjGradEXT"
    )
}

/// The GLSL 450 name of a texture function of GLSL ES 1.00.
fn texture_function(name: &str) -> &str {
    match name {
        "texture2D" | "textureCube" => "texture",
        "texture2DProj" => "textureProj",
        "texture2DLod" | "textureCubeLod" | "texture2DLodEXT" | "textureCubeLodEXT" => "textureLod",
        "texture2DProjLod" | "texture2DProjLodEXT" => "textureProjLod",
        "texture2DGradEXT" | "textureCubeGradEXT" => "textureGrad",
        "texture2DProjGradEXT" => "textureProjGrad",
        n => n,
    }
}

fn is_builtin_const(name: &str, caps: &Caps) -> Option<u32> {
    Some(match name {
        "gl_MaxVertexAttribs" => caps.max_vertex_attribs,
        "gl_MaxVertexUniformVectors" => caps.max_vertex_uniform_vectors,
        "gl_MaxVaryingVectors" => caps.max_varying_vectors,
        "gl_MaxVertexTextureImageUnits" => caps.max_vertex_texture_units,
        "gl_MaxCombinedTextureImageUnits" => caps.max_combined_texture_units,
        "gl_MaxTextureImageUnits" => caps.max_texture_units,
        "gl_MaxFragmentUniformVectors" => caps.max_fragment_uniform_vectors,
        "gl_MaxDrawBuffers" => caps.max_draw_buffers,
        "gl_MaxVertexOutputVectors" => caps.max_varying_vectors,
        "gl_MaxFragmentInputVectors" => caps.max_varying_vectors,
        "gl_MinProgramTexelOffset" => return None,
        "gl_MaxProgramTexelOffset" => 7,
        _ => return None,
    })
}

impl Shader {
    fn word<'a>(&'a self, s: &'a str) -> &'a str {
        self.renames.get(s).map_or(s, |r| r.as_str())
    }

    /// Writes tokens [a, b) of a part of the code, rewriting what has to be.
    fn emit_code(&self, out: &mut Out, a: usize, b: usize, map: &LinkMap, caps: &Caps, local: &mut HashMap<String, SamplerKind>, is_function_top: bool) -> Result<(), String> {
        let toks = &self.toks;
        let mut calls: Vec<Call> = Vec::new();
        let mut brace = 0;
        let mut i = a;
        let mut buf = String::new();
        // A function's header: its parameters may be samplers.
        let mut in_header = is_function_top;
        while i < b {
            let tk = &toks[i];
            out.at_line(tk.line);
            match &tk.t {
                T::Id(name) => {
                    // a function's parameter that is a sampler (type, name)
                    if in_header && calls.len() == 1 {
                        if let Some(kind) = sampler_kind(name) {
                            let pname = id_of(toks.get(i + 1)).map(str::to_string);
                            let (pname, next) = match pname {
                                Some(n) => (n, i + 2),
                                None => (format!("{}p{}", PREFIX, i), i + 1),
                            };
                            let m = format!("{}p_{}", PREFIX, pname);
                            out.tok(&format!("{} {}_t , {} {}_s", kind.texture, m, kind.sampler, m));
                            local.insert(pname, kind);
                            i = next;
                            continue;
                        }
                    }
                    if in_header && calls.len() == 1 && matches!(name.as_str(), "in" | "const") {
                        // (qualifiers of a sampler parameter go; of another parameter they stay)
                        let mut j = i + 1;
                        while matches!(id_of(toks.get(j)), Some("in" | "const")) {
                            j += 1;
                        }
                        if id_of(toks.get(j)).and_then(sampler_kind).is_some() {
                            i = j;
                            continue;
                        }
                    }
                    // a sampler used as an argument
                    let kind = local.get(name).copied().map(|k| (k, true)).or_else(|| self.samplers.iter().find(|d| &d.name == name).map(|d| (d.kind, false)));
                    if let Some((kind, is_local)) = kind {
                        let prev_ok = i > a && (is_p(toks.get(i - 1), Punct::LeftParen) || is_p(toks.get(i - 1), Punct::Comma));
                        let (index, next) = if is_p(toks.get(i + 1), Punct::LeftBracket) {
                            let close = (Reader { toks, i: 0 }).matching(i + 1, Punct::LeftBracket, Punct::RightBracket).ok_or_else(|| log_line(tk.line, "bad index"))?;
                            (Some(&toks[i + 2..close]), close + 1)
                        } else {
                            (None, i + 1)
                        };
                        let next_ok = is_p(toks.get(next), Punct::Comma) || is_p(toks.get(next), Punct::RightParen);
                        if prev_ok && next_ok && calls.last().map_or(false, |c| c.callee.is_some()) {
                            let base = if is_local {
                                format!("{}p_{}", PREFIX, name)
                            } else {
                                let d = self.samplers.iter().find(|d| &d.name == name).unwrap();
                                match index {
                                    Some(ix) => {
                                        let Some(v) = eval_int(ix, &self.consts) else {
                                            return Err(log_line(tk.line, &format!("{}: a sampler array's index must be a constant", name)));
                                        };
                                        if v < 0 || v as u32 >= d.count {
                                            return Err(log_line(tk.line, &format!("{}: index out of range", name)));
                                        }
                                        format!("{}_{}", d.mangled, v)
                                    }
                                    None => d.mangled.clone(),
                                }
                            };
                            let callee = calls.last().unwrap().callee.as_deref().unwrap();
                            if is_texture_builtin(callee) {
                                out.tok(&format!("{} ( {}_t , {}_s )", kind.combined, base, base));
                            } else {
                                out.tok(&format!("{}_t , {}_s", base, base));
                            }
                            i = next;
                            continue;
                        }
                    }
                    let open = is_p(toks.get(i + 1), Punct::LeftParen);
                    let mut text: &str = name.as_str();
                    let prev_dot = i > a && is_p(toks.get(i - 1), Punct::Dot);
                    if !prev_dot {
                        if let Some(v) = is_builtin_const(name, caps) {
                            let _ = write!(buf, "{}", v);
                            out.tok(&buf);
                            buf.clear();
                            i += 1;
                            continue;
                        }
                        match name.as_str() {
                            "gl_MinProgramTexelOffset" => {
                                out.tok("( - 8 )");
                                i += 1;
                                continue;
                            }
                            "gl_FragColor" => text = "_wr_FragData_0",
                            "gl_FragDepthEXT" => text = "gl_FragDepth",
                            "gl_PointSize" => text = "_wr_PointSize",
                            "gl_PointCoord" => text = "_wr_PointCoord",
                            "gl_VertexID" => text = if map.points { "gl_InstanceIndex" } else { "gl_VertexIndex" },
                            "gl_InstanceID" => text = "gl_InstanceIndex",
                            "gl_FragData" if !self.es3 => {
                                let close = (Reader { toks, i: 0 }).matching(i + 1, Punct::LeftBracket, Punct::RightBracket).ok_or_else(|| log_line(tk.line, "bad index"))?;
                                let v = eval_int(&toks[i + 2..close], &self.consts).unwrap_or(0);
                                out.tok(&format!("_wr_FragData_{}", v));
                                i = close + 1;
                                continue;
                            }
                            "main" if open && brace == 0 && calls.is_empty() => text = "_wr_main",
                            "gl_DepthRange" => text = "_wr_DepthRange",
                            _ => {
                                if open && is_texture_builtin(name) {
                                    text = texture_function(name);
                                } else {
                                    if name.starts_with("gl_") && !KNOWN_GL.contains(&name.as_str()) {
                                        return Err(log_line(tk.line, &format!("{}: unknown or reserved name", name)));
                                    }
                                    text = self.word(name);
                                }
                            }
                        }
                    } else {
                        text = self.word(name);
                    }
                    if open {
                        calls.push(Call { callee: Some(name.clone()) });
                        out.tok(text);
                        out.tok("(");
                        i += 2;
                        continue;
                    }
                    out.tok(text);
                    i += 1;
                }
                T::P(p) => {
                    match p {
                        Punct::LeftParen => calls.push(Call { callee: None }),
                        Punct::RightParen => {
                            calls.pop();
                            if calls.is_empty() {
                                in_header = false;
                            }
                        }
                        Punct::LeftBrace => brace += 1,
                        Punct::RightBrace => brace -= 1,
                        _ => {}
                    }
                    out.tok(punct_text(*p));
                    i += 1;
                }
                other => {
                    tok_text(other, &mut buf);
                    out.tok(&buf);
                    buf.clear();
                    i += 1;
                }
            }
        }
        Ok(())
    }

    /// The tokens of an array's size, written.
    fn array_text(&self, array: &[Tok]) -> String {
        let mut s = String::new();
        for t in array {
            match &t.t {
                T::Id(n) => s.push_str(self.word(n)),
                other => tok_text(other, &mut s),
            }
            s.push(' ');
        }
        s
    }

    /// The type a field or uniform has in a block, and how many vec4 stand for a matrix.
    fn block_type(&self, ty: &TypeRef) -> (String, u32) {
        match ty {
            TypeRef::Struct(n) => {
                let def = self.struct_def(n).unwrap();
                (if def.needs_copy { format!("{}U_{}", PREFIX, self.word(n)) } else { self.word(n).to_string() }, 1)
            }
            TypeRef::Basic(b, name) => {
                if b.scalar() == Scalar::Bool {
                    return (
                        match b.rows {
                            1 => "uint".to_string(),
                            n => format!("uvec{}", n),
                        },
                        1,
                    );
                }
                if b.cols > 1 && b.rows == 2 {
                    return ("vec4".to_string(), b.cols);
                }
                (name.clone(), 1)
            }
        }
    }

    /// A block member of this declaration. Returns its text.
    fn block_member(&self, ty: &TypeRef, name: &str, array: &[Tok]) -> String {
        let (t, mult) = self.block_type(ty);
        let arr = self.array_text(array);
        if mult > 1 {
            if array.is_empty() {
                format!("{} {}[{}];\n", t, name, mult)
            } else {
                format!("{} {}[({})*{}];\n", t, name, arr, mult)
            }
        } else if array.is_empty() {
            format!("{} {};\n", t, name)
        } else {
            format!("{} {}[{}];\n", t, name, arr)
        }
    }

    /// Code that copies `src` (of the block's type) to `dst` (of the declared type).
    fn copy_code(&self, out: &mut String, ty: &TypeRef, dst: &str, src: &str, array: &[Tok], depth: &mut u32) {
        if !array.is_empty() {
            let i = format!("{}i{}", PREFIX, *depth);
            *depth += 1;
            let n = self.array_text(array);
            let (_, mult) = self.block_type(ty);
            let _ = writeln!(out, "for (int {i} = 0; {i} < ({n}); {i}++) {{");
            if mult > 1 {
                self.copy_matrix(out, ty, &format!("{dst}[{i}]"), src, &format!("{i} * {mult}"));
            } else {
                self.copy_code(out, ty, &format!("{dst}[{i}]"), &format!("{src}[{i}]"), &[], depth);
            }
            out.push_str("}\n");
            return;
        }
        match ty {
            TypeRef::Struct(n) => {
                let def = self.struct_def(n).unwrap();
                for f in &def.fields {
                    let fname = self.word(&f.name).to_string();
                    let (_, mult) = self.block_type(&f.ty);
                    if self.needs_copy(&f.ty) || mult > 1 {
                        self.copy_code(out, &f.ty, &format!("{dst}.{fname}"), &format!("{src}.{fname}"), &f.array, depth);
                    } else {
                        let _ = writeln!(out, "{dst}.{fname} = {src}.{fname};");
                    }
                }
            }
            TypeRef::Basic(b, _) => {
                if b.scalar() == Scalar::Bool {
                    match b.rows {
                        1 => {
                            let _ = writeln!(out, "{dst} = {src} != 0u;");
                        }
                        n => {
                            let _ = writeln!(out, "{dst} = notEqual({src}, uvec{n}(0u));");
                        }
                    }
                } else if b.cols > 1 && b.rows == 2 {
                    self.copy_matrix(out, ty, dst, src, "0");
                } else {
                    let _ = writeln!(out, "{dst} = {src};");
                }
            }
        }
    }

    fn copy_matrix(&self, out: &mut String, ty: &TypeRef, dst: &str, src: &str, base: &str) {
        if let TypeRef::Basic(b, name) = ty {
            let mut cols = String::new();
            for c in 0..b.cols {
                if c > 0 {
                    cols.push_str(", ");
                }
                let _ = write!(cols, "{src}[{base} + {c}].xy");
            }
            let _ = writeln!(out, "{dst} = {name}({cols});");
        }
    }

    /// The whole shader for a link.
    pub fn emit(&self, map: &LinkMap, caps: &Caps) -> Result<String, String> {
        let mut out = Out::default();
        out.line = 0;
        out.raw("#version 450 core\n");
        let es1_frag = self.stage == Stage::Fragment && !self.es3;
        // structures and constants first: they may be needed by all that follows
        let mut local = HashMap::new();
        let mut hoisted = self.hoisted.clone();
        hoisted.sort_unstable();
        for (a, b) in &hoisted {
            self.emit_code(&mut out, *a, *b, map, caps, &mut local, false)?;
            // (a structure followed by declarators)
            if !is_p(self.toks.get(*b - 1), Punct::Semicolon) {
                out.tok(";");
            }
            out.at_line(0);
        }
        // the structures as blocks hold them
        for def in &self.structs {
            if def.needs_copy {
                let mut body = String::new();
                for f in &def.fields {
                    body.push_str(&self.block_member(&f.ty, self.word(&f.name), &f.array));
                }
                let name = format!("{}U_{}", PREFIX, self.word(&def.name));
                out.raw(&format!("struct {name} {{\n{body}}};\n"));
            }
        }
        // the block of default uniforms, and what stands for those it cannot hold
        let (group, binding) = (GROUP_UNIFORMS, if self.stage == Stage::Vertex { BINDING_VS_UNIFORMS } else { BINDING_FS_UNIFORMS });
        let mut block = String::new();
        if self.stage == Stage::Vertex {
            let _ = writeln!(block, "vec4 {};", VS_VIEWPORT_MEMBER);
        }
        let mut privates = String::new();
        let mut copies = String::new();
        let mut depth = 0;
        for u in &self.uniforms {
            let visible = self.word(&u.name).to_string();
            if self.needs_copy(&u.ty) {
                block.push_str(&self.block_member(&u.ty, &u.mangled, &u.array));
                let tname = match &u.ty {
                    TypeRef::Basic(_, n) => n.clone(),
                    TypeRef::Struct(n) => self.word(n).to_string(),
                };
                if u.array.is_empty() {
                    let _ = writeln!(privates, "{tname} {visible};");
                } else {
                    let _ = writeln!(privates, "{tname} {visible}[{}];", self.array_text(&u.array));
                }
                self.copy_code(&mut copies, &u.ty, &visible, &u.mangled, &u.array, &mut depth);
            } else {
                block.push_str(&self.block_member(&u.ty, &visible, &u.array));
            }
        }
        if !block.is_empty() {
            out.raw(&format!("layout(std140, set = {group}, binding = {binding}) uniform {PREFIX}Default {{\n{block}}};\n"));
        }
        out.raw(&privates);
        // samplers
        let mut sampler_lines = String::new();
        for d in &self.samplers {
            let elements: Vec<(String, String)> = if d.count == 0 {
                vec![(d.name.clone(), d.mangled.clone())]
            } else {
                (0..d.count).map(|i| (format!("{}[{}]", d.name, i), format!("{}_{}", d.mangled, i))).collect()
            };
            for (key, m) in elements {
                let Some(ix) = map.samplers.get(&key) else { return Err(log_line(0, &format!("{}: not linked", key))) };
                let _ = writeln!(
                    sampler_lines,
                    "layout(set = {GROUP_TEXTURES}, binding = {}) uniform {} {m}_t;\nlayout(set = {GROUP_TEXTURES}, binding = {}) uniform {} {m}_s;",
                    ix * 2,
                    d.kind.texture,
                    ix * 2 + 1,
                    d.kind.sampler
                );
            }
        }
        out.raw(&sampler_lines);
        // blocks of the page
        for b in &self.block_decls {
            let Some(ix) = map.blocks.get(&b.name) else { return Err(log_line(0, &format!("{}: not linked", b.name))) };
            let mut body = String::new();
            let mut j = 0;
            while j < b.body.len() {
                if let T::Id(n) = &b.body[j].t {
                    if n == "layout" {
                        if let Some(c) = (Reader { toks: &b.body, i: 0 }).matching(j + 1, Punct::LeftParen, Punct::RightParen) {
                            if b.body[j + 2..c].iter().any(|t| matches!(&t.t, T::Id(n) if n == "row_major")) {
                                return Err(log_line(b.body[j].line, "row_major is not supported"));
                            }
                            j = c + 1;
                            continue;
                        }
                    }
                }
                match &b.body[j].t {
                    T::Id(n) => body.push_str(self.word(n)),
                    other => tok_text(other, &mut body),
                }
                body.push(' ');
                j += 1;
            }
            let inst = b.instance.as_deref().map(|s| self.word(s).to_string()).unwrap_or_default();
            out.raw(&format!("layout(std140, set = {GROUP_BLOCKS}, binding = {ix}) uniform {} {{ {body} }} {inst};\n", self.word(&b.name)));
        }
        // inputs and outputs
        let mut next_loc: u32 = 0;
        for (v, input) in self.inputs.iter().map(|v| (v, true)).chain(self.outputs.iter().map(|v| (v, false))) {
            let dir = if input { "in" } else { "out" };
            let key = &v.name;
            let loc = if input {
                if self.stage == Stage::Vertex {
                    map.attributes.get(key).copied()
                } else {
                    map.varyings.get(key).copied()
                }
            } else if self.stage == Stage::Vertex {
                map.varyings.get(key).copied()
            } else {
                let l = v.location.unwrap_or(next_loc);
                next_loc = l + v.slots();
                Some(l)
            };
            let Some(loc) = loc else {
                // a varying of the vertex stage nobody reads goes to no location: a private variable
                if self.stage == Stage::Vertex && !input {
                    let arr = if v.array_toks.is_empty() { String::new() } else { format!("[{}]", self.array_text(&v.array_toks)) };
                    out.raw(&format!("{} {}{};\n", v.type_name, self.word(&v.name), arr));
                    continue;
                }
                // an attribute or varying of the fragment stage that is not linked: unused (a link error otherwise)
                let arr = if v.array_toks.is_empty() { String::new() } else { format!("[{}]", self.array_text(&v.array_toks)) };
                out.raw(&format!("{} {}{};\n", v.type_name, self.word(&v.name), arr));
                continue;
            };
            let mut q = String::new();
            for w in &v.qualifiers {
                q.push_str(w);
                q.push(' ');
            }
            let arr = if v.array_toks.is_empty() { String::new() } else { format!("[{}]", self.array_text(&v.array_toks)) };
            out.raw(&format!("layout(location = {loc}) {q}{dir} {} {}{};\n", v.type_name, self.word(&v.name), arr));
        }
        // what the stage writes or reads that GL has and this GLSL does not
        match self.stage {
            Stage::Vertex => {
                out.raw("float _wr_PointSize = 1.0;\n");
                if map.points {
                    out.raw(&format!("layout(location = {}) out vec2 _wr_PointCoordOut;\n", map.point_coord));
                } else if map.point_coord != u32::MAX {
                    out.raw(&format!("layout(location = {}) out vec2 _wr_PointCoordOut;\n", map.point_coord));
                }
            }
            Stage::Fragment => {
                if es1_frag {
                    let uses_color = self.toks.iter().any(|t| matches!(&t.t, T::Id(n) if n == "gl_FragColor"));
                    if uses_color {
                        out.raw("layout(location = 0) out vec4 _wr_FragData_0;\n");
                    }
                    for i in &self.frag_data_used {
                        out.raw(&format!("layout(location = {i}) out vec4 _wr_FragData_{i};\n"));
                    }
                }
                if self.uses_frag_coord_point {
                    out.raw(&format!("layout(location = {}) in vec2 _wr_PointCoord;\n", map.point_coord));
                }
            }
        }
        if self.toks.iter().any(|t| matches!(&t.t, T::Id(n) if n == "gl_DepthRange")) {
            out.raw("struct _wr_DepthRangeT { float near_; float far_; float diff; };\nconst _wr_DepthRangeT _wr_DepthRange = _wr_DepthRangeT(0.0, 1.0, 1.0);\n");
        }
        // the code, in order
        let mut skip: Vec<(usize, usize)> = self.decl_ranges.clone();
        skip.extend(hoisted.iter().copied());
        skip.sort_unstable();
        let mut i = 0;
        for (a, b) in merged(&skip) {
            if i < a {
                self.emit_range(&mut out, i, a, map, caps)?;
            }
            i = b.max(i);
        }
        if i < self.toks.len() {
            self.emit_range(&mut out, i, self.toks.len(), map, caps)?;
        }
        out.at_line(0);
        out.raw("\n");
        // the wrapper
        out.raw("void main() {\n");
        out.raw(&copies);
        out.raw("_wr_main();\n");
        if self.stage == Stage::Vertex {
            if map.points {
                out.raw(&format!(
                    "const vec2 corners[6] = vec2[6](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(-1.0, 1.0), vec2(1.0, -1.0), vec2(1.0, 1.0));\n\
                     vec2 corner = corners[gl_VertexIndex];\n\
                     gl_Position.xy += corner * _wr_PointSize / {VS_VIEWPORT_MEMBER}.xy * gl_Position.w;\n\
                     _wr_PointCoordOut = vec2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5);\n"
                ));
            } else if map.point_coord != u32::MAX {
                out.raw("_wr_PointCoordOut = vec2(0.0);\n");
            }
            out.raw("gl_Position.y = -gl_Position.y;\ngl_Position.z = (gl_Position.z + gl_Position.w) * 0.5;\n");
        }
        out.raw("}\n");
        Ok(out.text)
    }

    /// Code between declarations: statement by statement, functions with their headers.
    fn emit_range(&self, out: &mut Out, a: usize, b: usize, map: &LinkMap, caps: &Caps) -> Result<(), String> {
        let toks = &self.toks;
        let mut i = a;
        while i < b {
            // up to the end of this function or global statement
            let mut j = i;
            let mut paren = 0;
            let mut end = b;
            let mut is_function = false;
            while j < b {
                if let T::P(p) = toks[j].t {
                    match p {
                        Punct::LeftParen => {
                            if paren == 0 {
                                is_function = true;
                            }
                            paren += 1;
                        }
                        Punct::RightParen => paren -= 1,
                        Punct::Equal if paren == 0 => is_function = false,
                        Punct::Semicolon if paren == 0 => {
                            end = j + 1;
                            break;
                        }
                        Punct::LeftBrace if paren == 0 => {
                            let close = (Reader { toks, i: 0 }).matching(j, Punct::LeftBrace, Punct::RightBrace).ok_or_else(|| log_line(toks[j].line, "unbalanced"))?;
                            end = close + 1;
                            break;
                        }
                        _ => {}
                    }
                }
                j += 1;
            }
            let mut local = HashMap::new();
            self.emit_code(out, i, end, map, caps, &mut local, is_function)?;
            i = end;
        }
        Ok(())
    }

    /// Layouts of the blocks, from naga's module.
    fn reflect(&mut self, module: &naga::Module) -> Result<(), String> {
        let mut leaves = Vec::new();
        let mut size = 0;
        let binding = if self.stage == Stage::Vertex { BINDING_VS_UNIFORMS } else { BINDING_FS_UNIFORMS };
        for (_, g) in module.global_variables.iter() {
            let Some(rb) = g.binding else { continue };
            if rb.group == GROUP_UNIFORMS && rb.binding == binding {
                let TypeInner::Struct { members, span } = &module.types[g.ty].inner else {
                    return Err(log_line(0, "internal: the default block is not a structure"));
                };
                size = *span;
                for (k, m) in members.iter().enumerate() {
                    let index = if self.stage == Stage::Vertex { k.checked_sub(1) } else { Some(k) };
                    let Some(index) = index else { continue };
                    let Some(u) = self.uniforms.get(index) else { return Err(log_line(0, "internal: the default block has an unknown member")) };
                    if !u.active {
                        continue;
                    }
                    let array = !u.array.is_empty();
                    self.walk(module, m.ty, &u.ty, &u.name, array, m.offset, &mut leaves)?;
                    if leaves.len() > MAX_UNIFORM_LEAVES {
                        return Err(log_line(0, "too many uniforms"));
                    }
                }
            }
        }
        self.leaves = leaves;
        self.block_size = size;
        let mut blocks = Vec::new();
        for b in &self.block_decls {
            let mut info = BlockInfo { name: b.name.clone(), size: 0, members: Vec::new(), active: true };
            for (_, g) in module.global_variables.iter() {
                let Some(rb) = g.binding else { continue };
                if rb.group != GROUP_BLOCKS {
                    continue;
                }
                let Some(n) = module.types[g.ty].name.as_deref() else { continue };
                if n != self.word(&b.name) {
                    continue;
                }
                let TypeInner::Struct { members, span } = &module.types[g.ty].inner else { continue };
                info.size = *span;
                for m in members.iter() {
                    let name = m.name.clone().unwrap_or_default();
                    let visible = self.renames.iter().find(|(_, v)| **v == name).map_or(name.clone(), |(k, _)| k.clone());
                    block_leaves(module, m.ty, &format!("{}{}", if b.instance.is_some() { format!("{}.", b.name) } else { String::new() }, visible), m.offset, &mut info.members);
                }
            }
            blocks.push(info);
        }
        self.blocks = blocks;
        Ok(())
    }

    /// The leaves of a default uniform (offsets from naga, types as declared).
    #[allow(clippy::too_many_arguments)]
    fn walk(&self, module: &naga::Module, ty: naga::Handle<naga::Type>, decl: &TypeRef, name: &str, is_array: bool, offset: u32, out: &mut Vec<UniformLeaf>) -> Result<(), String> {
        if out.len() > MAX_UNIFORM_LEAVES {
            return Ok(());
        }
        match decl {
            TypeRef::Basic(b, _) => {
                let mult = if self.needs_copy(decl) && b.cols > 1 { b.cols } else { 1 };
                let (count, stride) = match module.types[ty].inner {
                    TypeInner::Array { size: naga::ArraySize::Constant(n), stride, .. } => (n.get(), stride),
                    _ => (0, 0),
                };
                let (count, stride) = if mult > 1 { (if is_array { count / mult } else { 0 }, stride * mult) } else { (count, stride) };
                let name = if count > 0 { format!("{}[0]", name) } else { name.to_string() };
                out.push(UniformLeaf { name, ty: *b, count, offset, stride });
            }
            TypeRef::Struct(sn) => {
                let def = self.struct_def(sn).ok_or_else(|| log_line(0, "internal: unknown structure"))?;
                if is_array {
                    let TypeInner::Array { base, size: naga::ArraySize::Constant(n), stride } = module.types[ty].inner else {
                        return Err(log_line(0, "internal: an array is expected"));
                    };
                    for i in 0..n.get() {
                        self.walk(module, base, decl, &format!("{}[{}]", name, i), false, offset + i * stride, out)?;
                    }
                    return Ok(());
                }
                let TypeInner::Struct { members, .. } = &module.types[ty].inner else {
                    return Err(log_line(0, "internal: a structure is expected"));
                };
                for (f, m) in def.fields.iter().zip(members.iter()) {
                    self.walk(module, m.ty, &f.ty, &format!("{}.{}", name, f.name), !f.array.is_empty(), offset + m.offset, out)?;
                }
            }
        }
        Ok(())
    }
}

fn block_leaves(module: &naga::Module, ty: naga::Handle<naga::Type>, name: &str, offset: u32, out: &mut Vec<BlockMember>) {
    if out.len() > MAX_UNIFORM_LEAVES {
        return;
    }
    let scalar_gl = |s: naga::Scalar, n: u32| -> u32 {
        let base = match s.kind {
            naga::ScalarKind::Sint => [GL_INT, GL_INT_VEC2, GL_INT_VEC3, GL_INT_VEC4],
            naga::ScalarKind::Uint => [GL_UNSIGNED_INT, GL_UNSIGNED_INT_VEC2, GL_UNSIGNED_INT_VEC3, GL_UNSIGNED_INT_VEC4],
            naga::ScalarKind::Bool => [GL_BOOL, GL_BOOL_VEC2, GL_BOOL_VEC3, GL_BOOL_VEC4],
            _ => [GL_FLOAT, GL_FLOAT_VEC2, GL_FLOAT_VEC3, GL_FLOAT_VEC4],
        };
        base[(n - 1) as usize]
    };
    match &module.types[ty].inner {
        TypeInner::Scalar(s) => out.push(BlockMember { name: name.to_string(), ty: BasicType { gl: scalar_gl(*s, 1), cols: 1, rows: 1 }, count: 0, offset, array_stride: 0, matrix_stride: 0 }),
        TypeInner::Vector { size, scalar } => {
            let n = *size as u32;
            out.push(BlockMember { name: name.to_string(), ty: BasicType { gl: scalar_gl(*scalar, n), cols: 1, rows: n }, count: 0, offset, array_stride: 0, matrix_stride: 0 })
        }
        TypeInner::Matrix { columns, rows, .. } => {
            let (c, r) = (*columns as u32, *rows as u32);
            out.push(BlockMember { name: name.to_string(), ty: matrix_type(c, r), count: 0, offset, array_stride: 0, matrix_stride: 16 })
        }
        TypeInner::Array { base, size: naga::ArraySize::Constant(n), stride } => {
            let inner = &module.types[*base].inner;
            if matches!(inner, TypeInner::Struct { .. }) {
                for i in 0..n.get() {
                    block_leaves(module, *base, &format!("{}[{}]", name, i), offset + i * stride, out);
                }
            } else {
                let mut tmp = Vec::new();
                block_leaves(module, *base, &format!("{}[0]", name), offset, &mut tmp);
                for mut m in tmp {
                    m.count = n.get();
                    m.array_stride = *stride;
                    out.push(m);
                }
            }
        }
        TypeInner::Struct { members, .. } => {
            for m in members {
                let field = m.name.clone().unwrap_or_default();
                block_leaves(module, m.ty, &format!("{}.{}", name, field), offset + m.offset, out);
            }
        }
        _ => {}
    }
}

fn matrix_type(c: u32, r: u32) -> BasicType {
    let gl = match (c, r) {
        (2, 2) => GL_FLOAT_MAT2,
        (3, 3) => GL_FLOAT_MAT3,
        (4, 4) => GL_FLOAT_MAT4,
        (2, 3) => GL_FLOAT_MAT2X3,
        (2, 4) => GL_FLOAT_MAT2X4,
        (3, 2) => GL_FLOAT_MAT3X2,
        (3, 4) => GL_FLOAT_MAT3X4,
        (4, 2) => GL_FLOAT_MAT4X2,
        _ => GL_FLOAT_MAT4X3,
    };
    BasicType { gl, cols: c, rows: r }
}

fn merged(ranges: &[(usize, usize)]) -> Vec<(usize, usize)> {
    let mut out: Vec<(usize, usize)> = Vec::new();
    for &(a, b) in ranges {
        match out.last_mut() {
            Some(l) if a <= l.1 => l.1 = l.1.max(b),
            _ => out.push((a, b)),
        }
    }
    out
}

/// The names `gl_*` that a shader may use and naga knows.
const KNOWN_GL: &[&str] = &["gl_Position", "gl_FragCoord", "gl_FrontFacing", "gl_FragDepth"];

/// Parses what `emit` wrote.
pub fn parse_glsl(stage: Stage, text: &str) -> Result<naga::Module, String> {
    let st = match stage {
        Stage::Vertex => ShaderStage::Vertex,
        Stage::Fragment => ShaderStage::Fragment,
    };
    let mut fe = Frontend::default();
    fe.parse(&Options::from(st), text).map_err(|errors| {
        let mut log = String::new();
        let lines: Vec<&str> = text.split('\n').collect();
        for e in &errors.errors {
            let loc = e.meta.location(text);
            let line = loc.line_number;
            let shown = lines.get(line.saturating_sub(1) as usize).copied().unwrap_or("");
            let shown: String = shown.chars().take(200).collect();
            let _ = writeln!(log, "ERROR: 0:{}: {} (in: {})", line, e.kind, shown.trim());
        }
        if log.is_empty() {
            log.push_str("ERROR: 0:0: the shader could not be compiled\n");
        }
        log
    })
}

/// A linked pair: what the pipeline needs, and the reflection of the program.
#[derive(Debug)]
pub struct Linked {
    pub vertex: naga::Module,
    /// The vertex stage drawing points as quads; made on the first draw of points.
    pub fragment: naga::Module,
    pub attributes: Vec<(String, BasicType, u32, u32)>,
    pub varying_slots: u32,
    pub map: LinkMap,
    pub vs_size: u32,
    pub fs_size: u32,
    pub warnings: String,
}

/// Link: the interface between the stages checked, every location and binding decided, both stages translated again.
/// `bound`: bindAttribLocation's choices.
pub fn link(vs: &Shader, fs: &Shader, bound: &HashMap<String, u32>, caps: &Caps) -> Result<Linked, String> {
    if vs.es3 != fs.es3 {
        return Err("ERROR: the shaders of a program must have the same version\n".to_string());
    }
    let mut map = LinkMap::default();
    // varyings: by name
    let mut names = HashSet::new();
    let mut loc = 0;
    for v in &vs.outputs {
        names.insert(v.name.clone());
    }
    for f in &fs.inputs {
        match vs.outputs.iter().find(|v| v.name == f.name) {
            Some(v) => {
                if v.ty != f.ty || v.array != f.array {
                    return Err(format!("ERROR: varying {}: the types differ between the stages\n", f.name));
                }
                if v.flat != f.flat {
                    return Err(format!("ERROR: varying {}: the interpolation differs between the stages\n", f.name));
                }
            }
            None => {
                if f.active {
                    return Err(format!("ERROR: varying {} is read but not written by the vertex shader\n", f.name));
                }
            }
        }
    }
    for f in &fs.inputs {
        if vs.outputs.iter().any(|v| v.name == f.name) {
            map.varyings.insert(f.name.clone(), loc);
            loc += f.slots();
        }
    }
    if loc > caps.max_varying_vectors {
        return Err(format!("ERROR: too many varying vectors: {}\n", loc));
    }
    map.point_coord = loc;
    // attributes: bound ones, then what layout says, then the free places
    let mut taken = vec![false; caps.max_vertex_attribs as usize];
    let mut attributes = Vec::new();
    let mut pending = Vec::new();
    for a in &vs.inputs {
        let want = a.location.or_else(|| bound.get(&a.name).copied());
        if let Some(l) = want {
            let n = a.slots();
            if l + n > caps.max_vertex_attribs {
                return Err(format!("ERROR: attribute {}: location out of range\n", a.name));
            }
            for k in l..l + n {
                if taken[k as usize] {
                    return Err(format!("ERROR: attribute {}: location {} is taken\n", a.name, k));
                }
                taken[k as usize] = true;
            }
            map.attributes.insert(a.name.clone(), l);
            attributes.push((a.name.clone(), a.ty, a.array, l));
        } else {
            pending.push(a);
        }
    }
    for a in pending {
        let n = a.slots() as usize;
        let mut l = 0;
        let mut found = None;
        while l + n <= taken.len() {
            if taken[l..l + n].iter().all(|t| !*t) {
                found = Some(l);
                break;
            }
            l += 1;
        }
        let Some(l) = found else { return Err(format!("ERROR: too many attributes ({})\n", a.name)) };
        for t in &mut taken[l..l + n] {
            *t = true;
        }
        map.attributes.insert(a.name.clone(), l as u32);
        attributes.push((a.name.clone(), a.ty, a.array, l as u32));
    }
    // samplers: one binding per name across the stages
    let mut next = 0;
    let mut seen: HashMap<String, SamplerKind> = HashMap::new();
    for d in vs.samplers.iter().chain(fs.samplers.iter()) {
        if let Some(k) = seen.get(&d.name) {
            if *k != d.kind {
                return Err(format!("ERROR: uniform {}: the types differ between the stages\n", d.name));
            }
            continue;
        }
        seen.insert(d.name.clone(), d.kind);
        if d.count == 0 {
            map.samplers.insert(d.name.clone(), next);
            next += 1;
        } else {
            for i in 0..d.count {
                map.samplers.insert(format!("{}[{}]", d.name, i), next);
                next += 1;
            }
        }
    }
    if next > caps.max_combined_texture_units.min(caps.max_texture_units) {
        return Err(format!("ERROR: too many samplers: {}\n", next));
    }
    // blocks of the page: one binding per name
    let mut nb = 0;
    for b in vs.block_decls.iter().chain(fs.block_decls.iter()) {
        if !map.blocks.contains_key(&b.name) {
            map.blocks.insert(b.name.clone(), nb);
            nb += 1;
        }
    }
    // uniforms in both stages must have the same type
    for l in &vs.leaves {
        if let Some(o) = fs.leaves.iter().find(|o| o.name == l.name) {
            if o.ty != l.ty || o.count != l.count {
                return Err(format!("ERROR: uniform {}: the types differ between the stages\n", l.name));
            }
        }
    }
    let vtext = vs.emit(&map, caps)?;
    let ftext = fs.emit(&map, caps)?;
    let vertex = parse_glsl(Stage::Vertex, &vtext).map_err(|e| format!("vertex shader: {e}"))?;
    let fragment = parse_glsl(Stage::Fragment, &ftext).map_err(|e| format!("fragment shader: {e}"))?;
    let mut warnings = String::new();
    for w in vs.warnings.iter().chain(fs.warnings.iter()) {
        warnings.push_str(w);
    }
    let _ = names;
    Ok(Linked { vertex, fragment, attributes, varying_slots: loc, map, vs_size: vs.block_size, fs_size: fs.block_size, warnings })
}

/// The vertex stage of a linked program as the quads of points.
pub fn points_variant(vs: &Shader, map: &LinkMap, caps: &Caps) -> Result<naga::Module, String> {
    let mut m = map.clone();
    m.points = true;
    let text = vs.emit(&m, caps)?;
    parse_glsl(Stage::Vertex, &text)
}

#[cfg(test)]
mod tests {
    use super::*;

    const VS1: &str = "attribute vec3 position; attribute vec2 uv; uniform mat4 mvp; uniform mat2 rot; uniform bool flag; varying vec2 v_uv; void main(){ v_uv = rot * uv; gl_Position = mvp * vec4(position, flag ? 1.0 : 0.5); gl_PointSize = 4.0; }";
    const FS1: &str = "precision mediump float; uniform sampler2D map; varying vec2 v_uv; uniform vec4 tint; uniform float arr[3]; void main(){ gl_FragColor = texture2D(map, v_uv) * tint * arr[1]; }";

    fn caps() -> Caps {
        Caps::default()
    }

    #[test]
    fn es1_pair_compiles_and_links() {
        let v = compile(Stage::Vertex, VS1, &caps()).unwrap();
        let f = compile(Stage::Fragment, FS1, &caps()).unwrap();
        assert_eq!(v.inputs.len(), 2);
        assert_eq!(f.samplers[0].name, "map");
        let names: Vec<_> = f.leaves.iter().map(|l| l.name.as_str()).collect();
        assert_eq!(names, ["tint", "arr[0]"]);
        assert_eq!(f.leaves[1].count, 3);
        assert_eq!(f.leaves[1].stride, 16);
        let l = link(&v, &f, &HashMap::new(), &caps()).unwrap();
        assert_eq!(l.map.varyings["v_uv"], 0);
        assert_eq!(l.map.samplers["map"], 0);
        points_variant(&v, &l.map, &caps()).unwrap();
    }

    #[test]
    fn errors_have_a_line() {
        let e = compile(Stage::Fragment, "precision mediump float;\nvoid main(){\n  vec4 x = nope;\n}\n", &caps()).unwrap_err();
        assert!(e.contains("ERROR"), "{e}");
    }

    #[test]
    fn es1_rejects_what_it_should() {
        let c = caps();
        assert!(compile(Stage::Fragment, "void main(){ webgl_x; }", &c).is_err());
        assert!(compile(Stage::Vertex, "attribute float a[2]; int main;", &c).is_err());
        let no = Caps { standard_derivatives: false, ..caps() };
        assert!(compile(Stage::Fragment, "precision mediump float; void main(){ gl_FragColor = vec4(dFdx(1.0)); }", &no).is_err());
        assert!(compile(Stage::Fragment, "precision mediump float; void main(){ gl_FragColor = vec4(dFdx(1.0)); }", &c).is_ok());
    }

    #[test]
    fn varyings_must_match() {
        let v = compile(Stage::Vertex, "varying vec2 a; void main(){ a = vec2(0.0); gl_Position = vec4(0.0); }", &caps()).unwrap();
        let f = compile(Stage::Fragment, "precision mediump float; varying vec3 a; void main(){ gl_FragColor = vec4(a, 1.0); }", &caps()).unwrap();
        assert!(link(&v, &f, &HashMap::new(), &caps()).is_err());
    }

    #[test]
    fn es3_with_structs_blocks_and_hoisting() {
        let vs = "#version 300 es\nlayout(location = 2) in vec3 p; in mat4 inst; uniform B { mat4 m; vec3 c; } b; uniform float x;\nfloat f(){ return x; }\nstruct L { vec3 c; bool on; };\nuniform L ls[2];\nflat out int id;\nvoid main(){ id = gl_VertexID; gl_Position = b.m * inst * vec4(p*f(), ls[1].on ? 1.0 : 0.0); }";
        let fs = "#version 300 es\nprecision highp float; precision highp sampler2DArray;\nflat in int id; uniform sampler2DArray arr; uniform sampler2DShadow sh; uniform sampler2D many[2]; out vec4 color;\nvec4 g(sampler2D s, vec2 uv){ return texture(s, uv); }\nvoid main(){ color = texture(arr, vec3(0.0)) + g(many[1], vec2(float(id))) + vec4(texture(sh, vec3(0.5))); }";
        let v = compile(Stage::Vertex, vs, &caps()).unwrap();
        let f = compile(Stage::Fragment, fs, &caps()).unwrap();
        assert_eq!(v.blocks[0].name, "B");
        assert!(v.leaves.iter().any(|l| l.name == "ls[1].on"), "{:?}", v.leaves);
        let l = link(&v, &f, &HashMap::new(), &caps()).unwrap();
        assert_eq!(l.map.attributes["p"], 2);
        assert_eq!(l.map.attributes["inst"], 3);
        assert!(l.map.samplers.contains_key("many[1]"));
    }

    #[test]
    fn macros_and_a_sampler_parameter() {
        let fs = "#extension GL_OES_standard_derivatives : enable\nprecision highp float;\n#define TEX(s, u) texture2D(s, u)\nuniform sampler2D a; uniform samplerCube c; varying vec2 uv;\nvec4 pick(const in sampler2D s, in vec2 p) { return TEX(s, p); }\nvoid main(){ gl_FragColor = pick(a, uv) + textureCube(c, vec3(uv, 1.0)) + vec4(fwidth(uv.x)); }";
        let f = compile(Stage::Fragment, fs, &caps()).unwrap();
        assert_eq!(f.samplers.len(), 2);
    }

    #[test]
    fn hostile_input_is_refused() {
        let deep = format!("void main(){{ float a = {}1.0{}; }}", "(".repeat(100_000), ")".repeat(100_000));
        assert!(compile(Stage::Vertex, &deep, &caps()).is_err());
        let long = format!("void main(){{ float a = 1.0{}; }}", "+1.0".repeat(100_000));
        assert!(compile(Stage::Vertex, &long, &caps()).is_err());
        let mut bomb = String::from("#define A0 x x\n");
        for i in 1..40 {
            bomb.push_str(&format!("#define A{i} A{p} A{p}\n", p = i - 1));
        }
        bomb.push_str("A39\nvoid main(){}");
        assert!(compile(Stage::Vertex, &bomb, &caps()).is_err());
    }
}
