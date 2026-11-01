//! What a page asks and waits for: getParameter, the logs of shaders and programs, readPixels and so on. See ops.rs for how answers travel.

use crate::formats;
use crate::gl::*;
use crate::ops::{self, Reader};
use crate::translate;

// getParameter's names
const ACTIVE_TEXTURE: u32 = 0x84E0;
const ALIASED_LINE_WIDTH_RANGE: u32 = 0x846E;
const ALIASED_POINT_SIZE_RANGE: u32 = 0x846D;
const ALPHA_BITS: u32 = 0x0D55;
const ARRAY_BUFFER_BINDING: u32 = 0x8894;
const BLEND_COLOR: u32 = 0x8005;
const BLEND_DST_ALPHA: u32 = 0x80CA;
const BLEND_DST_RGB: u32 = 0x80C8;
const BLEND_EQUATION_ALPHA: u32 = 0x883D;
const BLEND_EQUATION_RGB: u32 = 0x8009;
const BLEND_SRC_ALPHA: u32 = 0x80CB;
const BLEND_SRC_RGB: u32 = 0x80C9;
const BLUE_BITS: u32 = 0x0D54;
const COLOR_CLEAR_VALUE: u32 = 0x0C22;
const COLOR_WRITEMASK: u32 = 0x0C23;
const COMPRESSED_TEXTURE_FORMATS: u32 = 0x86A3;
const CULL_FACE_MODE: u32 = 0x0B45;
const CURRENT_PROGRAM: u32 = 0x8B8D;
const DEPTH_BITS: u32 = 0x0D56;
const DEPTH_CLEAR_VALUE: u32 = 0x0B73;
const DEPTH_FUNC: u32 = 0x0B74;
const DEPTH_RANGE: u32 = 0x0B70;
const DEPTH_WRITEMASK: u32 = 0x0B72;
const ELEMENT_ARRAY_BUFFER_BINDING: u32 = 0x8895;
const FRAMEBUFFER_BINDING: u32 = 0x8CA6;
const FRONT_FACE: u32 = 0x0B46;
const GENERATE_MIPMAP_HINT: u32 = 0x8192;
const GREEN_BITS: u32 = 0x0D53;
const IMPLEMENTATION_COLOR_READ_FORMAT: u32 = 0x8B9B;
const IMPLEMENTATION_COLOR_READ_TYPE: u32 = 0x8B9A;
const LINE_WIDTH: u32 = 0x0B21;
const MAX_COMBINED_TEXTURE_IMAGE_UNITS: u32 = 0x8B4D;
const MAX_CUBE_MAP_TEXTURE_SIZE: u32 = 0x851C;
const MAX_FRAGMENT_UNIFORM_VECTORS: u32 = 0x8DFD;
const MAX_RENDERBUFFER_SIZE: u32 = 0x84E8;
const MAX_TEXTURE_IMAGE_UNITS: u32 = 0x8872;
const MAX_TEXTURE_SIZE: u32 = 0x0D33;
const MAX_VARYING_VECTORS: u32 = 0x8DFC;
const MAX_VERTEX_ATTRIBS: u32 = 0x8869;
const MAX_VERTEX_TEXTURE_IMAGE_UNITS: u32 = 0x8B4C;
const MAX_VERTEX_UNIFORM_VECTORS: u32 = 0x8DFB;
const MAX_VIEWPORT_DIMS: u32 = 0x0D3A;
const PACK_ALIGNMENT_P: u32 = 0x0D05;
const POLYGON_OFFSET_FACTOR: u32 = 0x8038;
const POLYGON_OFFSET_UNITS: u32 = 0x2A00;
const RED_BITS: u32 = 0x0D52;
const RENDERBUFFER_BINDING: u32 = 0x8CA7;
const RENDERER: u32 = 0x1F01;
const SAMPLE_BUFFERS: u32 = 0x80A8;
const SAMPLE_COVERAGE_INVERT: u32 = 0x80AB;
const SAMPLE_COVERAGE_VALUE: u32 = 0x80AA;
const SAMPLES: u32 = 0x80A9;
const SCISSOR_BOX: u32 = 0x0C10;
const SHADING_LANGUAGE_VERSION: u32 = 0x8B8C;
const STENCIL_BACK_FAIL: u32 = 0x8801;
const STENCIL_BACK_FUNC: u32 = 0x8800;
const STENCIL_BACK_PASS_DEPTH_FAIL: u32 = 0x8802;
const STENCIL_BACK_PASS_DEPTH_PASS: u32 = 0x8803;
const STENCIL_BACK_REF: u32 = 0x8CA3;
const STENCIL_BACK_VALUE_MASK: u32 = 0x8CA4;
const STENCIL_BACK_WRITEMASK: u32 = 0x8CA5;
const STENCIL_BITS: u32 = 0x0D57;
const STENCIL_CLEAR_VALUE: u32 = 0x0B91;
const STENCIL_FAIL: u32 = 0x0B94;
const STENCIL_FUNC: u32 = 0x0B92;
const STENCIL_PASS_DEPTH_FAIL: u32 = 0x0B95;
const STENCIL_PASS_DEPTH_PASS: u32 = 0x0B96;
const STENCIL_REF: u32 = 0x0B97;
const STENCIL_VALUE_MASK: u32 = 0x0B93;
const STENCIL_WRITEMASK: u32 = 0x0B98;
const SUBPIXEL_BITS: u32 = 0x0D50;
const TEXTURE_BINDING_2D: u32 = 0x8069;
const TEXTURE_BINDING_CUBE_MAP: u32 = 0x8514;
const VENDOR: u32 = 0x1F00;
const VERSION: u32 = 0x1F02;
const VIEWPORT: u32 = 0x0BA2;
// WebGL 2
const MAX_3D_TEXTURE_SIZE: u32 = 0x8073;
const MAX_ARRAY_TEXTURE_LAYERS: u32 = 0x88FF;
const MAX_COLOR_ATTACHMENTS_P: u32 = 0x8CDF;
const MAX_DRAW_BUFFERS: u32 = 0x8824;
const MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS: u32 = 0x8A33;
const MAX_COMBINED_UNIFORM_BLOCKS: u32 = 0x8A2E;
const MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS: u32 = 0x8A31;
const MAX_ELEMENT_INDEX: u32 = 0x8D6B;
const MAX_ELEMENTS_INDICES: u32 = 0x80E9;
const MAX_ELEMENTS_VERTICES: u32 = 0x80E8;
const MAX_FRAGMENT_INPUT_COMPONENTS: u32 = 0x9125;
const MAX_FRAGMENT_UNIFORM_BLOCKS: u32 = 0x8A2D;
const MAX_FRAGMENT_UNIFORM_COMPONENTS: u32 = 0x8B49;
const MAX_PROGRAM_TEXEL_OFFSET: u32 = 0x8905;
const MIN_PROGRAM_TEXEL_OFFSET: u32 = 0x8904;
const MAX_SAMPLES: u32 = 0x8D57;
const MAX_SERVER_WAIT_TIMEOUT: u32 = 0x9141;
const MAX_TEXTURE_LOD_BIAS: u32 = 0x84FD;
const MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS: u32 = 0x8C8A;
const MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS: u32 = 0x8C8B;
const MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS: u32 = 0x8C80;
const MAX_UNIFORM_BLOCK_SIZE: u32 = 0x8A30;
const MAX_UNIFORM_BUFFER_BINDINGS_P: u32 = 0x8A2F;
const MAX_VARYING_COMPONENTS: u32 = 0x8B4B;
const MAX_VERTEX_OUTPUT_COMPONENTS: u32 = 0x9122;
const MAX_VERTEX_UNIFORM_BLOCKS: u32 = 0x8A2B;
const MAX_VERTEX_UNIFORM_COMPONENTS: u32 = 0x8B4A;
const UNIFORM_BUFFER_OFFSET_ALIGNMENT: u32 = 0x8A34;
const COPY_READ_BUFFER_BINDING: u32 = 0x8F36;
const COPY_WRITE_BUFFER_BINDING: u32 = 0x8F37;
const DRAW_FRAMEBUFFER_BINDING: u32 = 0x8CA6;
const READ_FRAMEBUFFER_BINDING: u32 = 0x8CAA;
const PIXEL_PACK_BUFFER_BINDING: u32 = 0x88ED;
const PIXEL_UNPACK_BUFFER_BINDING: u32 = 0x88EF;
const READ_BUFFER_P: u32 = 0x0C02;
const SAMPLER_BINDING: u32 = 0x8919;
const TEXTURE_BINDING_2D_ARRAY: u32 = 0x8C1D;
const TEXTURE_BINDING_3D: u32 = 0x806A;
const TRANSFORM_FEEDBACK_BUFFER_BINDING: u32 = 0x8C8F;
const UNIFORM_BUFFER_BINDING: u32 = 0x8A28;
const VERTEX_ARRAY_BINDING: u32 = 0x85B5;
const FRAGMENT_SHADER_DERIVATIVE_HINT: u32 = 0x8B8B;
const DRAW_BUFFER0: u32 = 0x8825;
const MAX_TEXTURE_MAX_ANISOTROPY: u32 = 0x84FF;
// glGetUniformBlock
const UNIFORM_BLOCK_BINDING: u32 = 0x8A3F;
const UNIFORM_BLOCK_DATA_SIZE: u32 = 0x8A40;
const UNIFORM_BLOCK_ACTIVE_UNIFORMS: u32 = 0x8A42;
const UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES: u32 = 0x8A43;
const UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER: u32 = 0x8A44;
const UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER: u32 = 0x8A46;

impl Ctx {
    /// Answers a query.
    pub fn query(&mut self, req: &[u8]) -> Reply {
        let mut r = Reader::new(req);
        self.query_inner(&mut r).unwrap_or_else(Reply::null)
    }

    fn query_inner(&mut self, r: &mut Reader<'_>) -> Option<Reply> {
        let op = r.u()?;
        Some(match op {
            ops::Q_ERROR => Reply::uint(self.take_error()),
            ops::Q_PARAMETER => {
                let p = r.u()?;
                self.get_parameter(p)
            }
            ops::Q_SHADER => {
                let (id, p) = (r.u()?, r.u()?);
                let Some(s) = self.shaders.get(&id) else {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::null());
                };
                match p {
                    0x8B81 => Reply::boolean(s.compiled.is_some()),
                    0x8B80 => Reply::boolean(s.deleted),
                    0x8B4F => Reply::uint(if s.stage == translate::Stage::Vertex { 0x8B31 } else { 0x8B30 }),
                    _ => {
                        self.set_error(INVALID_ENUM);
                        Reply::null()
                    }
                }
            }
            ops::Q_SHADER_LOG => {
                let id = r.u()?;
                match self.shaders.get(&id) {
                    Some(s) => Reply::string(&s.log),
                    None => Reply::string(""),
                }
            }
            ops::Q_PROGRAM => {
                let (id, p) = (r.u()?, r.u()?);
                self.program_parameter(id, p)
            }
            ops::Q_PROGRAM_LOG => {
                let id = r.u()?;
                match self.programs.get(&id) {
                    Some(p) => Reply::string(&p.log),
                    None => Reply::string(""),
                }
            }
            ops::Q_VALIDATE => {
                let id = r.u()?;
                self.validate_program(id);
                Reply::null()
            }
            ops::Q_ACTIVE_ATTRIB => {
                let (id, i) = (r.u()?, r.u()?);
                let Some(l) = self.programs.get(&id).and_then(|p| p.linked.as_ref()) else {
                    self.set_error(INVALID_VALUE);
                    return Some(Reply::null());
                };
                let list: Vec<_> = l.attributes.iter().filter(|a| a.4).collect();
                match list.get(i as usize) {
                    Some(a) => active_info(a.2.max(1), a.1.gl, &a.0),
                    None => {
                        self.set_error(INVALID_VALUE);
                        Reply::null()
                    }
                }
            }
            ops::Q_ACTIVE_UNIFORM => {
                let (id, i) = (r.u()?, r.u()?);
                let Some(l) = self.programs.get(&id).and_then(|p| p.linked.as_ref()) else {
                    self.set_error(INVALID_VALUE);
                    return Some(Reply::null());
                };
                match l.uniforms.get(i as usize) {
                    Some(u) => active_info(u.count.max(1), u.ty.gl, &u.name),
                    None => {
                        self.set_error(INVALID_VALUE);
                        Reply::null()
                    }
                }
            }
            ops::Q_ATTRIB_LOCATION => {
                let id = r.u()?;
                let name = r.bytes()?;
                let name = String::from_utf8_lossy(name);
                let Some(p) = self.programs.get(&id) else { return Some(Reply::int(-1)) };
                let Some(l) = p.linked.as_ref() else {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::int(-1));
                };
                let loc = l.attributes.iter().find(|a| a.0 == name && a.4).map_or(-1, |a| a.3 as i32);
                Reply::int(loc)
            }
            ops::Q_FRAG_DATA_LOCATION => {
                let id = r.u()?;
                let name = r.bytes()?;
                let name = String::from_utf8_lossy(name);
                let fs = self.programs.get(&id).map(|p| p.fs).unwrap_or(0);
                let loc = self.shaders.get(&fs).and_then(|s| s.compiled.as_ref()).and_then(|s| {
                    let mut next = 0;
                    for o in &s.outputs {
                        let l = o.location.unwrap_or(next);
                        if o.name == name {
                            return Some(l as i32);
                        }
                        next = l + o.slots();
                    }
                    None
                });
                Reply::int(loc.unwrap_or(-1))
            }
            ops::Q_UNIFORM_LOCATION => {
                let id = r.u()?;
                let name = r.bytes()?;
                let name = String::from_utf8_lossy(name);
                let Some(p) = self.programs.get(&id) else { return Some(Reply::int(-1)) };
                let gen = p.generation as i32;
                let Some(l) = p.linked.as_ref() else {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::int(-1));
                };
                let loc = l.names.get(name.as_ref()).map_or(-1, |v| *v as i32);
                let mut reply = Reply::int(loc);
                reply.u(gen as u32);
                reply
            }
            ops::Q_UNIFORM => {
                let (id, loc) = (r.u()?, r.i()?);
                self.get_uniform(id, loc)
            }
            ops::Q_FRAMEBUFFER_STATUS => {
                let t = r.u()?;
                let id = match t {
                    FRAMEBUFFER | DRAW_FRAMEBUFFER if t == FRAMEBUFFER || self.is_webgl2() => self.st.draw_fb,
                    READ_FRAMEBUFFER if self.is_webgl2() => self.st.read_fb,
                    _ => {
                        self.set_error(INVALID_ENUM);
                        return Some(Reply::uint(0));
                    }
                };
                Reply::uint(self.fb_status(id))
            }
            ops::Q_READ_PIXELS => {
                let (x, y, w, h, format, ty) = (r.i()?, r.i()?, r.i()?, r.i()?, r.u()?, r.u()?);
                let (dest_len, pbo_off) = (r.u()? as usize, r.u()?);
                self.read_pixels(x, y, w, h, format, ty, dest_len, pbo_off)
            }
            ops::Q_TEX_PARAMETER => {
                let (t, p) = (r.u()?, r.u()?);
                self.get_tex_parameter(t, p)
            }
            ops::Q_BUFFER_PARAMETER => {
                let (t, p) = (r.u()?, r.u()?);
                let Some(id) = self.buffer_binding(t) else {
                    self.set_error(INVALID_ENUM);
                    return Some(Reply::null());
                };
                if id == 0 {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::null());
                }
                let b = self.buffers.get(&id)?;
                match p {
                    0x8764 => Reply::int(b.shadow.len() as i32),
                    0x8765 => Reply::uint(b.usage),
                    _ => {
                        self.set_error(INVALID_ENUM);
                        Reply::null()
                    }
                }
            }
            ops::Q_RENDERBUFFER_PARAMETER => {
                let (t, p) = (r.u()?, r.u()?);
                if t != RENDERBUFFER {
                    self.set_error(INVALID_ENUM);
                    return Some(Reply::null());
                }
                let id = self.st.renderbuffer;
                let Some(rb) = self.rbs.get(&id) else {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::null());
                };
                let bits = rb.fmt.map_or([0; 6], |f| formats::bits(f.wgpu));
                match p {
                    0x8D42 => Reply::int(rb.w as i32),
                    0x8D43 => Reply::int(rb.h as i32),
                    0x8D44 => Reply::uint(rb.fmt.map_or(0x8056, |f| f.internal)),
                    0x8D50 => Reply::int(bits[0] as i32),
                    0x8D51 => Reply::int(bits[1] as i32),
                    0x8D52 => Reply::int(bits[2] as i32),
                    0x8D53 => Reply::int(bits[3] as i32),
                    0x8D54 => Reply::int(bits[4] as i32),
                    0x8D55 => Reply::int(bits[5] as i32),
                    0x8CAB => Reply::int(if rb.samples > 1 { rb.samples as i32 } else { 0 }),
                    _ => {
                        self.set_error(INVALID_ENUM);
                        Reply::null()
                    }
                }
            }
            ops::Q_ATTACHMENT_PARAMETER => {
                let (t, a, p) = (r.u()?, r.u()?, r.u()?);
                self.attachment_parameter(t, a, p)
            }
            ops::Q_VERTEX_ATTRIB => {
                let (i, p) = (r.u()?, r.u()?);
                self.vertex_attrib_parameter(i, p)
            }
            ops::Q_SAMPLER_PARAMETER => {
                let (id, p) = (r.u()?, r.u()?);
                let Some(s) = self.sampler_objs.get(&id).copied() else {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::null());
                };
                match sampler_param(&s, p) {
                    Some(v) => v,
                    None => {
                        self.set_error(INVALID_ENUM);
                        Reply::null()
                    }
                }
            }
            ops::Q_TF_VARYING => {
                let (id, i) = (r.u()?, r.u()?);
                let Some(l) = self.programs.get(&id).and_then(|p| p.linked.as_ref()) else {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::null());
                };
                match l.tf.vars.get(i as usize) {
                    Some(v) => active_info(v.size, v.ty.gl, &v.name),
                    None => {
                        self.set_error(INVALID_VALUE);
                        Reply::null()
                    }
                }
            }
            ops::Q_QUERY => {
                let (id, pname) = (r.u()?, r.u()?);
                if pname != crate::capture::QUERY_RESULT && pname != crate::capture::QUERY_RESULT_AVAILABLE {
                    self.set_error(INVALID_ENUM);
                    return Some(Reply::null());
                }
                let Some((available, value)) = self.query_answer(id, pname == crate::capture::QUERY_RESULT) else {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::null());
                };
                if pname == crate::capture::QUERY_RESULT_AVAILABLE { Reply::boolean(available) } else { Reply::uint(value) }
            }
            ops::Q_INDEXED => {
                let (t, i) = (r.u()?, r.u()?);
                if matches!(t, 0x8C8F | 0x8C84 | 0x8C85) {
                    let bound = self.st.tf_bound;
                    let Some(e) = self.tf_objects.entry(bound).or_default().binds.get(i as usize).copied() else {
                        self.set_error(INVALID_VALUE);
                        return Some(Reply::null());
                    };
                    return Some(match t {
                        0x8C8F => Reply::object(ops::OBJ_BUFFER, e.0),
                        0x8C84 => Reply::int(e.1 as i32),
                        _ => Reply::int(if e.2 == u32::MAX as u64 { 0 } else { e.2 as i32 }),
                    });
                }
                if t != UNIFORM_BUFFER_BINDING && t != 0x8C84 && t != 0x8A29 && t != 0x8A2A {
                    self.set_error(INVALID_ENUM);
                    return Some(Reply::null());
                }
                let Some(e) = self.st.ubo_ranges.get(i as usize).copied() else {
                    self.set_error(INVALID_VALUE);
                    return Some(Reply::null());
                };
                match t {
                    UNIFORM_BUFFER_BINDING => Reply::object(ops::OBJ_BUFFER, e.0),
                    0x8A29 => Reply::int(e.1 as i32),
                    0x8A2A => Reply::int(if e.2 == u32::MAX as u64 { 0 } else { e.2 as i32 }),
                    _ => Reply::null(),
                }
            }
            ops::Q_BUFFER_SUB_DATA => {
                let (t, off, len) = (r.u()?, r.u()? as usize, r.u()? as usize);
                let Some(id) = self.buffer_binding(t) else {
                    self.set_error(INVALID_ENUM);
                    return Some(Reply::empty());
                };
                self.buffer_sync(id);
                let Some(b) = self.buffers.get(&id) else {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::empty());
                };
                match off.checked_add(len) {
                    Some(end) if end <= b.shadow.len() => Reply { data: b.shadow[off..end].to_vec(), rows: Some((0, len, len)) },
                    _ => {
                        self.set_error(INVALID_VALUE);
                        Reply::empty()
                    }
                }
            }
            ops::Q_BLOCK => {
                let (id, what, i, p) = (r.u()?, r.u()?, r.u()?, r.u()?);
                let name = r.bytes()?;
                self.block_query(id, what, i, p, &String::from_utf8_lossy(name))
            }
            ops::Q_UNIFORM_INDICES => {
                let id = r.u()?;
                let n = r.u()? as usize;
                let mut names = Vec::new();
                if n > 1 << 16 {
                    return None;
                }
                for _ in 0..n {
                    names.push(String::from_utf8_lossy(r.bytes()?).into_owned());
                }
                let Some(l) = self.programs.get(&id).and_then(|p| p.linked.as_ref()) else {
                    self.set_error(INVALID_OPERATION);
                    return Some(Reply::null());
                };
                let list: Vec<String> = all_uniform_names(l);
                let out: Vec<u32> = names.iter().map(|n| list.iter().position(|x| x == n || x.strip_suffix("[0]") == Some(n)).map_or(u32::MAX, |v| v as u32)).collect();
                Reply::uints(&out)
            }
            ops::Q_ACTIVE_UNIFORMS => {
                let (id, p) = (r.u()?, r.u()?);
                let n = r.u()? as usize;
                if n > 1 << 16 {
                    return None;
                }
                let mut idx = Vec::with_capacity(n);
                for _ in 0..n {
                    idx.push(r.u()?);
                }
                self.active_uniforms(id, p, &idx)
            }
            ops::Q_FINISH => {
                self.submit();
                let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
                Reply::null()
            }
            ops::Q_SNAPSHOT => {
                self.submit();
                Reply::null()
            }
            ops::Q_FORMAT_SAMPLES => {
                let (t, internal) = (r.u()?, r.u()?);
                if t != RENDERBUFFER {
                    self.set_error(INVALID_ENUM);
                    return Some(Reply::null());
                }
                match formats::renderbuffer_format(internal, true) {
                    Some(_) if self.limits.max_samples > 1 => Reply::ints(&[self.limits.max_samples as i32]),
                    Some(_) => Reply::ints(&[]),
                    None => {
                        self.set_error(INVALID_ENUM);
                        Reply::null()
                    }
                }
            }
            _ => return None,
        })
    }

    fn validate_program(&mut self, id: u32) {
        let Some(p) = self.programs.get_mut(&id) else { return self.set_error(INVALID_OPERATION) };
        p.validate_status = p.link_status;
    }

    fn program_parameter(&mut self, id: u32, p: u32) -> Reply {
        let Some(prog) = self.programs.get(&id) else {
            self.set_error(INVALID_OPERATION);
            return Reply::null();
        };
        let l = prog.linked.as_ref();
        match p {
            0x8B80 => Reply::boolean(prog.deleted),
            0x8B82 => Reply::boolean(prog.link_status),
            0x8B83 => Reply::boolean(prog.validate_status),
            0x8B85 => Reply::int(prog.vs.min(1) as i32 + prog.fs.min(1) as i32),
            0x8B89 => Reply::int(l.map_or(0, |l| l.attributes.iter().filter(|a| a.4).count()) as i32),
            0x8B86 => Reply::int(l.map_or(0, |l| l.uniforms.len()) as i32),
            0x8A36 if self.is_webgl2() => Reply::int(l.map_or(0, |l| l.blocks.len()) as i32),
            0x8C7F if self.is_webgl2() => Reply::uint(if prog.linked.as_ref().is_some_and(|l| l.tf.separate) { crate::capture::SEPARATE_ATTRIBS } else { crate::capture::INTERLEAVED_ATTRIBS }),
            0x8C83 if self.is_webgl2() => Reply::int(prog.linked.as_ref().map_or(0, |l| l.tf.vars.len() as i32)),
            _ => {
                self.set_error(INVALID_ENUM);
                Reply::null()
            }
        }
    }

    fn get_uniform(&mut self, id: u32, loc: i32) -> Reply {
        let Some(l) = self.programs.get(&id).and_then(|p| p.linked.as_ref()) else {
            self.set_error(INVALID_OPERATION);
            return Reply::null();
        };
        let Some(&Location { uniform, element }) = l.locations.get(loc as usize) else {
            self.set_error(INVALID_OPERATION);
            return Reply::null();
        };
        let u = &l.uniforms[uniform as usize];
        if let Some(first) = u.sampler {
            return Reply::int(l.sampler_units[(first + element) as usize] as i32);
        }
        let (image, at) = match (u.vs, u.fs) {
            (Some(a), _) => (&l.vs_image, a),
            (_, Some(a)) => (&l.fs_image, a),
            _ => return Reply::null(),
        };
        let base = at.0 as usize + element as usize * at.1.max(16) as usize;
        let word = |i: usize| -> u32 {
            let to = base + i;
            match image.get(to..to + 4) {
                Some(b) => u32::from_ne_bytes([b[0], b[1], b[2], b[3]]),
                None => 0,
            }
        };
        let (cols, rows) = (u.ty.cols as usize, u.ty.rows as usize);
        if cols > 1 {
            let mut v = Vec::with_capacity(cols * rows);
            for c in 0..cols {
                for r in 0..rows {
                    v.push(f32::from_bits(word(c * 16 + r * 4)));
                }
            }
            return Reply::floats(&v);
        }
        match u.ty.scalar() {
            translate::Scalar::Float => {
                if rows == 1 {
                    Reply::float(f32::from_bits(word(0)))
                } else {
                    let v: Vec<f32> = (0..rows).map(|r| f32::from_bits(word(r * 4))).collect();
                    Reply::floats(&v)
                }
            }
            translate::Scalar::Int => {
                if rows == 1 {
                    Reply::int(word(0) as i32)
                } else {
                    let v: Vec<i32> = (0..rows).map(|r| word(r * 4) as i32).collect();
                    Reply::ints(&v)
                }
            }
            translate::Scalar::Uint => {
                if rows == 1 {
                    Reply::uint(word(0))
                } else {
                    let v: Vec<u32> = (0..rows).map(|r| word(r * 4)).collect();
                    Reply::uints(&v)
                }
            }
            translate::Scalar::Bool => {
                if rows == 1 {
                    Reply::boolean(word(0) != 0)
                } else {
                    let v: Vec<bool> = (0..rows).map(|r| word(r * 4) != 0).collect();
                    Reply::bools(&v)
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn read_pixels(&mut self, x: i32, y: i32, w: i32, h: i32, format: u32, ty: u32, dest_len: usize, pbo_off: u32) -> Reply {
        if w < 0 || h < 0 {
            self.set_error(INVALID_VALUE);
            return Reply::empty();
        }
        let (src, level, layer, fmt, sw, sh, samples) = match self.read_source() {
            Ok(s) => s,
            Err(e) => {
                self.set_error(e);
                return Reply::empty();
            }
        };
        if samples > 1 {
            self.set_error(INVALID_OPERATION);
            return Reply::empty();
        }
        let Some(obpp) = formats::bytes_per_pixel(format, ty) else {
            self.set_error(INVALID_ENUM);
            return Reply::empty();
        };
        // RGBA / UNSIGNED_BYTE, or the format the framebuffer says
        let (imp_f, imp_t) = formats::implementation_read(fmt.wgpu);
        let basic = (format == formats::RGBA && ty == formats::UNSIGNED_BYTE && formats::sample_kind(fmt.wgpu) == formats::SampleKind::Float)
            || (format == imp_f && ty == imp_t)
            || (self.is_webgl2() && format == formats::RGBA && ty == formats::FLOAT && matches!(formats::sample_kind(fmt.wgpu), formats::SampleKind::Float))
            || (self.is_webgl2() && matches!(format, formats::RED | formats::RG) && matches!(fmt.wgpu, wgpu::TextureFormat::R8Unorm | wgpu::TextureFormat::Rg8Unorm | wgpu::TextureFormat::R32Float | wgpu::TextureFormat::Rg32Float | wgpu::TextureFormat::R16Float | wgpu::TextureFormat::Rg16Float))
            || (self.is_webgl2() && format == formats::RGBA_INTEGER && formats::sample_kind(fmt.wgpu) != formats::SampleKind::Float);
        if !basic {
            self.set_error(if matches!(format, formats::RGBA | formats::RGB | formats::ALPHA | formats::RED | formats::RG | formats::RGBA_INTEGER | formats::RED_INTEGER | formats::RG_INTEGER | formats::RGB_INTEGER) { INVALID_OPERATION } else { INVALID_ENUM });
            return Reply::empty();
        }
        // how it lands in the destination
        let row_px = if self.st.pack_row_length > 0 { self.st.pack_row_length } else { w as u32 } as usize;
        let a = self.st.pack_alignment.max(1) as usize;
        let row = row_px * obpp as usize;
        let stride = (row + a - 1) / a * a;
        let skip = self.st.pack_skip_rows as usize * stride + self.st.pack_skip_pixels as usize * obpp as usize;
        let need = if w == 0 || h == 0 { 0 } else { skip + stride * (h as usize - 1) + w as usize * obpp as usize };
        let to_pbo = self.st.pixel_pack != 0;
        if !to_pbo && need > dest_len {
            self.set_error(INVALID_OPERATION);
            return Reply::empty();
        }
        // the part inside the framebuffer
        let (x0, y0) = (x.max(0), y.max(0));
        let x1 = (x as i64 + w as i64).min(sw as i64) as i32;
        let y1 = (y as i64 + h as i64).min(sh as i64) as i32;
        if x1 <= x0 || y1 <= y0 {
            return Reply::empty();
        }
        let (cw, ch) = ((x1 - x0) as u32, (y1 - y0) as u32);
        let Some((texels, bpr)) = self.read_texture(&src, level, layer, x0 as u32, y0 as u32, cw, ch) else {
            self.set_error(INVALID_OPERATION);
            return Reply::empty();
        };
        let row_bytes = cw as usize * obpp as usize;
        let mut out = vec![0u8; ch as usize * row_bytes];
        if !formats::convert_readback(&texels, bpr, fmt.wgpu, format, ty, cw as usize, ch as usize, row_bytes, &mut out) {
            self.set_error(INVALID_OPERATION);
            return Reply::empty();
        }
        let first = skip + (y0 - y) as usize * stride + (x0 - x) as usize * obpp as usize;
        if to_pbo {
            let id = self.st.pixel_pack;
            let off = pbo_off as usize;
            let total = off + first + stride * (ch as usize - 1) + row_bytes;
            let Some(b) = self.buffers.get_mut(&id) else {
                self.set_error(INVALID_OPERATION);
                return Reply::empty();
            };
            if total > b.shadow.len() {
                self.set_error(INVALID_OPERATION);
                return Reply::empty();
            }
            for r in 0..ch as usize {
                let to = off + first + r * stride;
                b.shadow[to..to + row_bytes].copy_from_slice(&out[r * row_bytes..(r + 1) * row_bytes]);
            }
            b.version += 1;
            self.write_buffer_range(id, off + first, total);
            return Reply::empty();
        }
        Reply { data: out, rows: Some((first, row_bytes, stride)) }
    }

    fn get_tex_parameter(&mut self, target: u32, p: u32) -> Reply {
        let Some(id) = self.tex_binding(target) else {
            self.set_error(INVALID_ENUM);
            return Reply::null();
        };
        if id == 0 {
            self.set_error(INVALID_OPERATION);
            return Reply::null();
        }
        let aniso = self.ext.anisotropic;
        let t = &self.textures[&id];
        if p == TEXTURE_MAX_ANISOTROPY && aniso {
            return Reply::float(f32::from_bits(t.params.anisotropy));
        }
        if self.attrs.webgl2 {
            match p {
                TEXTURE_BASE_LEVEL => return Reply::int(t.base_level as i32),
                TEXTURE_MAX_LEVEL => return Reply::int(t.max_level as i32),
                TEXTURE_IMMUTABLE_FORMAT => return Reply::boolean(t.immutable > 0),
                TEXTURE_IMMUTABLE_LEVELS => return Reply::int(t.immutable as i32),
                _ => {}
            }
        }
        match sampler_param(&t.params, p).filter(|_| self.attrs.webgl2 || matches!(p, TEXTURE_MAG_FILTER | TEXTURE_MIN_FILTER | TEXTURE_WRAP_S | TEXTURE_WRAP_T)) {
            Some(v) => v,
            None => {
                self.set_error(INVALID_ENUM);
                Reply::null()
            }
        }
    }

    fn attachment_parameter(&mut self, target: u32, attachment: u32, p: u32) -> Reply {
        let fb = match target {
            FRAMEBUFFER | DRAW_FRAMEBUFFER if target == FRAMEBUFFER || self.is_webgl2() => self.st.draw_fb,
            READ_FRAMEBUFFER if self.is_webgl2() => self.st.read_fb,
            _ => {
                self.set_error(INVALID_ENUM);
                return Reply::null();
            }
        };
        const OBJECT_TYPE: u32 = 0x8CD0;
        const OBJECT_NAME: u32 = 0x8CD1;
        const TEXTURE_LEVEL: u32 = 0x8CD2;
        const CUBE_FACE: u32 = 0x8CD3;
        const TEXTURE_LAYER: u32 = 0x8CD4;
        if fb == 0 {
            if !self.is_webgl2() {
                self.set_error(INVALID_OPERATION);
                return Reply::null();
            }
            return match p {
                OBJECT_TYPE => Reply::uint(0x1702), // FRAMEBUFFER_DEFAULT
                _ => Reply::null(),
            };
        }
        let Some(f) = self.fbs.get(&fb) else {
            self.set_error(INVALID_OPERATION);
            return Reply::null();
        };
        let a = match attachment {
            COLOR_ATTACHMENT0..=0x8CEF if ((attachment - COLOR_ATTACHMENT0) as usize) < MAX_COLOR_ATTACHMENTS => f.color[(attachment - COLOR_ATTACHMENT0) as usize],
            DEPTH_ATTACHMENT => f.depth,
            STENCIL_ATTACHMENT => f.stencil,
            DEPTH_STENCIL_ATTACHMENT => f.depth,
            _ => {
                self.set_error(INVALID_ENUM);
                return Reply::null();
            }
        };
        let Some(a) = a else {
            return match p {
                OBJECT_TYPE => Reply::uint(0),
                OBJECT_NAME => Reply::null(),
                _ => {
                    self.set_error(INVALID_OPERATION);
                    Reply::null()
                }
            };
        };
        match (p, a) {
            (OBJECT_TYPE, Attach::Tex { .. }) => Reply::uint(0x1702),
            (OBJECT_TYPE, Attach::Rb { .. }) => Reply::uint(RENDERBUFFER),
            (OBJECT_NAME, Attach::Tex { id, .. }) => Reply::object(ops::OBJ_TEXTURE, id),
            (OBJECT_NAME, Attach::Rb { id }) => Reply::object(ops::OBJ_RENDERBUFFER, id),
            (TEXTURE_LEVEL, Attach::Tex { level, .. }) => Reply::int(level as i32),
            (CUBE_FACE, Attach::Tex { id, layer, .. }) => {
                let cube = self.textures.get(&id).map_or(false, |t| t.target == TEXTURE_CUBE_MAP);
                Reply::uint(if cube { TEXTURE_CUBE_MAP_POSITIVE_X + layer } else { 0 })
            }
            (TEXTURE_LAYER, Attach::Tex { layer, .. }) if self.is_webgl2() => Reply::int(layer as i32),
            (0x8210..=0x8217, _) if self.is_webgl2() => {
                let info = self.attachment_info(&a);
                let bits = info.map_or([0; 6], |i| formats::bits(i.2.wgpu));
                match p {
                    0x8212 => Reply::int(bits[0] as i32),
                    0x8213 => Reply::int(bits[1] as i32),
                    0x8214 => Reply::int(bits[2] as i32),
                    0x8215 => Reply::int(bits[3] as i32),
                    0x8216 => Reply::int(bits[4] as i32),
                    0x8217 => Reply::int(bits[5] as i32),
                    0x8211 => Reply::uint(info.map_or(0, |i| match i.2.sample_kind() {
                        formats::SampleKind::Sint => formats::INT,
                        formats::SampleKind::Uint => formats::UNSIGNED_INT,
                        _ => 0x8C17, // UNSIGNED_NORMALIZED
                    })),
                    _ => Reply::uint(if info.map_or(false, |i| i.2.wgpu.is_srgb()) { 0x8C40 } else { 0x2601 }),
                }
            }
            _ => {
                self.set_error(INVALID_ENUM);
                Reply::null()
            }
        }
    }

    fn vertex_attrib_parameter(&mut self, i: u32, p: u32) -> Reply {
        if i >= self.caps.max_vertex_attribs {
            self.set_error(INVALID_VALUE);
            return Reply::null();
        }
        let a = self.current_vao().attrs[i as usize];
        match p {
            0x8622 => Reply::boolean(a.enabled),
            0x8623 => Reply::int(a.size as i32),
            0x8624 => Reply::int(a.stride as i32),
            0x8625 => Reply::uint(a.ty),
            0x886A => Reply::boolean(a.normalized),
            0x88FE => Reply::int(a.divisor as i32),
            0x88FD if self.is_webgl2() => Reply::boolean(a.integer),
            0x889F => Reply::object(ops::OBJ_BUFFER, a.buffer),
            0x8626 => {
                let g = self.st.generic[i as usize];
                match self.st.generic_kind[i as usize] {
                    1 => Reply::ints(&[g[0] as i32, g[1] as i32, g[2] as i32, g[3] as i32]),
                    2 => Reply::uints(&g),
                    _ => Reply::floats(&[f32::from_bits(g[0]), f32::from_bits(g[1]), f32::from_bits(g[2]), f32::from_bits(g[3])]),
                }
            }
            0x8645 => Reply::uint(a.offset),
            _ => {
                self.set_error(INVALID_ENUM);
                Reply::null()
            }
        }
    }

    fn block_query(&mut self, id: u32, what: u32, i: u32, p: u32, name: &str) -> Reply {
        let Some(prog) = self.programs.get(&id) else {
            self.set_error(INVALID_OPERATION);
            return Reply::null();
        };
        let Some(l) = prog.linked.as_ref() else {
            self.set_error(INVALID_OPERATION);
            return Reply::null();
        };
        match what {
            0 => Reply::uint(l.blocks.iter().position(|b| b.name == name).map_or(u32::MAX, |v| v as u32)),
            1 => match l.blocks.get(i as usize) {
                Some(b) => Reply::string(&b.name),
                None => {
                    self.set_error(INVALID_VALUE);
                    Reply::null()
                }
            },
            _ => {
                let Some(b) = l.blocks.get(i as usize) else {
                    self.set_error(INVALID_VALUE);
                    return Reply::null();
                };
                match p {
                    UNIFORM_BLOCK_BINDING => Reply::int(l.block_bindings[i as usize] as i32),
                    UNIFORM_BLOCK_DATA_SIZE => Reply::int(b.size as i32),
                    UNIFORM_BLOCK_ACTIVE_UNIFORMS => Reply::int(b.members.len() as i32),
                    UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES => {
                        let list = all_uniform_names(l);
                        let v: Vec<u32> = b.members.iter().map(|m| list.iter().position(|x| x == &m.name).map_or(0, |v| v as u32)).collect();
                        Reply::uints(&v)
                    }
                    UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER => Reply::boolean(true),
                    UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER => Reply::boolean(true),
                    _ => {
                        self.set_error(INVALID_ENUM);
                        Reply::null()
                    }
                }
            }
        }
    }

    fn active_uniforms(&mut self, id: u32, p: u32, idx: &[u32]) -> Reply {
        let Some(l) = self.programs.get(&id).and_then(|p| p.linked.as_ref()) else {
            self.set_error(INVALID_OPERATION);
            return Reply::null();
        };
        let mut out = Vec::with_capacity(idx.len());
        for i in idx {
            let Some(u) = l.uniforms.get(*i as usize) else {
                self.set_error(INVALID_VALUE);
                return Reply::null();
            };
            out.push(match p {
                0x8A37 => u.ty.gl as i32,
                0x8A38 => u.count.max(1) as i32,
                0x8A3A => u.block.map_or(-1, |b| b.0 as i32),
                0x8A3B => u.block.map_or(-1, |b| b.1 as i32),
                0x8A3C => u.block.map_or(-1, |b| b.2 as i32),
                0x8A3D => u.block.map_or(-1, |b| b.3 as i32),
                0x8A3E => 0,
                _ => {
                    self.set_error(INVALID_ENUM);
                    return Reply::null();
                }
            });
        }
        Reply::ints(&out)
    }

    fn fb_bits(&mut self) -> [u32; 6] {
        let fb = self.st.draw_fb;
        if fb == 0 {
            let mut b = [8, 8, 8, if self.attrs.alpha { 8 } else { 0 }, 0, 0];
            if let Some(f) = self.bb.format_ds {
                let x = formats::bits(f);
                b[4] = if self.attrs.depth { x[4] } else { 0 };
                b[5] = if self.attrs.stencil { x[5] } else { 0 };
            }
            return b;
        }
        let Some(f) = self.fbs.get(&fb).cloned() else { return [0; 6] };
        let mut b = [0; 6];
        if let Some(a) = f.color[0] {
            if let Some(i) = self.attachment_info(&a) {
                let x = formats::bits(i.2.wgpu);
                b[..4].copy_from_slice(&x[..4]);
            }
        }
        if let Some(a) = f.depth {
            if let Some(i) = self.attachment_info(&a) {
                b[4] = formats::bits(i.2.wgpu)[4];
            }
        }
        if let Some(a) = f.stencil {
            if let Some(i) = self.attachment_info(&a) {
                b[5] = formats::bits(i.2.wgpu)[5];
            }
        }
        b
    }

    fn get_parameter(&mut self, p: u32) -> Reply {
        let w2 = self.is_webgl2();
        let u = self.st.active_unit as usize;
        match p {
            VENDOR => return Reply::string("Wren"),
            RENDERER => return Reply::string("Wren WebGL"),
            VERSION => return Reply::string(if w2 { "WebGL 2.0 (OpenGL ES 3.0 Wren)" } else { "WebGL 1.0 (OpenGL ES 2.0 Wren)" }),
            SHADING_LANGUAGE_VERSION => return Reply::string(if w2 { "WebGL GLSL ES 3.00 (Wren)" } else { "WebGL GLSL ES 1.0 (Wren)" }),
            ACTIVE_TEXTURE => return Reply::uint(0x84C0 + self.st.active_unit),
            ALIASED_LINE_WIDTH_RANGE => return Reply::floats(&[1.0, 1.0]),
            ALIASED_POINT_SIZE_RANGE => return Reply::floats(&[1.0, MAX_POINT_SIZE]),
            RED_BITS | GREEN_BITS | BLUE_BITS | ALPHA_BITS | DEPTH_BITS | STENCIL_BITS => {
                let b = self.fb_bits();
                return Reply::int(b[match p {
                    RED_BITS => 0,
                    GREEN_BITS => 1,
                    BLUE_BITS => 2,
                    ALPHA_BITS => 3,
                    DEPTH_BITS => 4,
                    _ => 5,
                }] as i32);
            }
            ARRAY_BUFFER_BINDING => return Reply::object(ops::OBJ_BUFFER, self.st.array_buffer),
            ELEMENT_ARRAY_BUFFER_BINDING => {
                let e = self.current_vao().element;
                return Reply::object(ops::OBJ_BUFFER, e);
            }
            BLEND_COLOR => return Reply::floats(&self.st.blend_color),
            BLEND_SRC_RGB => return Reply::uint(self.st.blend_func[0]),
            BLEND_DST_RGB => return Reply::uint(self.st.blend_func[1]),
            BLEND_SRC_ALPHA => return Reply::uint(self.st.blend_func[2]),
            BLEND_DST_ALPHA => return Reply::uint(self.st.blend_func[3]),
            BLEND_EQUATION_RGB => return Reply::uint(self.st.blend_eq[0]),
            BLEND_EQUATION_ALPHA => return Reply::uint(self.st.blend_eq[1]),
            COLOR_CLEAR_VALUE => return Reply::floats(&self.st.clear_color),
            COLOR_WRITEMASK => return Reply::bools(&self.st.color_mask),
            COMPRESSED_TEXTURE_FORMATS => {
                if self.ext.s3tc {
                    return Reply::uints(&[0x83F0, 0x83F1, 0x83F2, 0x83F3]);
                }
                return Reply::uints(&[]);
            }
            CULL_FACE => return Reply::boolean(self.st.cull),
            CULL_FACE_MODE => return Reply::uint(self.st.cull_face),
            BLEND => return Reply::boolean(self.st.blend),
            DITHER => return Reply::boolean(self.st.dither),
            DEPTH_TEST => return Reply::boolean(self.st.depth_test),
            STENCIL_TEST => return Reply::boolean(self.st.stencil_test),
            SCISSOR_TEST => return Reply::boolean(self.st.scissor_test),
            POLYGON_OFFSET_FILL => return Reply::boolean(self.st.polygon_offset),
            SAMPLE_ALPHA_TO_COVERAGE => return Reply::boolean(self.st.alpha_to_coverage),
            SAMPLE_COVERAGE => return Reply::boolean(self.st.sample_coverage),
            RASTERIZER_DISCARD if w2 => return Reply::boolean(self.st.rasterizer_discard),
            CURRENT_PROGRAM => return Reply::object(ops::OBJ_PROGRAM, self.st.program),
            DEPTH_CLEAR_VALUE => return Reply::float(self.st.clear_depth),
            DEPTH_FUNC => return Reply::uint(self.st.depth_func),
            DEPTH_RANGE => return Reply::floats(&self.st.depth_range),
            DEPTH_WRITEMASK => return Reply::boolean(self.st.depth_mask),
            FRAMEBUFFER_BINDING => return Reply::object(ops::OBJ_FRAMEBUFFER, self.st.draw_fb),
            FRONT_FACE => return Reply::uint(self.st.front_face),
            GENERATE_MIPMAP_HINT => return Reply::uint(self.st.generate_mipmap_hint),
            IMPLEMENTATION_COLOR_READ_FORMAT | IMPLEMENTATION_COLOR_READ_TYPE => {
                let f = self.read_source().map(|s| s.3.wgpu).unwrap_or(wgpu::TextureFormat::Rgba8Unorm);
                let (a, b) = formats::implementation_read(f);
                return Reply::uint(if p == IMPLEMENTATION_COLOR_READ_FORMAT { a } else { b });
            }
            LINE_WIDTH => return Reply::float(self.st.line_width),
            MAX_COMBINED_TEXTURE_IMAGE_UNITS => return Reply::int(self.caps.max_combined_texture_units as i32),
            MAX_CUBE_MAP_TEXTURE_SIZE => return Reply::int(self.limits.max_cube as i32),
            MAX_FRAGMENT_UNIFORM_VECTORS => return Reply::int(self.caps.max_fragment_uniform_vectors as i32),
            MAX_RENDERBUFFER_SIZE => return Reply::int(self.limits.max_renderbuffer as i32),
            MAX_TEXTURE_IMAGE_UNITS => return Reply::int(self.caps.max_texture_units as i32),
            MAX_TEXTURE_SIZE => return Reply::int(self.limits.max_texture as i32),
            MAX_VARYING_VECTORS => return Reply::int(self.caps.max_varying_vectors as i32),
            MAX_VERTEX_ATTRIBS => return Reply::int(self.caps.max_vertex_attribs as i32),
            MAX_VERTEX_TEXTURE_IMAGE_UNITS => return Reply::int(self.caps.max_vertex_texture_units as i32),
            MAX_VERTEX_UNIFORM_VECTORS => return Reply::int(self.caps.max_vertex_uniform_vectors as i32),
            MAX_VIEWPORT_DIMS => return Reply::ints(&[self.limits.max_texture as i32, self.limits.max_texture as i32]),
            PACK_ALIGNMENT_P => return Reply::int(self.st.pack_alignment as i32),
            UNPACK_ALIGNMENT => return Reply::int(self.st.unpack.alignment as i32),
            UNPACK_FLIP_Y_WEBGL => return Reply::boolean(self.st.unpack.flip_y),
            UNPACK_PREMULTIPLY_ALPHA_WEBGL => return Reply::boolean(self.st.unpack.premultiply),
            UNPACK_COLORSPACE_CONVERSION_WEBGL => return Reply::uint(self.st.colorspace),
            POLYGON_OFFSET_FACTOR => return Reply::float(self.st.polygon_factor),
            POLYGON_OFFSET_UNITS => return Reply::float(self.st.polygon_units),
            RENDERBUFFER_BINDING => return Reply::object(ops::OBJ_RENDERBUFFER, self.st.renderbuffer),
            SAMPLE_BUFFERS => {
                let s = self.target_of(self.st.draw_fb).map_or(1, |t| t.samples);
                return Reply::int((s > 1) as i32);
            }
            SAMPLES => {
                let s = self.target_of(self.st.draw_fb).map_or(1, |t| t.samples);
                return Reply::int(if s > 1 { s as i32 } else { 0 });
            }
            SAMPLE_COVERAGE_INVERT => return Reply::boolean(self.st.coverage.1),
            SAMPLE_COVERAGE_VALUE => return Reply::float(self.st.coverage.0),
            SCISSOR_BOX => return Reply::ints(&self.st.scissor),
            STENCIL_BACK_FAIL => return Reply::uint(self.st.stencil_back.fail),
            STENCIL_BACK_FUNC => return Reply::uint(self.st.stencil_back.func),
            STENCIL_BACK_PASS_DEPTH_FAIL => return Reply::uint(self.st.stencil_back.zfail),
            STENCIL_BACK_PASS_DEPTH_PASS => return Reply::uint(self.st.stencil_back.zpass),
            STENCIL_BACK_REF => return Reply::int(self.st.stencil_back.reference),
            STENCIL_BACK_VALUE_MASK => return Reply::uint(self.st.stencil_back.read_mask),
            STENCIL_BACK_WRITEMASK => return Reply::uint(self.st.stencil_back.write_mask),
            STENCIL_CLEAR_VALUE => return Reply::int(self.st.clear_stencil),
            STENCIL_FAIL => return Reply::uint(self.st.stencil_front.fail),
            STENCIL_FUNC => return Reply::uint(self.st.stencil_front.func),
            STENCIL_PASS_DEPTH_FAIL => return Reply::uint(self.st.stencil_front.zfail),
            STENCIL_PASS_DEPTH_PASS => return Reply::uint(self.st.stencil_front.zpass),
            STENCIL_REF => return Reply::int(self.st.stencil_front.reference),
            STENCIL_VALUE_MASK => return Reply::uint(self.st.stencil_front.read_mask),
            STENCIL_WRITEMASK => return Reply::uint(self.st.stencil_front.write_mask),
            SUBPIXEL_BITS => return Reply::int(4),
            TEXTURE_BINDING_2D => return Reply::object(ops::OBJ_TEXTURE, self.st.tex_2d[u]),
            TEXTURE_BINDING_CUBE_MAP => return Reply::object(ops::OBJ_TEXTURE, self.st.tex_cube[u]),
            VIEWPORT => return Reply::ints(&self.st.viewport),
            VERTEX_ARRAY_BINDING if w2 || self.ext.vao => return Reply::object(ops::OBJ_VAO, self.st.vao),
            FRAGMENT_SHADER_DERIVATIVE_HINT if w2 || self.ext.standard_derivatives => return Reply::uint(self.st.derivative_hint),
            MAX_TEXTURE_MAX_ANISOTROPY if self.ext.anisotropic => return Reply::float(self.limits.max_anisotropy),
            MAX_COLOR_ATTACHMENTS_P | MAX_DRAW_BUFFERS if w2 || self.ext.draw_buffers => return Reply::int(self.caps.max_draw_buffers as i32),
            DRAW_BUFFER0..=0x8834 if w2 || self.ext.draw_buffers => {
                let i = (p - DRAW_BUFFER0) as usize;
                let fb = self.st.draw_fb;
                if fb == 0 {
                    return Reply::uint(if i == 0 { BACK } else { NONE });
                }
                return Reply::uint(self.fbs.get(&fb).map_or(NONE, |f| f.draw_buffers.get(i).copied().unwrap_or(NONE)));
            }
            _ => {}
        }
        if w2 {
            let m = self.limits.max_uniform_block as i32;
            let v = match p {
                MAX_3D_TEXTURE_SIZE => Some(self.limits.max_3d as i32),
                MAX_ARRAY_TEXTURE_LAYERS => Some(self.limits.max_array_layers as i32),
                MAX_COMBINED_UNIFORM_BLOCKS => Some(24),
                MAX_VERTEX_UNIFORM_BLOCKS | MAX_FRAGMENT_UNIFORM_BLOCKS => Some(12),
                MAX_FRAGMENT_INPUT_COMPONENTS | MAX_VERTEX_OUTPUT_COMPONENTS | MAX_VARYING_COMPONENTS => Some(self.caps.max_varying_vectors as i32 * 4),
                MAX_FRAGMENT_UNIFORM_COMPONENTS => Some(self.caps.max_fragment_uniform_vectors as i32 * 4),
                MAX_VERTEX_UNIFORM_COMPONENTS => Some(self.caps.max_vertex_uniform_vectors as i32 * 4),
                MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS | MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS => Some(self.caps.max_fragment_uniform_vectors as i32 * 4 + 12 * m / 4),
                MAX_ELEMENT_INDEX => return Reply::float(4294967295.0),
                MAX_ELEMENTS_INDICES | MAX_ELEMENTS_VERTICES => Some(i32::MAX),
                MAX_PROGRAM_TEXEL_OFFSET => Some(7),
                MIN_PROGRAM_TEXEL_OFFSET => Some(-8),
                MAX_SAMPLES => Some(self.limits.max_samples as i32),
                MAX_SERVER_WAIT_TIMEOUT => Some(0),
                MAX_TEXTURE_LOD_BIAS => return Reply::float(2.0),
                // (0 on a device that cannot capture: capture.rs)
                MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS => Some(if self.tf_available() { crate::capture::MAX_TF_INTERLEAVED_COMPONENTS as i32 } else { 0 }),
                MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS => Some(if self.tf_available() { crate::capture::MAX_TF_BUFFERS as i32 } else { 0 }),
                MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS => Some(if self.tf_available() { crate::capture::MAX_TF_SEPARATE_COMPONENTS as i32 } else { 0 }),
                0x8E23 => {
                    let t = self.st.tf_bound;
                    return Reply::boolean(self.tf_objects.get(&t).is_some_and(|o| o.active && o.paused));
                }
                0x8E24 => {
                    let t = self.st.tf_bound;
                    return Reply::boolean(self.tf_objects.get(&t).is_some_and(|o| o.active));
                }
                0x8E25 => return Reply::object(ops::OBJ_TF, self.st.tf_bound),
                MAX_UNIFORM_BLOCK_SIZE => Some(m),
                MAX_UNIFORM_BUFFER_BINDINGS_P => Some(MAX_UNIFORM_BUFFER_BINDINGS as i32),
                UNIFORM_BUFFER_OFFSET_ALIGNMENT => Some(self.limits.ubo_align as i32),
                PACK_ROW_LENGTH => Some(self.st.pack_row_length as i32),
                PACK_SKIP_PIXELS => Some(self.st.pack_skip_pixels as i32),
                PACK_SKIP_ROWS => Some(self.st.pack_skip_rows as i32),
                UNPACK_IMAGE_HEIGHT => Some(self.st.unpack.image_height as i32),
                UNPACK_ROW_LENGTH => Some(self.st.unpack.row_length as i32),
                UNPACK_SKIP_IMAGES => Some(self.st.unpack.skip_images as i32),
                UNPACK_SKIP_PIXELS => Some(self.st.unpack.skip_pixels as i32),
                UNPACK_SKIP_ROWS => Some(self.st.unpack.skip_rows as i32),
                _ => None,
            };
            if let Some(v) = v {
                return Reply::int(v);
            }
            match p {
                COPY_READ_BUFFER_BINDING => return Reply::object(ops::OBJ_BUFFER, self.st.copy_read),
                COPY_WRITE_BUFFER_BINDING => return Reply::object(ops::OBJ_BUFFER, self.st.copy_write),
                READ_FRAMEBUFFER_BINDING => return Reply::object(ops::OBJ_FRAMEBUFFER, self.st.read_fb),
                DRAW_FRAMEBUFFER_BINDING => return Reply::object(ops::OBJ_FRAMEBUFFER, self.st.draw_fb),
                PIXEL_PACK_BUFFER_BINDING => return Reply::object(ops::OBJ_BUFFER, self.st.pixel_pack),
                PIXEL_UNPACK_BUFFER_BINDING => return Reply::object(ops::OBJ_BUFFER, self.st.pixel_unpack),
                SAMPLER_BINDING => return Reply::object(ops::OBJ_SAMPLER, self.st.samplers[u]),
                TEXTURE_BINDING_2D_ARRAY => return Reply::object(ops::OBJ_TEXTURE, self.st.tex_array[u]),
                TEXTURE_BINDING_3D => return Reply::object(ops::OBJ_TEXTURE, self.st.tex_3d[u]),
                TRANSFORM_FEEDBACK_BUFFER_BINDING => return Reply::object(ops::OBJ_BUFFER, self.st.tf_buffer),
                UNIFORM_BUFFER_BINDING => return Reply::object(ops::OBJ_BUFFER, self.st.uniform_buffer),
                READ_BUFFER_P => {
                    let fb = self.st.read_fb;
                    return Reply::uint(if fb == 0 { BACK } else { self.fbs.get(&fb).map_or(COLOR_ATTACHMENT0, |f| f.read_buffer) });
                }
                _ => {}
            }
        }
        self.set_error(INVALID_ENUM);
        Reply::null()
    }
}

fn active_info(size: u32, ty: u32, name: &str) -> Reply {
    let mut r = Reply::tag(ops::TAG_INTS);
    r.u(2);
    r.u(size);
    r.u(ty);
    r.u(name.len() as u32);
    r.data.extend_from_slice(name.as_bytes());
    r
}

fn sampler_param(s: &SamplerState, p: u32) -> Option<Reply> {
    Some(match p {
        TEXTURE_MAG_FILTER => Reply::uint(s.mag),
        TEXTURE_MIN_FILTER => Reply::uint(s.min),
        TEXTURE_WRAP_S => Reply::uint(s.wrap_s),
        TEXTURE_WRAP_T => Reply::uint(s.wrap_t),
        TEXTURE_WRAP_R => Reply::uint(s.wrap_r),
        TEXTURE_MIN_LOD => Reply::float(f32::from_bits(s.min_lod)),
        TEXTURE_MAX_LOD => Reply::float(f32::from_bits(s.max_lod)),
        TEXTURE_COMPARE_MODE => Reply::uint(s.compare_mode),
        TEXTURE_COMPARE_FUNC => Reply::uint(s.compare_func),
        _ => return None,
    })
}

fn all_uniform_names(l: &Linked) -> Vec<String> {
    l.uniforms.iter().map(|u| u.name.clone()).collect()
}
