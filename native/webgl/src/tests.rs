//! A context end to end through the C ABI, on the software adapter (WARP on Windows, lavapipe on Linux). A machine without one
//! skips these: what must not fail is the absence of a GPU.

use super::*;
use crate::gl::*;
use crate::ops;

/// The command stream, as web_webgl.js writes it.
#[derive(Default)]
struct C {
    d: Vec<u8>,
}

impl C {
    fn u(&mut self, v: u32) -> &mut Self {
        self.d.extend_from_slice(&v.to_ne_bytes());
        self
    }
    fn f(&mut self, v: f32) -> &mut Self {
        self.u(v.to_bits())
    }
    fn b(&mut self, data: &[u8]) -> &mut Self {
        self.u(data.len() as u32);
        self.d.extend_from_slice(data);
        while self.d.len() % 4 != 0 {
            self.d.push(0);
        }
        self
    }
    fn s(&mut self, text: &str) -> &mut Self {
        self.b(text.as_bytes())
    }
}

struct Gl {
    h: *mut Handle,
}

impl Drop for Gl {
    fn drop(&mut self) {
        unsafe { wg_destroy(self.h) }
    }
}

fn attrs(webgl2: bool, w: u32, h: u32) -> WgAttrs {
    WgAttrs {
        webgl2: webgl2 as i32,
        alpha: 1,
        depth: 1,
        stencil: 1,
        antialias: 0,
        premultiplied: 1,
        preserve: 0,
        fail_if_major_performance_caveat: 0,
        width: w,
        height: h,
        max_dimension: 16384,
        allow_software: 1,
        force_software: std::env::var_os("WREN_WEBGL_TEST_GPU").is_none() as i32,
        backend: BACKEND_AUTO,
        max_bytes: 1 << 30,
        wait_ms: 60_000,
        notify: None,
        notify_user: std::ptr::null_mut(),
    }
}

fn context(a: WgAttrs) -> Option<Gl> {
    let mut info = WgInfo::default();
    let mut err = [0u8; 256];
    let mut n = 0usize;
    let h = unsafe { wg_create(&a, &mut info, err.as_mut_ptr() as *mut _, err.len(), &mut n) };
    if h.is_null() {
        eprintln!("no context: {}", String::from_utf8_lossy(&err[..n]));
        return None;
    }
    Some(Gl { h })
}

impl Gl {
    fn send(&self, c: &C) {
        unsafe { wg_submit(self.h, c.d.as_ptr(), c.d.len(), std::ptr::null(), 0) }
    }
    fn q(&self, c: &C, cap: usize) -> Vec<u8> {
        let mut out = vec![0u8; cap];
        let n = unsafe { wg_query(self.h, c.d.as_ptr(), c.d.len(), out.as_mut_ptr(), cap) };
        assert!(n >= 0, "the context answered nothing");
        out.truncate((n as usize).min(cap));
        out
    }
    fn error(&self) -> u32 {
        let mut c = C::default();
        c.u(ops::Q_ERROR);
        let r = self.q(&c, 16);
        u32::from_ne_bytes([r[4], r[5], r[6], r[7]])
    }
    fn pixels(&self, x: i32, y: i32, w: i32, h: i32) -> Vec<u8> {
        let mut c = C::default();
        let cap = (w * h * 4) as usize;
        c.u(ops::Q_READ_PIXELS).u(x as u32).u(y as u32).u(w as u32).u(h as u32).u(formats::RGBA).u(formats::UNSIGNED_BYTE).u(cap as u32).u(0);
        let mut out = vec![0u8; cap];
        let n = unsafe { wg_query(self.h, c.d.as_ptr(), c.d.len(), out.as_mut_ptr(), cap) };
        assert!(n >= 0);
        out
    }
    fn program(&self, id: u32, vs: &str, fs: &str) -> bool {
        let mut c = C::default();
        c.u(ops::SHADER_SOURCE).u(id + 1).u(0x8B31).s(vs);
        c.u(ops::COMPILE_SHADER).u(id + 1);
        c.u(ops::SHADER_SOURCE).u(id + 2).u(0x8B30).s(fs);
        c.u(ops::COMPILE_SHADER).u(id + 2);
        c.u(ops::ATTACH_SHADER).u(id).u(id + 1);
        c.u(ops::ATTACH_SHADER).u(id).u(id + 2);
        c.u(ops::LINK_PROGRAM).u(id);
        self.send(&c);
        let mut q = C::default();
        q.u(ops::Q_PROGRAM).u(id).u(0x8B82);
        let r = self.q(&q, 16);
        let ok = u32::from_ne_bytes([r[4], r[5], r[6], r[7]]) != 0;
        if !ok {
            let mut q = C::default();
            q.u(ops::Q_PROGRAM_LOG).u(id);
            eprintln!("link: {}", String::from_utf8_lossy(&self.q(&q, 4096)));
            for s in [id + 1, id + 2] {
                let mut q = C::default();
                q.u(ops::Q_SHADER_LOG).u(s);
                eprintln!("shader: {}", String::from_utf8_lossy(&self.q(&q, 4096)));
            }
        }
        ok
    }
    fn uniform_location(&self, p: u32, name: &str) -> i32 {
        let mut c = C::default();
        c.u(ops::Q_UNIFORM_LOCATION).u(p).s(name);
        let r = self.q(&c, 32);
        i32::from_ne_bytes([r[4], r[5], r[6], r[7]])
    }
}

fn floats(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|x| x.to_ne_bytes()).collect()
}

const VS: &str = "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }";
const FS_COLOR: &str = "precision mediump float; uniform vec4 c; void main(){ gl_FragColor = c; }";

/// Sets up a program with attribute p and a triangle that covers everything.
fn full_triangle(gl: &Gl, id: u32, fs: &str) {
    assert!(gl.program(id, VS, fs));
    let mut c = C::default();
    c.u(ops::USE_PROGRAM).u(id);
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(1);
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[-1.0, -1.0, 3.0, -1.0, -1.0, 3.0]));
    c.u(ops::ENABLE_ATTRIB).u(0);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(0).u(2).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    gl.send(&c);
}

fn draw3() -> C {
    let mut c = C::default();
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    c
}

#[test]
fn a_triangle_is_read_back() {
    let Some(gl) = context(attrs(false, 16, 16)) else { return };
    full_triangle(&gl, 10, FS_COLOR);
    let loc = gl.uniform_location(10, "c");
    assert!(loc >= 0);
    let mut c = C::default();
    c.u(ops::CLEAR_COLOR).f(0.0).f(0.0).f(1.0).f(1.0).u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    c.u(ops::UNIFORM).u(loc as u32).u(4).u(1).b(&floats(&[1.0, 0.0, 0.0, 1.0]));
    gl.send(&c);
    gl.send(&draw3());
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(8, 8, 1, 1), [255, 0, 0, 255]);
}

#[test]
fn the_rows_are_gls() {
    let Some(gl) = context(attrs(false, 8, 8)) else { return };
    assert!(gl.program(10, "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }", "precision mediump float; void main(){ gl_FragColor = vec4(gl_FragCoord.y < 4.0 ? 1.0 : 0.0, 0.0, 0.0, 1.0); }"));
    let mut c = C::default();
    c.u(ops::USE_PROGRAM).u(10);
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(1);
    // only the bottom half of clip space
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[-1.0, -1.0, 1.0, -1.0, -1.0, 0.0, 1.0, -1.0, 1.0, 0.0, -1.0, 0.0]));
    c.u(ops::ENABLE_ATTRIB).u(0);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(0).u(2).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(6).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    // y = 0 is the bottom row, as in GL
    assert_eq!(gl.pixels(4, 0, 1, 1), [255, 0, 0, 255]);
    assert_eq!(gl.pixels(4, 7, 1, 1), [0, 0, 0, 0]);
}

#[test]
fn counter_clockwise_is_the_front() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    assert!(gl.program(10, VS, "precision mediump float; void main(){ gl_FragColor = gl_FrontFacing ? vec4(1.0, 0.0, 0.0, 1.0) : vec4(0.0, 1.0, 0.0, 1.0); }"));
    let mut c = C::default();
    c.u(ops::USE_PROGRAM).u(10);
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(1);
    // counter-clockwise in clip space, y up
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[-1.0, -1.0, 3.0, -1.0, -1.0, 3.0]));
    c.u(ops::ENABLE_ATTRIB).u(0);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(0).u(2).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    gl.send(&c);
    assert_eq!(gl.pixels(1, 1, 1, 1), [255, 0, 0, 255], "gl_FrontFacing");
    let mut c = C::default();
    c.u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    c.u(ops::ENABLE).u(CULL_FACE);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    gl.send(&c);
    assert_eq!(gl.pixels(1, 1, 1, 1), [255, 0, 0, 255], "culling the back keeps it");
    let mut c = C::default();
    c.u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    c.u(ops::CULL_FACE).u(FRONT);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    gl.send(&c);
    assert_eq!(gl.pixels(1, 1, 1, 1), [0, 0, 0, 0], "culling the front drops it");
    let mut c = C::default();
    c.u(ops::FRONT_FACE).u(0x0900);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    gl.send(&c);
    assert_eq!(gl.pixels(1, 1, 1, 1), [0, 255, 0, 255], "clockwise as the front: it is the back, and it is kept");
    assert_eq!(gl.error(), 0);
}

#[test]
fn a_shader_with_no_output_writes_only_depth() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    full_triangle(&gl, 10, "precision mediump float; void main(){}");
    let mut c = C::default();
    c.u(ops::CLEAR_COLOR).f(0.0).f(1.0).f(0.0).f(1.0).u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    c.u(ops::ENABLE).u(DEPTH_TEST);
    gl.send(&c);
    gl.send(&draw3());
    assert_eq!(gl.error(), 0);
    assert_eq!(unsafe { wg_is_lost(gl.h) }, 0);
    assert_eq!(gl.pixels(1, 1, 1, 1), [0, 255, 0, 255]);
}

#[test]
fn viewports_and_offsets_past_all_limits() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    full_triangle(&gl, 10, FS_COLOR);
    let mut c = C::default();
    c.u(ops::VIEWPORT).u(2_000_000_000).u(2_000_000_000).u(1 << 30).u(1 << 30);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    c.u(ops::VIEWPORT).u(-2_000_000_000i32 as u32).u(-2_000_000_000i32 as u32).u(16).u(16);
    c.u(ops::ENABLE).u(POLYGON_OFFSET_FILL).u(ops::POLYGON_OFFSET).f(1e30).f(-1e30);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    c.u(ops::DRAW_ARRAYS).u(1).u(0).u(3).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    assert_eq!(unsafe { wg_is_lost(gl.h) }, 0, "a page's numbers do not lose the context");
}

#[test]
fn out_of_range_draws_are_refused() {
    let Some(gl) = context(attrs(false, 8, 8)) else { return };
    full_triangle(&gl, 10, FS_COLOR);
    let mut c = C::default();
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(4).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), INVALID_OPERATION);
    // an index past the buffer
    let mut c = C::default();
    c.u(ops::BIND_BUFFER).u(ELEMENT_ARRAY_BUFFER).u(2);
    c.u(ops::BUFFER_DATA).u(ELEMENT_ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&[0, 0, 1, 0, 9, 0]);
    c.u(ops::DRAW_ELEMENTS).u(4).u(3).u(formats::UNSIGNED_SHORT).u(0).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), INVALID_OPERATION);
    // past the index buffer
    let mut c = C::default();
    c.u(ops::DRAW_ELEMENTS).u(4).u(30).u(formats::UNSIGNED_SHORT).u(0).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), INVALID_OPERATION);
    // a valid one still draws
    let mut c = C::default();
    c.u(ops::BUFFER_DATA).u(ELEMENT_ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&[0, 0, 1, 0, 2, 0, 0, 0]);
    c.u(ops::DRAW_ELEMENTS).u(4).u(3).u(formats::UNSIGNED_SHORT).u(0).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
}

#[test]
fn textures_start_as_zeros_and_read_what_was_given() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    full_triangle(&gl, 10, "precision mediump float; uniform sampler2D t; void main(){ gl_FragColor = texture2D(t, gl_FragCoord.xy / 4.0) + vec4(0.0, 0.0, 0.0, 1.0); }");
    let tex = |c: &mut C| {
        c.u(ops::BIND_TEXTURE).u(TEXTURE_2D).u(5);
        c.u(ops::TEX_PARAMETER_I).u(TEXTURE_2D).u(TEXTURE_MIN_FILTER).u(NEAREST);
        c.u(ops::TEX_PARAMETER_I).u(TEXTURE_2D).u(TEXTURE_MAG_FILTER).u(NEAREST);
    };
    // no data: zeros
    let mut c = C::default();
    tex(&mut c);
    c.u(ops::TEX_IMAGE).u(TEXTURE_2D).u(0).u(formats::RGBA).u(1).u(1).u(1).u(0).u(formats::RGBA).u(formats::UNSIGNED_BYTE).u(0).u(0).u(0).b(&[]);
    gl.send(&c);
    gl.send(&draw3());
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(0, 0, 1, 1), [0, 0, 0, 255]);
    // data: read
    let mut c = C::default();
    c.u(ops::TEX_IMAGE).u(TEXTURE_2D).u(0).u(formats::RGBA).u(1).u(1).u(1).u(0).u(formats::RGBA).u(formats::UNSIGNED_BYTE).u(1).u(0).u(0).b(&[10, 20, 30, 40]);
    gl.send(&c);
    gl.send(&draw3());
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(0, 0, 1, 1), [10, 20, 30, 255]);
    // too few bytes for the size
    let mut c = C::default();
    c.u(ops::TEX_IMAGE).u(TEXTURE_2D).u(0).u(formats::RGBA).u(4).u(4).u(1).u(0).u(formats::RGBA).u(formats::UNSIGNED_BYTE).u(1).u(0).u(0).b(&[1, 2, 3, 4]);
    gl.send(&c);
    assert_eq!(gl.error(), INVALID_OPERATION);
}

#[test]
fn an_incomplete_texture_reads_black() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    full_triangle(&gl, 10, "precision mediump float; uniform sampler2D t; void main(){ gl_FragColor = texture2D(t, vec2(0.5)); }");
    let mut c = C::default();
    c.u(ops::BIND_TEXTURE).u(TEXTURE_2D).u(5);
    // 3 x 3 with a mipmapping filter: not complete in WebGL 1
    let data = vec![200u8; 36];
    c.u(ops::TEX_IMAGE).u(TEXTURE_2D).u(0).u(formats::RGBA).u(3).u(3).u(1).u(0).u(formats::RGBA).u(formats::UNSIGNED_BYTE).u(1).u(0).u(0).b(&data);
    gl.send(&c);
    gl.send(&draw3());
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(1, 1, 1, 1), [0, 0, 0, 255]);
}

#[test]
fn a_framebuffer_mipmaps_blending_depth_and_scissor() {
    let Some(gl) = context(attrs(true, 8, 8)) else { return };
    full_triangle(&gl, 10, FS_COLOR);
    let loc = gl.uniform_location(10, "c");
    // render to a texture
    let mut c = C::default();
    c.u(ops::BIND_TEXTURE).u(TEXTURE_2D).u(5);
    c.u(ops::TEX_IMAGE).u(TEXTURE_2D).u(0).u(formats::RGBA).u(8).u(8).u(1).u(0).u(formats::RGBA).u(formats::UNSIGNED_BYTE).u(0).u(0).u(0).b(&[]);
    c.u(ops::BIND_FRAMEBUFFER).u(FRAMEBUFFER).u(7);
    c.u(ops::FRAMEBUFFER_TEXTURE).u(FRAMEBUFFER).u(COLOR_ATTACHMENT0).u(TEXTURE_2D).u(5).u(0);
    c.u(ops::UNIFORM).u(loc as u32).u(4).u(1).b(&floats(&[0.0, 1.0, 0.0, 1.0]));
    gl.send(&c);
    gl.send(&draw3());
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(3, 3, 1, 1), [0, 255, 0, 255]);
    // mipmaps of it
    let mut c = C::default();
    c.u(ops::BIND_FRAMEBUFFER).u(FRAMEBUFFER).u(0);
    c.u(ops::GENERATE_MIPMAP).u(TEXTURE_2D);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    // a color write mask and a scissored clear
    let mut c = C::default();
    c.u(ops::CLEAR_COLOR).f(1.0).f(1.0).f(1.0).f(1.0).u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    c.u(ops::ENABLE).u(SCISSOR_TEST).u(ops::SCISSOR).u(0).u(0).u(4).u(8);
    c.u(ops::CLEAR_COLOR).f(0.0).f(0.0).f(0.0).f(1.0).u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    c.u(ops::DISABLE).u(SCISSOR_TEST);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(1, 1, 1, 1), [0, 0, 0, 255]);
    assert_eq!(gl.pixels(6, 1, 1, 1), [255, 255, 255, 255]);
    // depth: the later triangle behind the first does not pass
    let mut c = C::default();
    c.u(ops::ENABLE).u(DEPTH_TEST).u(ops::CLEAR).u(COLOR_BUFFER_BIT | DEPTH_BUFFER_BIT);
    gl.send(&c);
    assert!(gl.program(20, "attribute vec2 p; uniform float z; void main(){ gl_Position = vec4(p, z, 1.0); }", FS_COLOR));
    let (lz, lc) = (gl.uniform_location(20, "z"), gl.uniform_location(20, "c"));
    let mut c = C::default();
    c.u(ops::USE_PROGRAM).u(20);
    c.u(ops::UNIFORM).u(lz as u32).u(1).u(1).b(&floats(&[-0.5]));
    c.u(ops::UNIFORM).u(lc as u32).u(4).u(1).b(&floats(&[1.0, 0.0, 0.0, 1.0]));
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    c.u(ops::UNIFORM).u(lz as u32).u(1).u(1).b(&floats(&[0.5]));
    c.u(ops::UNIFORM).u(lc as u32).u(4).u(1).b(&floats(&[0.0, 0.0, 1.0, 1.0]));
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(4, 4, 1, 1), [255, 0, 0, 255]);
    // blending
    let mut c = C::default();
    c.u(ops::DISABLE).u(DEPTH_TEST);
    c.u(ops::CLEAR_COLOR).f(0.0).f(0.0).f(0.0).f(0.0).u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    c.u(ops::ENABLE).u(BLEND).u(ops::BLEND_FUNC).u(1).u(1).u(1).u(1);
    c.u(ops::UNIFORM).u(lc as u32).u(4).u(1).b(&floats(&[0.25, 0.0, 0.0, 0.25]));
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    let px = gl.pixels(4, 4, 1, 1);
    assert!((px[0] as i32 - 128).abs() <= 2, "{px:?}");
}

#[test]
fn fans_loops_points_and_byte_indices() {
    let Some(gl) = context(attrs(false, 8, 8)) else { return };
    assert!(gl.program(10, "attribute vec2 p; attribute vec4 k; varying vec4 v; void main(){ v = k; gl_Position = vec4(p, 0.0, 1.0); gl_PointSize = 4.0; }", "precision mediump float; varying vec4 v; void main(){ gl_FragColor = v; }"));
    let mut c = C::default();
    c.u(ops::USE_PROGRAM).u(10);
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(1);
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[-1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0]));
    c.u(ops::ENABLE_ATTRIB).u(0);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(0).u(2).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    // a constant attribute: not enabled
    c.u(ops::VERTEX_ATTRIB).u(1).u(0).f(0.0).f(1.0).f(0.0).f(1.0);
    c.u(ops::BIND_ATTRIB_LOCATION).u(10).u(1).s("k");
    c.u(ops::LINK_PROGRAM).u(10);
    c.u(ops::USE_PROGRAM).u(10);
    // a fan
    c.u(ops::DRAW_ARRAYS).u(6).u(0).u(4).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(4, 4, 1, 1), [0, 255, 0, 255]);
    // byte indices
    let mut c = C::default();
    c.u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    c.u(ops::BIND_BUFFER).u(ELEMENT_ARRAY_BUFFER).u(2);
    c.u(ops::BUFFER_DATA).u(ELEMENT_ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&[0, 1, 2, 0, 2, 3]);
    c.u(ops::DRAW_ELEMENTS).u(4).u(6).u(formats::UNSIGNED_BYTE).u(0).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(4, 4, 1, 1), [0, 255, 0, 255]);
    // a point at the centre
    let mut c = C::default();
    c.u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[0.0, 0.0]));
    c.u(ops::DRAW_ARRAYS).u(0).u(0).u(1).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(4, 4, 1, 1), [0, 255, 0, 255]);
    assert_eq!(gl.pixels(0, 0, 1, 1), [0, 0, 0, 0]);
}

#[test]
fn stride_formats_wgpu_does_not_have_are_converted() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    assert!(gl.program(10, "attribute vec2 p; attribute vec3 k; varying vec3 v; void main(){ v = k; gl_Position = vec4(p, 0.0, 1.0); }", "precision mediump float; varying vec3 v; void main(){ gl_FragColor = vec4(v, 1.0); }"));
    let mut c = C::default();
    c.u(ops::BIND_ATTRIB_LOCATION).u(10).u(0).s("p");
    c.u(ops::BIND_ATTRIB_LOCATION).u(10).u(1).s("k");
    c.u(ops::LINK_PROGRAM).u(10);
    c.u(ops::USE_PROGRAM).u(10);
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(1);
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[-1.0, -1.0, 3.0, -1.0, -1.0, 3.0]));
    c.u(ops::ENABLE_ATTRIB).u(0);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(0).u(2).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    // three normalized bytes, tightly packed: no such format, and a stride of 3
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(2);
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&[255, 0, 0, 255, 0, 0, 255, 0, 0]);
    c.u(ops::ENABLE_ATTRIB).u(1);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(1).u(3).u(formats::UNSIGNED_BYTE).u(1).u(0).u(0).u(0);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(1, 1, 1, 1), [255, 0, 0, 255]);
}

#[test]
fn a_write_between_draws_reaches_only_later_draws() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    assert!(gl.program(10, "attribute vec2 p; attribute float k; varying float v; void main(){ v = k; gl_Position = vec4(p, 0.0, 1.0); }", "precision mediump float; varying float v; void main(){ gl_FragColor = vec4(v, 0.0, 0.0, 1.0); }"));
    let mut c = C::default();
    c.u(ops::BIND_ATTRIB_LOCATION).u(10).u(0).s("p");
    c.u(ops::BIND_ATTRIB_LOCATION).u(10).u(1).s("k");
    c.u(ops::LINK_PROGRAM).u(10);
    c.u(ops::USE_PROGRAM).u(10);
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(1);
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[-1.0, -1.0, 3.0, -1.0, -1.0, 3.0]));
    c.u(ops::ENABLE_ATTRIB).u(0);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(0).u(2).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(2);
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E8).u(0).u(1).b(&floats(&[1.0, 1.0, 1.0]));
    c.u(ops::ENABLE_ATTRIB).u(1);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(1).u(1).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    // draw on half, change the buffer, draw on the other half
    c.u(ops::ENABLE).u(SCISSOR_TEST).u(ops::SCISSOR).u(0).u(0).u(2).u(4);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    c.u(ops::BUFFER_SUB_DATA).u(ARRAY_BUFFER).u(0).b(&floats(&[0.5, 0.5, 0.5]));
    c.u(ops::SCISSOR).u(2).u(0).u(2).u(4);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(1);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(0, 0, 1, 1)[0], 255);
    let v = gl.pixels(3, 0, 1, 1)[0] as i32;
    assert!((v - 128).abs() <= 2, "{v}");
}

#[test]
fn a_frame_reaches_the_bitmap_with_its_top_row_first() {
    let Some(gl) = context(attrs(false, 2, 2)) else { return };
    let mut c = C::default();
    c.u(ops::ENABLE).u(SCISSOR_TEST).u(ops::SCISSOR).u(0).u(0).u(2).u(1);
    c.u(ops::CLEAR_COLOR).f(1.0).f(0.0).f(0.0).f(1.0).u(ops::CLEAR).u(COLOR_BUFFER_BIT);
    gl.send(&c);
    unsafe { wg_present(gl.h) };
    let mut px = [0u8; 16];
    let t0 = Instant::now();
    loop {
        if unsafe { wg_take_frame(gl.h, px.as_mut_ptr(), 2, 2, 8) } != FRAME_NONE {
            break;
        }
        assert!(t0.elapsed() < Duration::from_secs(30));
        std::thread::sleep(Duration::from_millis(1));
    }
    // GL's y = 0 is the bottom: the red row is the last of the bitmap
    assert_eq!(&px[..4], [0, 0, 0, 0]);
    assert_eq!(&px[8..12], [255, 0, 0, 255]);
    // the buffer is new for the next frame, as preserveDrawingBuffer: false says
    assert_eq!(gl.pixels(0, 0, 1, 1), [0, 0, 0, 0]);
    assert_eq!(unsafe { wg_take_frame(gl.h, px.as_mut_ptr(), 2, 2, 8) }, 0);
}

#[test]
fn es3_blocks_instancing_and_a_3d_texture() {
    let Some(gl) = context(attrs(true, 4, 4)) else { return };
    let vs = "#version 300 es\nin vec2 p; in vec2 off; layout(std140) uniform B { vec4 tint; }; out vec4 v; void main(){ v = tint; gl_Position = vec4(p + off, 0.0, 1.0); }";
    let fs = "#version 300 es\nprecision highp float; precision highp sampler3D; in vec4 v; out vec4 color; uniform sampler3D t; void main(){ color = v + texture(t, vec3(0.5)); }";
    assert!(gl.program(10, vs, fs));
    let mut c = C::default();
    c.u(ops::USE_PROGRAM).u(10);
    c.u(ops::BIND_VAO).u(3);
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(1);
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[-1.0, -1.0, 3.0, -1.0, -1.0, 3.0]));
    c.u(ops::ENABLE_ATTRIB).u(0);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(0).u(2).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    c.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(2);
    c.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[0.0, 0.0, 10.0, 10.0]));
    c.u(ops::ENABLE_ATTRIB).u(1);
    c.u(ops::VERTEX_ATTRIB_POINTER).u(1).u(2).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    c.u(ops::VERTEX_ATTRIB_DIVISOR).u(1).u(1);
    c.u(ops::BIND_BUFFER).u(UNIFORM_BUFFER).u(4);
    c.u(ops::BUFFER_DATA).u(UNIFORM_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[0.0, 1.0, 0.0, 1.0]));
    c.u(ops::BIND_BUFFER_RANGE).u(UNIFORM_BUFFER).u(0).u(4).u(0).u(u32::MAX);
    c.u(ops::BIND_TEXTURE).u(TEXTURE_3D).u(5);
    c.u(ops::TEX_PARAMETER_I).u(TEXTURE_3D).u(TEXTURE_MIN_FILTER).u(NEAREST);
    c.u(ops::TEX_IMAGE).u(TEXTURE_3D).u(0).u(formats::RGBA).u(1).u(1).u(1).u(0).u(formats::RGBA).u(formats::UNSIGNED_BYTE).u(1).u(1).u(0).b(&[255, 0, 0, 0]);
    c.u(ops::DRAW_ARRAYS).u(4).u(0).u(3).u(2);
    gl.send(&c);
    assert_eq!(gl.error(), 0);
    assert_eq!(gl.pixels(1, 1, 1, 1), [255, 255, 0, 255]);
}

#[test]
fn a_bad_stream_loses_the_context_and_the_browser_goes_on() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    let mut c = C::default();
    c.u(99999);
    gl.send(&c);
    let t0 = Instant::now();
    while unsafe { wg_is_lost(gl.h) } == 0 {
        assert!(t0.elapsed() < Duration::from_secs(30));
        std::thread::sleep(Duration::from_millis(1));
    }
    let mut q = C::default();
    q.u(ops::Q_ERROR);
    let mut out = [0u8; 16];
    assert_eq!(unsafe { wg_query(gl.h, q.d.as_ptr(), q.d.len(), out.as_mut_ptr(), 16) }, -1);
    // what comes next does nothing, and a new device gives a working context
    assert_eq!(unsafe { wg_restore(gl.h) }, 1);
    assert_eq!(gl.error(), 0);
}

#[test]
fn a_hostile_shader_is_an_error_in_the_log() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    let deep = format!("void main(){{ gl_Position = vec4({}0.0{}); }}", "(".repeat(50_000), ")".repeat(50_000));
    assert!(!gl.program(10, &deep, FS_COLOR));
    // the deepest nesting and the longest statement the translator lets through must not overflow anything behind it, on this
    // thread's stack: compiling them may fail, the context lives
    let deepest = format!("void main(){{ gl_Position = vec4({}1.0{}); }}", "(".repeat(translate::MAX_NESTING - 8), ")".repeat(translate::MAX_NESTING - 8));
    let _ = gl.program(20, &deepest, FS_COLOR);
    let longest = format!("uniform float a; void main(){{ gl_Position = vec4(a{}); }}", "+a".repeat(translate::MAX_STATEMENT_OPERATORS - 16));
    let _ = gl.program(30, &longest, FS_COLOR);
    let unary = format!("uniform float a; void main(){{ gl_Position = vec4({}a); }}", "- ".repeat(translate::MAX_STATEMENT_OPERATORS - 16));
    let _ = gl.program(50, &unary, FS_COLOR);
    let members = format!("uniform vec4 a; void main(){{ gl_Position = a{}; }}", ".xyzw".repeat(translate::MAX_STATEMENT_OPERATORS - 16));
    let _ = gl.program(60, &members, FS_COLOR);
    let ifs = format!("uniform float a; void main(){{ {}gl_Position = vec4(a); }}", "if (a > 0.0) ".repeat(translate::MAX_CONTROL_CHAIN / 2));
    let _ = gl.program(70, &ifs, FS_COLOR);
    let elses = format!("uniform float a; void main(){{ if (a > 0.0) gl_Position = vec4(a); {} }}", "else if (a > 1.0) gl_Position = vec4(a); ".repeat(translate::MAX_ELSES - 16));
    let _ = gl.program(80, &elses, FS_COLOR);
    let flat = format!("const float x[{}] = float[]({}); void main(){{ gl_Position = vec4(x[0]); }}", translate::MAX_STATEMENT_TOKENS / 3, vec!["1.0"; translate::MAX_STATEMENT_TOKENS / 3].join(","));
    let _ = gl.program(90, &flat, FS_COLOR);
    let nested_calls = format!("void main(){{ gl_Position = vec4({}1.0{}); }}", "abs(".repeat(translate::MAX_NESTING - 8), ")".repeat(translate::MAX_NESTING - 8));
    let _ = gl.program(40, &nested_calls, FS_COLOR);
    assert_eq!(unsafe { wg_is_lost(gl.h) }, 0, "the context lives");
    assert_eq!(gl.error(), 0);
}

#[test]
fn shader_precision_and_es1_samples() {
    let Some(gl) = context(attrs(false, 4, 4)) else { return };
    // shaders in the style of the old samples: const arrays, struct uniforms, functions on samplers
    let vs = "attribute vec4 a; uniform struct L { vec3 c; float k; } l[2]; varying vec3 v; void main(){ v = l[1].c * l[0].k; gl_Position = a; }";
    let fs = "precision mediump float; varying vec3 v; const int N = 3; uniform vec4 m[N]; uniform mat3 r; uniform mat2 q; uniform bvec2 b; void main(){ vec3 x = r * v; vec2 y = q * x.xy; gl_FragColor = vec4(y, b.x ? m[2].x : m[1].y, 1.0); }";
    assert!(gl.program(10, vs, fs));
    let (a, b, c, d, e) = (gl.uniform_location(10, "l[1].c"), gl.uniform_location(10, "m[2]"), gl.uniform_location(10, "q"), gl.uniform_location(10, "b"), gl.uniform_location(10, "zzz"));
    assert!(a >= 0 && b >= 0 && c >= 0 && d >= 0);
    assert_eq!(e, -1);
    let mut cmd = C::default();
    cmd.u(ops::USE_PROGRAM).u(10);
    cmd.u(ops::UNIFORM).u(gl.uniform_location(10, "l[0].k") as u32).u(1).u(1).b(&floats(&[1.0]));
    cmd.u(ops::UNIFORM).u(a as u32).u(3).u(1).b(&floats(&[1.0, 0.0, 0.0]));
    cmd.u(ops::UNIFORM).u(gl.uniform_location(10, "r") as u32).u(0x100 | 0x33).u(1).b(&floats(&[1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]));
    cmd.u(ops::UNIFORM).u(c as u32).u(0x100 | 0x22).u(1).b(&floats(&[0.0, 1.0, 1.0, 0.0]));
    // a uniform of the wrong kind
    cmd.u(ops::UNIFORM).u(b as u32).u(1).u(1).b(&floats(&[1.0]));
    gl.send(&cmd);
    assert_eq!(gl.error(), INVALID_OPERATION);
    let mut cmd = C::default();
    cmd.u(ops::UNIFORM).u(b as u32).u(4).u(1).b(&floats(&[0.75, 0.0, 0.0, 0.0]));
    cmd.u(ops::UNIFORM).u(d as u32).u(0x10 | 2).u(1).b(&[1, 0, 0, 0, 0, 0, 0, 0]);
    cmd.u(ops::BIND_BUFFER).u(ARRAY_BUFFER).u(1);
    cmd.u(ops::BUFFER_DATA).u(ARRAY_BUFFER).u(0x88E4).u(0).u(1).b(&floats(&[-1.0, -1.0, 0.0, 1.0, 3.0, -1.0, 0.0, 1.0, -1.0, 3.0, 0.0, 1.0]));
    cmd.u(ops::ENABLE_ATTRIB).u(0);
    cmd.u(ops::VERTEX_ATTRIB_POINTER).u(0).u(4).u(formats::FLOAT).u(0).u(0).u(0).u(0);
    gl.send(&cmd);
    gl.send(&draw3());
    assert_eq!(gl.error(), 0);
    let px = gl.pixels(1, 1, 1, 1);
    assert_eq!(px[0], 0); // y = q * (1,0) with q = [0 1; 1 0] column first: (0, 1)
    assert_eq!(px[1], 255);
    assert!((px[2] as i32 - 191).abs() <= 2, "{px:?}");
}
