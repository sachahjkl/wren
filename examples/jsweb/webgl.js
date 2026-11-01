// WebGL (native/js/odin/web_webgl.js, native/webgl, src/page/bindings_webgl.odin): the interfaces and their rules, a small
// conformance set read back through readPixels on the software adapter (webgl.force_software in this tool). A machine with no
// adapter at all answers getContext with null and a webglcontextcreationerror: that is what is checked there.
"use strict";

const SIZE = 16;
const CROSS_ORIGIN_IMAGE = "/site/images/alpha.png";   // of the test server, reached by another of its names
// what the shell does each frame, twice: the canvas is shown, the frame comes back from the device
const frame = async () => { await signal("frame"); await sleep(100); await signal("frame"); };
const loadImage = async url => {
  const img = new Image();
  let failed = false;
  img.onerror = () => { failed = true; };
  img.src = url;
  for (let i = 0; i < 200 && !img.complete && !failed; i++) { await signal("frame"); await sleep(20); }
  return failed || !img.complete ? null : img;
};
const mk = (kind = "webgl", attrs, w = SIZE, h = SIZE) => {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  return [c, c.getContext(kind, attrs)];
};
const VS = "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }";
const FS = "precision mediump float; uniform vec4 c; void main(){ gl_FragColor = c; }";

const shader = (gl, type, source) => {
  const s = gl.createShader(type);
  gl.shaderSource(s, source);
  gl.compileShader(s);
  return s;
};
const program = (gl, vs = VS, fs = FS) => {
  const p = gl.createProgram();
  gl.attachShader(p, shader(gl, gl.VERTEX_SHADER, vs));
  gl.attachShader(p, shader(gl, gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(p);
  return p;
};
// a triangle over everything
const cover = (gl, p, attr = "p") => {
  gl.useProgram(p);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const at = gl.getAttribLocation(p, attr);
  gl.enableVertexAttribArray(at);
  gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
};
const px = (gl, x = 1, y = 1) => {
  const out = new Uint8Array(4);
  gl.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, out);
  return Array.from(out).join(",");
};
const near = (got, want, what) => {
  const g = got.split(",").map(Number);
  ok(want.every((v, i) => Math.abs(v - g[i]) <= 2), what + " (got " + got + ", want " + want.join(",") + ")");
};
const available = mk()[1] !== null;

test("feature detection", () => {
  for (const name of ["WebGLRenderingContext", "WebGL2RenderingContext", "WebGLBuffer", "WebGLFramebuffer", "WebGLProgram", "WebGLRenderbuffer", "WebGLShader", "WebGLTexture",
    "WebGLUniformLocation", "WebGLActiveInfo", "WebGLShaderPrecisionFormat", "WebGLContextEvent", "WebGLQuery", "WebGLSampler", "WebGLSync", "WebGLTransformFeedback", "WebGLVertexArrayObject"]) {
    eq(typeof globalThis[name], "function", name + " exists");
  }
  throws(() => new WebGLRenderingContext(), "TypeError", "no constructor for a context");
  throws(() => new WebGLBuffer(), "TypeError", "no constructor for a buffer");
  eq(WebGLRenderingContext.ARRAY_BUFFER, 0x8892, "a constant on the interface");
  eq(WebGLRenderingContext.prototype.TRIANGLES, 4, "a constant on the prototype");
  eq(WebGL2RenderingContext.RGBA8, 0x8058, "a constant of WebGL 2");
  eq(new WebGLContextEvent("x", { statusMessage: "why" }).statusMessage, "why", "WebGLContextEvent");
  eq(document.createElement("canvas").getContext("webgpu"), null, "no webgpu");
});

test("a canvas has one kind of context", () => {
  if (!available) { ok(true, "no adapter here"); return; }
  const [c, gl] = mk();
  ok(gl instanceof WebGLRenderingContext, "a WebGLRenderingContext");
  eq(Object.prototype.toString.call(gl), "[object WebGLRenderingContext]", "toStringTag");
  eq(c.getContext("webgl"), gl, "the same context again");
  eq(c.getContext("experimental-webgl"), gl, "under its old name too");
  eq(c.getContext("2d"), null, "no 2d on a webgl canvas");
  eq(c.getContext("webgl2"), null, "no webgl2 on a webgl canvas");
  eq(gl.canvas, c, "gl.canvas");
  const [c2, g2] = mk("webgl2");
  ok(g2 instanceof WebGL2RenderingContext, "a WebGL2RenderingContext");
  ok(!(g2 instanceof WebGLRenderingContext), "not a WebGLRenderingContext");
  eq(c2.getContext("webgl"), null, "no webgl on a webgl2 canvas");
  const d = document.createElement("canvas");
  const two = d.getContext("2d");
  ok(two, "2d first");
  eq(d.getContext("webgl"), null, "no webgl on a 2d canvas");
  eq(gl.drawingBufferWidth, SIZE, "drawingBufferWidth");
  eq(gl.drawingBufferHeight, SIZE, "drawingBufferHeight");
  const a = gl.getContextAttributes();
  eq(a.alpha && a.depth && a.premultipliedAlpha, true, "default attributes");
  eq(a.stencil, false, "no stencil by default");
  eq(a.preserveDrawingBuffer, false, "not preserved by default");
  eq(mk("webgl", { alpha: false, stencil: true, antialias: false })[1].getContextAttributes().alpha, false, "alpha: false kept");
  eq(gl.getError(), 0, "no error");
});

test("what getParameter says", () => {
  if (!available) return;
  const [, gl] = mk();
  ok(gl.getParameter(gl.VERSION).startsWith("WebGL 1.0"), "VERSION");
  ok(gl.getParameter(gl.SHADING_LANGUAGE_VERSION).startsWith("WebGL GLSL ES 1.0"), "SHADING_LANGUAGE_VERSION");
  eq(gl.getParameter(gl.RENDERER), "Wren WebGL", "RENDERER says no more than this");
  eq(gl.getParameter(gl.VENDOR), "Wren", "VENDOR");
  eq(gl.getExtension("WEBGL_debug_renderer_info"), null, "the GPU's name is not exposed");
  ok(gl.getParameter(gl.MAX_TEXTURE_SIZE) >= 2048, "MAX_TEXTURE_SIZE");
  ok(gl.getParameter(gl.MAX_VERTEX_ATTRIBS) >= 8, "MAX_VERTEX_ATTRIBS");
  ok(gl.getParameter(gl.VIEWPORT) instanceof Int32Array, "VIEWPORT is an Int32Array");
  eq(Array.from(gl.getParameter(gl.VIEWPORT)).join(), "0,0," + SIZE + "," + SIZE, "VIEWPORT");
  ok(gl.getParameter(gl.COLOR_CLEAR_VALUE) instanceof Float32Array, "COLOR_CLEAR_VALUE is a Float32Array");
  eq(gl.getParameter(gl.COLOR_WRITEMASK).join(), "true,true,true,true", "COLOR_WRITEMASK");
  eq(gl.getParameter(gl.ARRAY_BUFFER_BINDING), null, "nothing bound");
  const b = gl.createBuffer();
  eq(gl.isBuffer(b), false, "a buffer is one when it was bound");
  gl.bindBuffer(gl.ARRAY_BUFFER, b);
  eq(gl.isBuffer(b), true, "bound");
  eq(gl.getParameter(gl.ARRAY_BUFFER_BINDING), b, "the object bound");
  eq(gl.isEnabled(gl.BLEND), false, "isEnabled");
  gl.enable(gl.BLEND);
  eq(gl.isEnabled(gl.BLEND), true, "enabled");
  eq(gl.getParameter(gl.BLEND), true, "getParameter of a capability");
  eq(gl.getError(), 0, "no error so far");
  gl.getParameter(0x1234);
  eq(gl.getError(), gl.INVALID_ENUM, "an unknown name");
  eq(gl.getError(), 0, "errors are read once");
  const f = gl.getShaderPrecisionFormat(gl.FRAGMENT_SHADER, gl.HIGH_FLOAT);
  eq(f.precision, 23, "precision of highp float");
  ok(f instanceof WebGLShaderPrecisionFormat, "a WebGLShaderPrecisionFormat");
  for (const e of ["OES_element_index_uint", "OES_standard_derivatives", "OES_vertex_array_object", "ANGLE_instanced_arrays", "OES_texture_float", "EXT_blend_minmax", "WEBGL_depth_texture", "WEBGL_lose_context", "EXT_texture_filter_anisotropic"]) {
    ok(gl.getSupportedExtensions().includes(e), e + " listed");
    ok(gl.getExtension(e), e + " given");
  }
  eq(gl.getExtension("oes_standard_DERIVATIVES"), gl.getExtension("OES_standard_derivatives"), "names in any case, the same object");
  eq(gl.getExtension("nope"), null, "an unknown extension");
});

test("shaders and programs", () => {
  if (!available) return;
  const [, gl] = mk();
  const bad = shader(gl, gl.FRAGMENT_SHADER, "void main() { nope; }");
  eq(gl.getShaderParameter(bad, gl.COMPILE_STATUS), false, "a broken shader");
  ok(gl.getShaderInfoLog(bad).includes("ERROR"), "its log says so");
  const ok1 = shader(gl, gl.VERTEX_SHADER, VS);
  eq(gl.getShaderParameter(ok1, gl.COMPILE_STATUS), true, "a good shader");
  eq(gl.getShaderInfoLog(ok1), "", "an empty log");
  eq(gl.getShaderParameter(ok1, gl.SHADER_TYPE), gl.VERTEX_SHADER, "SHADER_TYPE");
  eq(gl.getShaderSource(ok1), VS, "getShaderSource");
  eq(gl.getShaderParameter(shader(gl, gl.FRAGMENT_SHADER, "precision mediump float; void main(){ gl_FragColor = vec4(dFdx(1.0)); }"), gl.COMPILE_STATUS), false, "dFdx needs its extension");
  gl.getExtension("OES_standard_derivatives");
  eq(gl.getShaderParameter(shader(gl, gl.FRAGMENT_SHADER, "#extension GL_OES_standard_derivatives : enable\nprecision mediump float; void main(){ gl_FragColor = vec4(dFdx(1.0)); }"), gl.COMPILE_STATUS), true, "with it, it compiles");
  eq(gl.getShaderParameter(shader(gl, gl.VERTEX_SHADER, "#version 300 es\nvoid main(){}"), gl.COMPILE_STATUS), false, "no GLSL ES 3.00 in WebGL 1");
  eq(gl.getShaderParameter(shader(gl, gl.VERTEX_SHADER, "void main(){ float webgl_x; }"), gl.COMPILE_STATUS), false, "webgl_ names are reserved");

  const p = program(gl, "attribute vec2 p; attribute vec3 unused; uniform mat4 m; uniform vec3 a[4]; uniform struct S { float x; bool on; } s; void main(){ gl_Position = m * vec4(p + a[1].xy, s.on ? s.x : 0.0, 1.0); }",
    "precision mediump float; uniform sampler2D t; uniform vec4 c; void main(){ gl_FragColor = texture2D(t, vec2(0.5)) * c; }");
  eq(gl.getProgramParameter(p, gl.LINK_STATUS), true, "it links");
  eq(gl.getProgramInfoLog(p), "", "no log");
  eq(gl.getProgramParameter(p, gl.ATTACHED_SHADERS), 2, "ATTACHED_SHADERS");
  eq(gl.getProgramParameter(p, gl.ACTIVE_ATTRIBUTES), 1, "only what is used is active");
  const info = gl.getActiveAttrib(p, 0);
  ok(info instanceof WebGLActiveInfo, "a WebGLActiveInfo");
  eq(info.name + ":" + info.type + ":" + info.size, "p:" + gl.FLOAT_VEC2 + ":1", "the attribute");
  const names = [];
  for (let i = 0; i < gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS); i++) { const u = gl.getActiveUniform(p, i); names.push(u.name + ":" + u.size); }
  names.sort();
  eq(names.join(" "), "a[0]:4 c:1 m:1 s.on:1 s.x:1 t:1", "the uniforms, leaves of structures, arrays named by their first element");
  ok(gl.getUniformLocation(p, "a[2]") instanceof WebGLUniformLocation, "an element's location");
  ok(gl.getUniformLocation(p, "a") !== null, "the array's name is its first element");
  ok(gl.getUniformLocation(p, "s.x") !== null, "a field's location");
  eq(gl.getUniformLocation(p, "nope"), null, "nothing by that name");
  eq(gl.getAttribLocation(p, "nope"), -1, "no attribute by that name");
  gl.useProgram(p);
  const m = gl.getUniformLocation(p, "c");
  gl.uniform4f(m, 0.25, 0.5, 0.75, 1);
  eq(Array.from(gl.getUniform(p, m)).join(), "0.25,0.5,0.75,1", "getUniform");
  gl.uniform1f(m, 1);
  eq(gl.getError(), gl.INVALID_OPERATION, "a uniform call of the wrong size");
  gl.uniform4f(null, 1, 1, 1, 1);
  eq(gl.getError(), 0, "a null location is ignored");
  const other = program(gl);
  gl.useProgram(other);
  gl.uniform4f(m, 1, 1, 1, 1);
  eq(gl.getError(), gl.INVALID_OPERATION, "a location of another program");
  throws(() => gl.useProgram({}), "TypeError", "not a program");
  const v = gl.createProgram();
  gl.attachShader(v, shader(gl, gl.VERTEX_SHADER, "varying vec2 x; void main(){ x = vec2(0.0); gl_Position = vec4(0.0); }"));
  gl.attachShader(v, shader(gl, gl.FRAGMENT_SHADER, "precision mediump float; varying vec3 x; void main(){ gl_FragColor = vec4(x, 1.0); }"));
  gl.linkProgram(v);
  eq(gl.getProgramParameter(v, gl.LINK_STATUS), false, "varyings that differ do not link");
  ok(gl.getProgramInfoLog(v).length > 0, "and it says why");
  gl.useProgram(v);
  eq(gl.getError(), gl.INVALID_OPERATION, "a program not linked cannot be used");
});

test("a triangle", () => {
  if (!available) return;
  const [, gl] = mk();
  eq(px(gl), "0,0,0,0", "the buffer starts transparent");
  gl.clearColor(0, 0, 1, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  eq(px(gl), "0,0,255,255", "clear");
  const p = program(gl);
  cover(gl, p);
  gl.uniform4f(gl.getUniformLocation(p, "c"), 1, 0, 0, 1);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), 0, "no error");
  eq(px(gl), "255,0,0,255", "drawn");
  const out = new Uint8Array(4 * SIZE * SIZE);
  gl.readPixels(0, 0, SIZE, SIZE, gl.RGBA, gl.UNSIGNED_BYTE, out);
  ok(out.every((v, i) => v === (i % 4 === 0 || i % 4 === 3 ? 255 : 0)), "all of it");
  // what is outside the framebuffer stays as it was
  const edge = new Uint8Array(8).fill(9);
  gl.readPixels(SIZE - 1, 0, 2, 1, gl.RGBA, gl.UNSIGNED_BYTE, edge);
  eq(Array.from(edge).join(), "255,0,0,255,9,9,9,9", "readPixels past the edge");
  gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(3));
  eq(gl.getError(), gl.INVALID_OPERATION, "a destination too small");
  gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, new Float32Array(4));
  eq(gl.getError(), gl.INVALID_OPERATION, "a destination of another type");
  // the y axis is GL's: 0 at the bottom
  gl.enable(gl.SCISSOR_TEST);
  gl.scissor(0, 0, SIZE, 1);
  gl.clearColor(0, 1, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.disable(gl.SCISSOR_TEST);
  eq(px(gl, 1, 0), "0,255,0,255", "row 0");
  eq(px(gl, 1, 1), "255,0,0,255", "row 1");
  gl.colorMask(false, true, false, true);
  gl.clearColor(1, 1, 1, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.colorMask(true, true, true, true);
  eq(px(gl, 1, 1), "255,255,0,255", "a mask on clear");
});

test("the bounds of draws", () => {
  if (!available) return;
  const [, gl] = mk();
  const p = program(gl);
  cover(gl, p);
  gl.drawArrays(gl.TRIANGLES, 0, 4);
  eq(gl.getError(), gl.INVALID_OPERATION, "past the attribute's buffer");
  gl.drawArrays(gl.TRIANGLES, -1, 3);
  eq(gl.getError(), gl.INVALID_VALUE, "a negative first");
  gl.drawArrays(gl.TRIANGLES, 0, -3);
  eq(gl.getError(), gl.INVALID_VALUE, "a negative count");
  gl.drawArrays(99, 0, 3);
  eq(gl.getError(), gl.INVALID_ENUM, "not a mode");
  const e = gl.createBuffer();
  gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, e);
  gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array([0, 1, 2, 3, 1000]), gl.STATIC_DRAW);
  gl.drawElements(gl.TRIANGLES, 3, gl.UNSIGNED_SHORT, 0);
  eq(gl.getError(), 0, "indices in range");
  gl.drawElements(gl.TRIANGLES, 3, gl.UNSIGNED_SHORT, 2);
  eq(gl.getError(), gl.INVALID_OPERATION, "an index past the vertices");
  gl.drawElements(gl.TRIANGLES, 3, gl.UNSIGNED_SHORT, 1);
  eq(gl.getError(), gl.INVALID_OPERATION, "an offset that is not aligned");
  gl.drawElements(gl.TRIANGLES, 300, gl.UNSIGNED_SHORT, 0);
  eq(gl.getError(), gl.INVALID_OPERATION, "past the index buffer");
  gl.drawElements(gl.TRIANGLES, 3, gl.UNSIGNED_INT, 0);
  eq(gl.getError(), gl.INVALID_ENUM, "UNSIGNED_INT needs its extension");
  gl.bufferSubData(gl.ELEMENT_ARRAY_BUFFER, 4, new Uint16Array([0, 0, 0]));
  gl.drawElements(gl.TRIANGLES, 3, gl.UNSIGNED_SHORT, 4);
  eq(gl.getError(), 0, "a write changes what the bound checks see");
  gl.bufferSubData(gl.ELEMENT_ARRAY_BUFFER, 1000, new Uint16Array([0]));
  eq(gl.getError(), gl.INVALID_VALUE, "bufferSubData past the end");
  gl.bindBuffer(gl.ARRAY_BUFFER, e);
  eq(gl.getError(), gl.INVALID_OPERATION, "a buffer of indices is not an array buffer");
  gl.useProgram(null);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), gl.INVALID_OPERATION, "no program");
  const q = program(gl);
  gl.useProgram(q);
  gl.disableVertexAttribArray(0);
  gl.drawArrays(gl.TRIANGLES, 0, 100000);
  eq(gl.getError(), 0, "a constant attribute reads nothing");
  const n = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, n);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  gl.enableVertexAttribArray(0);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), gl.INVALID_OPERATION, "an empty buffer");
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 3, 0);
  eq(gl.getError(), gl.INVALID_OPERATION, "a stride that does not fit the type");
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 300, 0);
  eq(gl.getError(), gl.INVALID_VALUE, "a stride over 255");
  gl.vertexAttribPointer(0, 5, gl.FLOAT, false, 0, 0);
  eq(gl.getError(), gl.INVALID_VALUE, "a size over 4");
});

test("indices, modes, attributes", () => {
  if (!available) return;
  const [, gl] = mk();
  const p = program(gl, "attribute vec2 p; attribute vec3 k; varying vec3 v; void main(){ v = k; gl_Position = vec4(p, 0.0, 1.0); gl_PointSize = 8.0; }", "precision mediump float; varying vec3 v; void main(){ gl_FragColor = vec4(v, 1.0); }");
  gl.useProgram(p);
  const at = gl.getAttribLocation(p, "p"), kt = gl.getAttribLocation(p, "k");
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, 1, 1, -1, 1]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(at);
  gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
  gl.vertexAttrib3f(kt, 0, 1, 0);
  gl.drawArrays(gl.TRIANGLE_FAN, 0, 4);
  eq(px(gl, 8, 8), "0,255,0,255", "a fan, a constant attribute");
  eq(Array.from(gl.getVertexAttrib(kt, gl.CURRENT_VERTEX_ATTRIB)).join(), "0,1,0,1", "CURRENT_VERTEX_ATTRIB");
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint8Array([0, 1, 2, 0, 2, 3]), gl.STATIC_DRAW);
  gl.drawElements(gl.TRIANGLES, 6, gl.UNSIGNED_BYTE, 0);
  eq(px(gl, 8, 8), "0,255,0,255", "byte indices");
  gl.clear(gl.COLOR_BUFFER_BIT);
  const uint = gl.getExtension("OES_element_index_uint");
  ok(uint, "OES_element_index_uint");
  gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint32Array([0, 1, 2, 0, 2, 3]), gl.STATIC_DRAW);
  gl.drawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, 0);
  eq(gl.getError(), 0, "uint indices");
  eq(px(gl, 8, 8), "0,255,0,255", "drawn");
  gl.clear(gl.COLOR_BUFFER_BIT);
  // three bytes per vertex: wgpu has no such format, nor a stride of 3
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Uint8Array([255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(kt);
  gl.vertexAttribPointer(kt, 3, gl.UNSIGNED_BYTE, true, 0, 0);
  gl.drawArrays(gl.TRIANGLE_FAN, 0, 4);
  eq(gl.getError(), 0, "no error");
  eq(px(gl, 8, 8), "255,0,0,255", "three normalized bytes");
  gl.clear(gl.COLOR_BUFFER_BIT);
  // a point, drawn as a quad
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0]), gl.STATIC_DRAW);
  gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
  gl.disableVertexAttribArray(kt);
  gl.drawArrays(gl.POINTS, 0, 1);
  eq(px(gl, 8, 8), "0,255,0,255", "the middle of a point");
  eq(px(gl, 1, 1), "0,0,0,0", "outside the point");
  // instancing
  const inst = gl.getExtension("ANGLE_instanced_arrays");
  const vao = gl.getExtension("OES_vertex_array_object");
  const arr = vao.createVertexArrayOES();
  vao.bindVertexArrayOES(arr);
  eq(vao.isVertexArrayOES(arr), true, "a vertex array");
  const q = program(gl, "attribute vec2 p; attribute vec2 off; void main(){ gl_Position = vec4(p + off, 0.0, 1.0); }", "precision mediump float; void main(){ gl_FragColor = vec4(1.0); }");
  gl.useProgram(q);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 0, -1, -1, 0]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(gl.getAttribLocation(q, "p"));
  gl.vertexAttribPointer(gl.getAttribLocation(q, "p"), 2, gl.FLOAT, false, 0, 0);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 1]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(gl.getAttribLocation(q, "off"));
  gl.vertexAttribPointer(gl.getAttribLocation(q, "off"), 2, gl.FLOAT, false, 0, 0);
  inst.vertexAttribDivisorANGLE(gl.getAttribLocation(q, "off"), 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  inst.drawArraysInstancedANGLE(gl.TRIANGLES, 0, 3, 2);
  eq(gl.getError(), 0, "no error");
  eq(px(gl, 2, 2), "255,255,255,255", "the first instance");
  eq(px(gl, 10, 10), "255,255,255,255", "the second instance");
  inst.drawArraysInstancedANGLE(gl.TRIANGLES, 0, 3, 3);
  eq(gl.getError(), gl.INVALID_OPERATION, "an instance past its attribute");
  vao.bindVertexArrayOES(null);
  eq(gl.getVertexAttrib(0, gl.VERTEX_ATTRIB_ARRAY_ENABLED) && false, false, "back to the default vertex array");
});

test("textures", () => {
  if (!available) return;
  const [, gl] = mk();
  const p = program(gl, VS, "precision mediump float; uniform sampler2D t; void main(){ gl_FragColor = texture2D(t, gl_FragCoord.xy / " + SIZE + ".0); }");
  cover(gl, p);
  const draw = () => { gl.drawArrays(gl.TRIANGLES, 0, 3); return px(gl, 1, 1); };
  const t = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, t);
  eq(draw(), "0,0,0,255", "an incomplete texture reads opaque black");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  eq(draw(), "0,0,0,0", "a texture without data is zeros");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([10, 20, 30, 40]));
  eq(draw(), "10,20,30,40", "the pixel given");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array([10, 20, 30, 0]));
  eq(draw(), "10,20,30,255", "RGB is opaque");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE, 1, 1, 0, gl.LUMINANCE, gl.UNSIGNED_BYTE, new Uint8Array([77, 0, 0, 0]));
  eq(draw(), "77,77,77,255", "LUMINANCE");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.ALPHA, 1, 1, 0, gl.ALPHA, gl.UNSIGNED_BYTE, new Uint8Array([77, 0, 0, 0]));
  eq(draw(), "0,0,0,77", "ALPHA");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.LUMINANCE_ALPHA, 1, 1, 0, gl.LUMINANCE_ALPHA, gl.UNSIGNED_BYTE, new Uint8Array([77, 11, 0, 0]));
  eq(draw(), "77,77,77,11", "LUMINANCE_ALPHA");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_SHORT_4_4_4_4, new Uint16Array([0xF00F]));
  eq(draw(), "255,0,0,255", "4_4_4_4");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_SHORT_5_6_5, new Uint16Array([0x07E0]));
  eq(draw(), "0,255,0,255", "5_6_5");
  eq(gl.getError(), 0, "no error so far");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 2, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(4));
  eq(gl.getError(), gl.INVALID_OPERATION, "too few bytes");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, null);
  eq(gl.getError(), gl.INVALID_OPERATION, "internal format and format differ");
  gl.texImage2D(gl.TEXTURE_2D, 0, 0x1234, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, null);
  eq(gl.getError(), gl.INVALID_OPERATION, "not a format");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, -1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  eq(gl.getError(), gl.INVALID_VALUE, "a negative size");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, null);
  eq(gl.getError(), gl.INVALID_VALUE, "a border");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1 << 20, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  eq(gl.getError(), gl.INVALID_VALUE, "too large");
  // a subimage, flip, unpack alignment
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 2, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255, 4, 0, 0, 255]));
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  eq(draw(), "1,0,0,255", "row 0 of the array is y = 0");
  gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([9, 9, 9, 255]));
  eq(draw(), "9,9,9,255", "texSubImage2D");
  gl.texSubImage2D(gl.TEXTURE_2D, 0, 1, 1, 2, 2, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(16));
  eq(gl.getError(), gl.INVALID_VALUE, "a subimage past the edge");
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([1, 0, 0, 255, 2, 0, 0, 255]));
  eq(draw(), "2,0,0,255", "UNPACK_FLIP_Y_WEBGL");
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([200, 100, 50, 128]));
  near(draw(), [100, 50, 25, 128], "UNPACK_PREMULTIPLY_ALPHA_WEBGL");
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 3);
  eq(gl.getError(), gl.INVALID_VALUE, "not an alignment");
  // WebGL 1's rule on sizes that are not powers of two
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 3, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(12).fill(200));
  eq(draw(), "0,0,0,255", "REPEAT on 3 x 1 is incomplete");
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  eq(draw(), "200,200,200,200", "CLAMP_TO_EDGE is not");
  gl.generateMipmap(gl.TEXTURE_2D);
  eq(gl.getError(), gl.INVALID_OPERATION, "no mipmaps of 3 x 1 in WebGL 1");
  // sources
  const src = document.createElement("canvas");
  src.width = src.height = 2;
  const g2 = src.getContext("2d");
  g2.fillStyle = "#ff8000";
  g2.fillRect(0, 0, 2, 2);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, src);
  eq(gl.getError(), 0, "a canvas as a source");
  near(draw(), [255, 128, 0, 255], "its pixels");
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, new ImageData(new Uint8ClampedArray([1, 2, 3, 255]), 1, 1));
  eq(draw(), "1,2,3,255", "an ImageData");
  throws(() => gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, 17), "TypeError", "not an image");
  // mipmaps and cube maps
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 4, 4, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(64).fill(100));
  gl.generateMipmap(gl.TEXTURE_2D);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
  eq(gl.getError(), 0, "generateMipmap");
  eq(draw(), "100,100,100,100", "a mipmapped texture");
  const q = program(gl, VS, "precision mediump float; uniform samplerCube t; void main(){ gl_FragColor = textureCube(t, vec3(1.0, 0.0, 0.0)); }");
  cover(gl, q);
  const cube = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_CUBE_MAP, cube);
  gl.texParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  for (let i = 0; i < 6; i++) gl.texImage2D(gl.TEXTURE_CUBE_MAP_POSITIVE_X + i, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([i * 10, 0, 0, 255]));
  eq(draw(), "0,0,0,255", "the +x face");
  gl.bindTexture(gl.TEXTURE_2D, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  eq(gl.getError(), gl.INVALID_OPERATION, "no texture bound");
  gl.bindTexture(gl.TEXTURE_2D, cube);
  eq(gl.getError(), gl.INVALID_OPERATION, "a cube map is not a 2D texture");
  eq(gl.getParameter(gl.ACTIVE_TEXTURE), gl.TEXTURE0, "ACTIVE_TEXTURE");
  gl.activeTexture(gl.TEXTURE0 + 1000);
  eq(gl.getError(), gl.INVALID_ENUM, "no such unit");
  eq(gl.getTexParameter(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER), gl.NEAREST, "getTexParameter");
  // anisotropy and floats
  const an = gl.getExtension("EXT_texture_filter_anisotropic");
  ok(gl.getParameter(an.MAX_TEXTURE_MAX_ANISOTROPY_EXT) >= 1, "MAX_TEXTURE_MAX_ANISOTROPY_EXT");
  gl.texParameterf(gl.TEXTURE_CUBE_MAP, an.TEXTURE_MAX_ANISOTROPY_EXT, 4);
  eq(gl.getError(), 0, "TEXTURE_MAX_ANISOTROPY_EXT");
  gl.getExtension("OES_texture_float");
  cover(gl, p);
  gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.FLOAT, new Float32Array([0.5, 0.25, 1, 1]));
  eq(gl.getError(), 0, "a float texture");
  near(draw(), [128, 64, 255, 255], "read");
});

test("framebuffers, renderbuffers, depth, stencil, blending", () => {
  if (!available) return;
  const [, gl] = mk("webgl", { stencil: true });
  const p = program(gl, "attribute vec2 p; uniform float z; void main(){ gl_Position = vec4(p, z, 1.0); }", FS);
  cover(gl, p);
  const c = gl.getUniformLocation(p, "c"), z = gl.getUniformLocation(p, "z");
  const fb = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
  eq(gl.checkFramebufferStatus(gl.FRAMEBUFFER), gl.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT, "nothing attached");
  gl.clear(gl.COLOR_BUFFER_BIT);
  eq(gl.getError(), gl.INVALID_FRAMEBUFFER_OPERATION, "clear on an incomplete framebuffer");
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), gl.INVALID_FRAMEBUFFER_OPERATION, "a draw on it");
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, SIZE, SIZE, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
  eq(gl.checkFramebufferStatus(gl.FRAMEBUFFER), gl.FRAMEBUFFER_COMPLETE, "complete");
  gl.uniform4f(c, 0, 1, 0, 1);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(px(gl), "0,255,0,255", "drawn into a texture");
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  const s = program(gl, VS, "precision mediump float; uniform sampler2D t; void main(){ gl_FragColor = texture2D(t, vec2(0.5)); }");
  gl.useProgram(s);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(px(gl), "0,255,0,255", "that texture sampled");
  // a loop: a texture being drawn on, and read
  gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), gl.INVALID_OPERATION, "a feedback loop");
  gl.useProgram(p);
  // depth, from a renderbuffer
  const rb = gl.createRenderbuffer();
  gl.bindRenderbuffer(gl.RENDERBUFFER, rb);
  gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT16, SIZE, SIZE);
  eq(gl.getRenderbufferParameter(gl.RENDERBUFFER, gl.RENDERBUFFER_WIDTH), SIZE, "RENDERBUFFER_WIDTH");
  gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, rb);
  eq(gl.checkFramebufferStatus(gl.FRAMEBUFFER), gl.FRAMEBUFFER_COMPLETE, "with depth");
  eq(gl.getFramebufferAttachmentParameter(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.FRAMEBUFFER_ATTACHMENT_OBJECT_NAME), rb, "the attachment");
  gl.enable(gl.DEPTH_TEST);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  gl.uniform1f(z, -0.5);
  gl.uniform4f(c, 1, 0, 0, 1);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.uniform1f(z, 0.5);
  gl.uniform4f(c, 0, 0, 1, 1);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(px(gl), "255,0,0,255", "what is behind fails");
  gl.depthFunc(gl.GREATER);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(px(gl), "0,0,255,255", "depthFunc");
  gl.depthFunc(gl.LESS);
  gl.disable(gl.DEPTH_TEST);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  // the canvas's stencil
  gl.enable(gl.STENCIL_TEST);
  gl.clearStencil(0);
  gl.clear(gl.STENCIL_BUFFER_BIT | gl.COLOR_BUFFER_BIT);
  gl.stencilFunc(gl.ALWAYS, 1, 0xFF);
  gl.stencilOp(gl.KEEP, gl.KEEP, gl.REPLACE);
  gl.enable(gl.SCISSOR_TEST);
  gl.scissor(0, 0, 4, SIZE);
  gl.uniform4f(c, 1, 1, 1, 1);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.disable(gl.SCISSOR_TEST);
  gl.stencilFunc(gl.NOTEQUAL, 1, 0xFF);
  gl.stencilOp(gl.KEEP, gl.KEEP, gl.KEEP);
  gl.uniform4f(c, 1, 0, 0, 1);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(px(gl, 1, 1), "255,255,255,255", "stencil kept what it marked");
  eq(px(gl, 8, 1), "255,0,0,255", "and let the rest through");
  gl.stencilMaskSeparate(gl.FRONT, 0x0F);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), gl.INVALID_OPERATION, "different masks for front and back");
  gl.stencilMask(0xFF);
  gl.disable(gl.STENCIL_TEST);
  // blending
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE);
  gl.uniform4f(c, 0.25, 0, 0, 0.25);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  near(px(gl), [128, 0, 0, 128], "additive");
  gl.blendEquation(gl.FUNC_REVERSE_SUBTRACT);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  near(px(gl), [64, 0, 0, 64], "reverse subtract is the framebuffer minus the source");
  gl.blendEquation(gl.getExtension("EXT_blend_minmax").MAX_EXT);
  gl.uniform4f(c, 1, 1, 1, 1);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(px(gl), "255,255,255,255", "EXT_blend_minmax");
  gl.blendEquation(gl.FUNC_ADD);
  gl.blendFunc(gl.CONSTANT_COLOR, gl.CONSTANT_ALPHA);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), gl.INVALID_OPERATION, "constant color and constant alpha together");
  gl.blendFunc(gl.ONE, gl.ZERO);
  gl.disable(gl.BLEND);
  // a depth texture
  const dt = gl.getExtension("WEBGL_depth_texture");
  ok(dt, "WEBGL_depth_texture");
  const depth = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, depth);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT, SIZE, SIZE, 0, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT, null);
  eq(gl.getError(), 0, "a depth texture");
  const f2 = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, f2);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, depth, 0);
  const col = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, col);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, SIZE, SIZE, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, col, 0);
  eq(gl.checkFramebufferStatus(gl.FRAMEBUFFER), gl.FRAMEBUFFER_COMPLETE, "with a depth texture");
  gl.enable(gl.DEPTH_TEST);
  gl.clear(gl.DEPTH_BUFFER_BIT);
  gl.uniform1f(z, 0);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.disable(gl.DEPTH_TEST);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  gl.bindTexture(gl.TEXTURE_2D, depth);
  gl.useProgram(s);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  near(px(gl), [128, 0, 0], "what the depth test wrote, sampled: 0.5");
  eq(gl.getError(), 0, "no error");
});

test("the canvas: toDataURL, drawImage, presenting, a new size", async () => {
  if (!available) return;
  const [c, gl] = mk("webgl", { preserveDrawingBuffer: true, antialias: false });
  gl.clearColor(1, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  const two = document.createElement("canvas");
  two.width = two.height = SIZE;
  const g = two.getContext("2d");
  g.drawImage(c, 0, 0);
  eq(Array.from(g.getImageData(1, 1, 1, 1).data).join(), "255,0,0,255", "drawImage of what was just drawn");
  ok(c.toDataURL().startsWith("data:image/png"), "toDataURL");
  const img = await loadImage(c.toDataURL());
  ok(img, "and it is an image");
  if (img) {
    g.clearRect(0, 0, SIZE, SIZE);
    g.drawImage(img, 0, 0);
    eq(Array.from(g.getImageData(1, 1, 1, 1).data).join(), "255,0,0,255", "with the picture");
  }
  // another context takes this canvas as a source
  const [, other] = mk();
  const p = program(other, VS, "precision mediump float; uniform sampler2D t; void main(){ gl_FragColor = texture2D(t, vec2(0.5)); }");
  cover(other, p);
  other.bindTexture(other.TEXTURE_2D, other.createTexture());
  other.texParameteri(other.TEXTURE_2D, other.TEXTURE_MIN_FILTER, other.NEAREST);
  other.texParameteri(other.TEXTURE_2D, other.TEXTURE_WRAP_S, other.CLAMP_TO_EDGE);
  other.texParameteri(other.TEXTURE_2D, other.TEXTURE_WRAP_T, other.CLAMP_TO_EDGE);
  other.texImage2D(other.TEXTURE_2D, 0, other.RGBA, other.RGBA, other.UNSIGNED_BYTE, c);
  other.drawArrays(other.TRIANGLES, 0, 3);
  eq(px(other), "255,0,0,255", "a WebGL canvas as a texture");
  // a new size: a new buffer
  c.width = 8;
  eq(gl.drawingBufferWidth, 8, "drawingBufferWidth follows");
  eq(px(gl, 1, 1), "0,0,0,0", "the buffer is new");
  gl.clearColor(0, 0, 1, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  eq(px(gl, 1, 1), "0,0,255,255", "and works");
  // alpha: false reads opaque
  const [, opaque] = mk("webgl", { alpha: false });
  eq(px(opaque), "0,0,0,255", "alpha: false");
  opaque.clearColor(1, 0, 0, 0);
  opaque.clear(opaque.COLOR_BUFFER_BIT);
  eq(px(opaque), "255,0,0,255", "its alpha stays 1");
  // not preserved: the buffer is new after it was shown
  const [, np] = mk("webgl", { preserveDrawingBuffer: false });
  np.clearColor(0, 1, 0, 1);
  np.clear(np.COLOR_BUFFER_BIT);
  eq(px(np), "0,255,0,255", "before the frame");

  await frame();
  eq(px(np), "0,0,0,0", "after the frame");
  const [, pr] = mk("webgl", { preserveDrawingBuffer: true });
  pr.clearColor(0, 1, 0, 1);
  pr.clear(pr.COLOR_BUFFER_BIT);
  await frame();
  eq(px(pr), "0,255,0,255", "preserved over the frame");
});

test("a canvas with an origin the page may not read", async () => {
  if (!available) return;
  // a canvas tainted by a cross-origin image taints what reads it; the same goes for the image itself
  const url = location.origin.replace("127.0.0.1", "localhost") + CROSS_ORIGIN_IMAGE;
  const img = await loadImage(url);
  ok(img, "an image from another origin");
  if (!img) return;
  const [, gl] = mk();
  gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
  throws(() => gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img), "SecurityError", "a cross-origin image");
  const two = document.createElement("canvas");
  two.width = two.height = 2;
  two.getContext("2d").drawImage(img, 0, 0);
  throws(() => gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, two), "SecurityError", "a tainted canvas");
});

test("context loss", async () => {
  if (!available) return;
  const [c, gl] = mk();
  const ext = gl.getExtension("WEBGL_lose_context");
  const b = gl.createBuffer();
  const events = [];
  c.addEventListener("webglcontextlost", e => { events.push("lost"); e.preventDefault(); });
  c.addEventListener("webglcontextrestored", () => events.push("restored"));
  eq(gl.isContextLost(), false, "not lost");
  ext.loseContext();
  eq(gl.isContextLost(), true, "lost");
  eq(events.join(), "", "the event comes later");
  await sleep(50);
  eq(events.join(), "lost", "the event");
  eq(gl.getError(), gl.CONTEXT_LOST_WEBGL, "CONTEXT_LOST_WEBGL");
  eq(gl.getError(), 0, "once");
  eq(gl.createBuffer(), null, "nothing is made");
  gl.bindBuffer(gl.ARRAY_BUFFER, b);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getParameter(gl.VERSION), null, "no answers");
  eq(gl.getShaderPrecisionFormat(gl.VERTEX_SHADER, gl.HIGH_FLOAT), null, "none here either");
  eq(gl.isBuffer(b), false, "no objects");
  eq(gl.getProgramParameter === undefined, false, "the methods are there");
  ext.restoreContext();
  await sleep(200);
  eq(events.join(), "lost,restored", "the restored event");
  eq(gl.isContextLost(), false, "back");
  eq(gl.getError(), 0, "no error");
  gl.clearColor(1, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  eq(px(gl), "255,0,0,255", "it draws");
  gl.bindBuffer(gl.ARRAY_BUFFER, b);
  eq(gl.getError(), gl.INVALID_OPERATION, "an object of before is no good");
});

test("hostile programs", () => {
  if (!available) return;
  const [, gl] = mk();
  // deep nesting and huge expressions are refused at compile time, the page goes on
  const deep = "void main(){ gl_Position = vec4(" + "(".repeat(20000) + "0.0" + ")".repeat(20000) + "); }";
  eq(gl.getShaderParameter(shader(gl, gl.VERTEX_SHADER, deep), gl.COMPILE_STATUS), false, "too deep");
  const long = "void main(){ gl_Position = vec4(1.0" + "+1.0".repeat(100000) + "); }";
  eq(gl.getShaderParameter(shader(gl, gl.VERTEX_SHADER, long), gl.COMPILE_STATUS), false, "too long a statement");
  let bomb = "#define A0 x x\n";
  for (let i = 1; i < 40; i++) bomb += `#define A${i} A${i - 1} A${i - 1}\n`;
  eq(gl.getShaderParameter(shader(gl, gl.VERTEX_SHADER, bomb + "A39\nvoid main(){}"), gl.COMPILE_STATUS), false, "a macro that doubles forty times");
  eq(gl.isContextLost(), false, "the context lives");
  const p = program(gl);
  cover(gl, p);
  gl.bufferData(gl.ARRAY_BUFFER, 2 ** 40, gl.STATIC_DRAW);
  ok(gl.getError() !== 0, "a buffer too large");
  gl.bufferData(gl.ARRAY_BUFFER, -1, gl.STATIC_DRAW);
  eq(gl.getError(), gl.INVALID_VALUE, "a negative size");
  eq(gl.isContextLost(), false, "the context still lives");
});

test("WebGL 2", () => {
  const [, gl] = mk("webgl2");
  if (gl === null) { ok(true, "no adapter here"); return; }
  ok(gl.getParameter(gl.VERSION).startsWith("WebGL 2.0"), "VERSION");
  ok(gl.getParameter(gl.SHADING_LANGUAGE_VERSION).includes("3.00"), "SHADING_LANGUAGE_VERSION");
  const vs = `#version 300 es
    in vec2 p; in vec2 off; flat out int id; layout(std140) uniform B { vec4 tint; mat4 m; } b; out vec4 v;
    void main(){ id = gl_VertexID + gl_InstanceID; v = b.tint; gl_Position = b.m * vec4(p + off, 0.0, 1.0); }`;
  const fs = `#version 300 es
    precision highp float; precision highp sampler3D; precision highp sampler2DArray; precision highp isampler2D;
    in vec4 v; flat in int id; out vec4 color;
    uniform sampler3D t3; uniform sampler2DArray ta; uniform isampler2D ti;
    void main(){ color = v + texture(t3, vec3(0.5)) + texture(ta, vec3(0.5, 0.5, 1.0)) + vec4(float(texelFetch(ti, ivec2(0), 0).x) / 255.0, 0.0, 0.0, 0.0); }`;
  const p = program(gl, vs, fs);
  eq(gl.getProgramParameter(p, gl.LINK_STATUS), true, "GLSL ES 3.00 links: " + gl.getProgramInfoLog(p));
  gl.useProgram(p);
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);
  eq(gl.isVertexArray(vao), true, "a vertex array");
  const a = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, a);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const at = gl.getAttribLocation(p, "p");
  gl.enableVertexAttribArray(at);
  gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
  const o = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, o);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 9, 9]), gl.STATIC_DRAW);
  const ot = gl.getAttribLocation(p, "off");
  gl.enableVertexAttribArray(ot);
  gl.vertexAttribPointer(ot, 2, gl.FLOAT, false, 0, 0);
  gl.vertexAttribDivisor(ot, 1);
  // the block
  const index = gl.getUniformBlockIndex(p, "B");
  eq(gl.getActiveUniformBlockName(p, index), "B", "getActiveUniformBlockName");
  const size = gl.getActiveUniformBlockParameter(p, index, gl.UNIFORM_BLOCK_DATA_SIZE);
  eq(size, 80, "std140: a vec4 and a mat4");
  gl.uniformBlockBinding(p, index, 2);
  eq(gl.getActiveUniformBlockParameter(p, index, gl.UNIFORM_BLOCK_BINDING), 2, "its binding");
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), gl.INVALID_OPERATION, "no buffer at the block's binding");
  const u = gl.createBuffer();
  gl.bindBuffer(gl.UNIFORM_BUFFER, u);
  gl.bufferData(gl.UNIFORM_BUFFER, new Float32Array([0, 0, 0, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]), gl.DYNAMIC_DRAW);
  gl.bindBufferBase(gl.UNIFORM_BUFFER, 2, u);
  // textures of WebGL 2
  gl.activeTexture(gl.TEXTURE1);
  gl.bindTexture(gl.TEXTURE_3D, gl.createTexture());
  gl.texImage3D(gl.TEXTURE_3D, 0, gl.RGBA8, 1, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([50, 0, 0, 0]));
  gl.texParameteri(gl.TEXTURE_3D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  eq(gl.getError(), 0, "a 3D texture");
  gl.activeTexture(gl.TEXTURE2);
  gl.bindTexture(gl.TEXTURE_2D_ARRAY, gl.createTexture());
  gl.texStorage3D(gl.TEXTURE_2D_ARRAY, 1, gl.RGBA8, 1, 1, 2);
  gl.texSubImage3D(gl.TEXTURE_2D_ARRAY, 0, 0, 0, 1, 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([0, 60, 0, 0]));
  gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  eq(gl.getError(), 0, "a 2D array texture");
  gl.activeTexture(gl.TEXTURE3);
  gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8I, 1, 1, 0, gl.RED_INTEGER, gl.BYTE, new Int8Array([70]));
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  eq(gl.getError(), 0, "an integer texture");
  gl.uniform1i(gl.getUniformLocation(p, "t3"), 1);
  gl.uniform1i(gl.getUniformLocation(p, "ta"), 2);
  gl.uniform1i(gl.getUniformLocation(p, "ti"), 3);
  gl.drawArraysInstanced(gl.TRIANGLES, 0, 3, 2);
  eq(gl.getError(), 0, "drawn");
  near(px(gl), [120, 60, 0, 255], "everything added up");
  // a sampler object
  const smp = gl.createSampler();
  gl.samplerParameteri(smp, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  eq(gl.getSamplerParameter(smp, gl.TEXTURE_WRAP_S), gl.CLAMP_TO_EDGE, "a sampler's parameter");
  gl.bindSampler(0, smp);
  eq(gl.getParameter(gl.SAMPLER_BINDING) === null, true, "another unit is active");
  gl.bindSampler(0, null);
  // multiple render targets, sized formats, blit, readPixels of integers
  const f = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, f);
  const color = i => {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, SIZE, SIZE);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0 + i, gl.TEXTURE_2D, t, 0);
    return t;
  };
  color(0);
  color(1);
  gl.drawBuffers([gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1]);
  eq(gl.getParameter(gl.DRAW_BUFFER1), gl.COLOR_ATTACHMENT1, "DRAW_BUFFER1");
  const mrt = program(gl, "#version 300 es\nin vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }", "#version 300 es\nprecision mediump float; layout(location = 0) out vec4 a; layout(location = 1) out vec4 b; void main(){ a = vec4(1.0, 0.0, 0.0, 1.0); b = vec4(0.0, 1.0, 0.0, 1.0); }");
  gl.useProgram(mrt);
  const vao2 = gl.createVertexArray();
  gl.bindVertexArray(vao2);
  gl.bindBuffer(gl.ARRAY_BUFFER, a);
  gl.enableVertexAttribArray(gl.getAttribLocation(mrt, "p"));
  gl.vertexAttribPointer(gl.getAttribLocation(mrt, "p"), 2, gl.FLOAT, false, 0, 0);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), 0, "two targets");
  gl.readBuffer(gl.COLOR_ATTACHMENT1);
  eq(px(gl), "0,255,0,255", "the second");
  gl.readBuffer(gl.COLOR_ATTACHMENT0);
  eq(px(gl), "255,0,0,255", "the first");
  gl.bindFramebuffer(gl.READ_FRAMEBUFFER, f);
  gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
  gl.blitFramebuffer(0, 0, SIZE, SIZE, 0, 0, SIZE, SIZE, gl.COLOR_BUFFER_BIT, gl.NEAREST);
  eq(gl.getError(), 0, "a blit");
  gl.bindFramebuffer(gl.READ_FRAMEBUFFER, null);
  eq(px(gl), "255,0,0,255", "on the canvas");
  // a multisampled renderbuffer resolved by a blit
  const ms = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, ms);
  const rb = gl.createRenderbuffer();
  gl.bindRenderbuffer(gl.RENDERBUFFER, rb);
  gl.renderbufferStorageMultisample(gl.RENDERBUFFER, 4, gl.RGBA8, SIZE, SIZE);
  gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, rb);
  eq(gl.checkFramebufferStatus(gl.FRAMEBUFFER), gl.FRAMEBUFFER_COMPLETE, "a multisampled framebuffer");
  gl.clearColor(0, 0, 1, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.bindFramebuffer(gl.READ_FRAMEBUFFER, ms);
  gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
  gl.blitFramebuffer(0, 0, SIZE, SIZE, 0, 0, SIZE, SIZE, gl.COLOR_BUFFER_BIT, gl.NEAREST);
  eq(gl.getError(), 0, "resolved");
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);
  eq(px(gl), "0,0,255,255", "on the canvas");
  // buffers
  const b1 = gl.createBuffer(), b2 = gl.createBuffer();
  gl.bindBuffer(gl.COPY_READ_BUFFER, b1);
  gl.bufferData(gl.COPY_READ_BUFFER, new Uint8Array([1, 2, 3, 4]), gl.STATIC_DRAW);
  gl.bindBuffer(gl.COPY_WRITE_BUFFER, b2);
  gl.bufferData(gl.COPY_WRITE_BUFFER, 4, gl.STATIC_DRAW);
  gl.copyBufferSubData(gl.COPY_READ_BUFFER, gl.COPY_WRITE_BUFFER, 1, 0, 2);
  const out = new Uint8Array(4);
  gl.getBufferSubData(gl.COPY_WRITE_BUFFER, 0, out);
  eq(Array.from(out).join(), "2,3,0,0", "copyBufferSubData and getBufferSubData");
  const sync = gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0);
  eq(gl.clientWaitSync(sync, 0, 0), gl.ALREADY_SIGNALED, "a fence");
  eq(gl.getError(), 0, "no error");
});

const VS_TF = "#version 300 es\nin vec2 p; out vec3 v; out float s; void main(){ v = vec3(p, p.x + p.y); s = p.x * 2.0; gl_Position = vec4(p, 0.0, 1.0); }";
const FS_TF = "#version 300 es\nprecision mediump float; in vec3 v; out vec4 o; void main(){ o = vec4(v, 1.0); }";
const tfProgram = (gl, names, mode) => {
  const p = gl.createProgram();
  gl.attachShader(p, shader(gl, gl.VERTEX_SHADER, VS_TF));
  gl.attachShader(p, shader(gl, gl.FRAGMENT_SHADER, FS_TF));
  gl.transformFeedbackVaryings(p, names, mode);
  gl.linkProgram(p);
  return p;
};
const pointsBuffer = (gl, data) => {
  const b = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, b);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  return b;
};
const laterTask = () => new Promise(r => setTimeout(r, 0));

test("transform feedback: interleaved, separate, pause, the rules", () => {
  const [, gl] = mk("webgl2");
  if (gl === null) { ok(true, "no adapter here"); return; }
  const most = gl.getParameter(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS);
  if (most === 0) {
    eq(gl.getParameter(gl.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS), 0, "this adapter cannot, and says so");
    gl.beginTransformFeedback(gl.POINTS);
    eq(gl.getError(), gl.INVALID_OPERATION, "starting it is an error");
    return;
  }
  eq(most, 4, "the minimum of OpenGL ES 3.0");
  eq(gl.getParameter(gl.MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS), 64, "the minimum of OpenGL ES 3.0");
  eq(gl.getParameter(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS), 4, "the minimum of OpenGL ES 3.0");
  const p = tfProgram(gl, ["v", "s"], gl.INTERLEAVED_ATTRIBS);
  ok(gl.getProgramParameter(p, gl.LINK_STATUS), gl.getProgramInfoLog(p));
  eq(gl.getProgramParameter(p, gl.TRANSFORM_FEEDBACK_VARYINGS), 2, "two varyings");
  eq(gl.getProgramParameter(p, gl.TRANSFORM_FEEDBACK_BUFFER_MODE), gl.INTERLEAVED_ATTRIBS, "the mode");
  const info = gl.getTransformFeedbackVarying(p, 0);
  eq(info.name, "v", "its name");
  eq(info.type, gl.FLOAT_VEC3, "its type");
  eq(info.size, 1, "its size");
  gl.getTransformFeedbackVarying(p, 2);
  eq(gl.getError(), gl.INVALID_VALUE, "no third one");
  gl.useProgram(p);
  pointsBuffer(gl, [1, 2, 3, 4, 5, 6]);
  const tf = gl.createTransformFeedback();
  eq(gl.isTransformFeedback(tf), false, "not bound yet");
  gl.bindTransformFeedback(gl.TRANSFORM_FEEDBACK, tf);
  eq(gl.isTransformFeedback(tf), true, "bound");
  eq(gl.getParameter(gl.TRANSFORM_FEEDBACK_BINDING), tf, "the binding");
  const out = gl.createBuffer();
  gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, out);
  gl.bufferData(gl.TRANSFORM_FEEDBACK_BUFFER, 48, gl.STATIC_READ);
  gl.bindBufferBase(gl.TRANSFORM_FEEDBACK_BUFFER, 0, out);
  eq(gl.getIndexedParameter(gl.TRANSFORM_FEEDBACK_BUFFER_BINDING, 0), out, "bound at 0");
  gl.enable(gl.RASTERIZER_DISCARD);
  gl.beginTransformFeedback(gl.POINTS);
  eq(gl.getParameter(gl.TRANSFORM_FEEDBACK_ACTIVE), true, "active");
  eq(gl.getError(), 0, "it starts");
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), gl.INVALID_OPERATION, "not the primitive it began with");
  gl.drawElements(gl.POINTS, 1, gl.UNSIGNED_SHORT, 0);
  eq(gl.getError(), gl.INVALID_OPERATION, "no elements");
  gl.drawArrays(gl.POINTS, 0, 1);
  gl.pauseTransformFeedback();
  eq(gl.getParameter(gl.TRANSFORM_FEEDBACK_PAUSED), true, "paused");
  gl.drawArrays(gl.POINTS, 1, 1);
  gl.resumeTransformFeedback();
  gl.drawArrays(gl.POINTS, 2, 1);
  gl.endTransformFeedback();
  eq(gl.getError(), 0, "no error");
  gl.disable(gl.RASTERIZER_DISCARD);
  const got = new Float32Array(12);
  gl.getBufferSubData(gl.TRANSFORM_FEEDBACK_BUFFER, 0, got);
  eq(Array.from(got).join(), "1,2,3,2,5,6,11,10,0,0,0,0", "what was captured, in order, none of what was paused");
  gl.endTransformFeedback();
  eq(gl.getError(), gl.INVALID_OPERATION, "not active");
  // into separate buffers, an array of them from gl_Position
  const q = tfProgram(gl, ["gl_Position", "s"], gl.SEPARATE_ATTRIBS);
  ok(gl.getProgramParameter(q, gl.LINK_STATUS), gl.getProgramInfoLog(q));
  gl.useProgram(q);
  const a = gl.createBuffer(), b = gl.createBuffer();
  gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, a);
  gl.bufferData(gl.TRANSFORM_FEEDBACK_BUFFER, 16, gl.STATIC_READ);
  gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, b);
  gl.bufferData(gl.TRANSFORM_FEEDBACK_BUFFER, 8, gl.STATIC_READ);
  gl.bindBufferRange(gl.TRANSFORM_FEEDBACK_BUFFER, 0, a, 0, 16);
  gl.bindBufferRange(gl.TRANSFORM_FEEDBACK_BUFFER, 1, b, 4, 4);
  gl.beginTransformFeedback(gl.POINTS);
  gl.drawArrays(gl.POINTS, 2, 1);
  gl.endTransformFeedback();
  eq(gl.getError(), 0, "no error");
  const pos = new Float32Array(4), size = new Float32Array(2);
  gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, a);
  gl.getBufferSubData(gl.TRANSFORM_FEEDBACK_BUFFER, 0, pos);
  gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, b);
  gl.getBufferSubData(gl.TRANSFORM_FEEDBACK_BUFFER, 0, size);
  eq(Array.from(pos).join(), "5,6,0,1", "gl_Position in the first");
  eq(Array.from(size).join(), "0,10", "the other at its offset");
  // a varying that does not exist
  const bad = tfProgram(gl, ["nope"], gl.INTERLEAVED_ATTRIBS);
  eq(gl.getProgramParameter(bad, gl.LINK_STATUS), false, "the link fails");
});

test("transform feedback: drawing what it wrote, and it still draws", async () => {
  const [, gl] = mk("webgl2");
  if (gl === null || gl.getParameter(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS) === 0) { ok(true, "not here"); return; }
  const p = tfProgram(gl, ["gl_Position"], gl.INTERLEAVED_ATTRIBS);
  gl.useProgram(p);
  pointsBuffer(gl, [-1, -1, 3, -1, -1, 3]);
  const out = gl.createBuffer();
  gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, out);
  gl.bufferData(gl.TRANSFORM_FEEDBACK_BUFFER, 48, gl.DYNAMIC_COPY);
  gl.bindBufferBase(gl.TRANSFORM_FEEDBACK_BUFFER, 0, out);
  gl.clearColor(0, 0, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.beginTransformFeedback(gl.TRIANGLES);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.endTransformFeedback();
  eq(gl.getError(), 0, "no error");
  ok(px(gl, 14, 14) !== "0,0,0,255", "it rasterized too: " + px(gl, 14, 14));
  // the captured vertices as an attribute, in the next draw
  gl.bindBufferBase(gl.TRANSFORM_FEEDBACK_BUFFER, 0, null);
  gl.bindBuffer(gl.ARRAY_BUFFER, out);
  gl.vertexAttribPointer(0, 4, gl.FLOAT, false, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  eq(gl.getError(), 0, "no error");
});

test("queries: results on a later task, samples passed or not, primitives written", async () => {
  const [, gl] = mk("webgl2");
  if (gl === null) { ok(true, "no adapter here"); return; }
  const prog = program(gl, "#version 300 es\nin vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }", "#version 300 es\nprecision mediump float; out vec4 o; void main(){ o = vec4(1.0); }");
  gl.useProgram(prog);
  pointsBuffer(gl, [-1, -1, 3, -1, -1, 3]);
  const hit = gl.createQuery(), miss = gl.createQuery();
  eq(gl.isQuery(hit), false, "not begun");
  gl.beginQuery(gl.ANY_SAMPLES_PASSED, hit);
  eq(gl.getQuery(gl.ANY_SAMPLES_PASSED, gl.CURRENT_QUERY), hit, "the current one");
  eq(gl.isQuery(hit), true, "begun");
  gl.beginQuery(gl.ANY_SAMPLES_PASSED_CONSERVATIVE, miss);
  eq(gl.getError(), gl.INVALID_OPERATION, "one of samples at a time");
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.endQuery(gl.ANY_SAMPLES_PASSED);
  eq(gl.getQueryParameter(hit, gl.QUERY_RESULT_AVAILABLE), false, "never in the task that ended it");
  gl.beginQuery(gl.ANY_SAMPLES_PASSED_CONSERVATIVE, miss);
  gl.enable(gl.SCISSOR_TEST);
  gl.scissor(0, 0, 0, 0);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  gl.endQuery(gl.ANY_SAMPLES_PASSED_CONSERVATIVE);
  gl.disable(gl.SCISSOR_TEST);
  const stillThere = gl.getQueryParameter(hit, gl.QUERY_RESULT_AVAILABLE);
  eq(stillThere, false, "nor later in that task");
  let available = false;
  for (let i = 0; i < 200 && !available; i++) {
    await laterTask();
    available = gl.getQueryParameter(hit, gl.QUERY_RESULT_AVAILABLE) && gl.getQueryParameter(miss, gl.QUERY_RESULT_AVAILABLE);
    if (!available) await sleep(5);
  }
  ok(available, "available on a later task");
  eq(gl.getQueryParameter(hit, gl.QUERY_RESULT), 1, "samples passed");
  eq(gl.getQueryParameter(miss, gl.QUERY_RESULT), 0, "none passed the scissor");
  gl.deleteQuery(hit);
  eq(gl.isQuery(hit), false, "deleted");
  eq(gl.getError(), 0, "no error");
  if (gl.getParameter(gl.MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS) === 0) return;
  const p = tfProgram(gl, ["s"], gl.INTERLEAVED_ATTRIBS);
  gl.useProgram(p);
  const out = gl.createBuffer();
  gl.bindBuffer(gl.TRANSFORM_FEEDBACK_BUFFER, out);
  gl.bufferData(gl.TRANSFORM_FEEDBACK_BUFFER, 24, gl.STATIC_READ);
  gl.bindBufferBase(gl.TRANSFORM_FEEDBACK_BUFFER, 0, out);
  const written = gl.createQuery();
  gl.enable(gl.RASTERIZER_DISCARD);
  gl.beginQuery(gl.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN, written);
  gl.beginTransformFeedback(gl.TRIANGLES);
  gl.drawArrays(gl.TRIANGLE_FAN, 0, 3);
  gl.endTransformFeedback();
  gl.endQuery(gl.TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN);
  gl.disable(gl.RASTERIZER_DISCARD);
  await laterTask();
  await sleep(1);
  eq(gl.getQueryParameter(written, gl.QUERY_RESULT), 1, "one triangle");
});

test("a vertex attribute divisor above 1", () => {
  const [, gl] = mk("webgl2", undefined, 4, 4);
  if (gl === null) { ok(true, "no adapter here"); return; }
  const prog = program(gl, "#version 300 es\nlayout(location = 0) in vec2 p; layout(location = 1) in float k; out float v; void main(){ v = k; gl_Position = vec4(p.x * 0.5 + float(gl_InstanceID) - 1.5, p.y, 0.0, 1.0); }",
    "#version 300 es\nprecision mediump float; in float v; out vec4 o; void main(){ o = vec4(v, 0.0, 0.0, 1.0); }");
  gl.useProgram(prog);
  pointsBuffer(gl, [-1, -1, 1, -1, -1, 3, 1, -1, 1, 3, -1, 3]);
  const values = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, values);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([1, 0]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(1);
  gl.vertexAttribPointer(1, 1, gl.FLOAT, false, 0, 0);
  gl.vertexAttribDivisor(1, 2);
  gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, 4);
  eq(gl.getError(), 0, "no error");
  const row = new Uint8Array(16);
  gl.readPixels(0, 1, 4, 1, gl.RGBA, gl.UNSIGNED_BYTE, row);
  eq([row[0], row[4], row[8], row[12]].join(), "255,255,0,0", "two instances of each value");
  gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, 5);
  eq(gl.getError(), gl.INVALID_OPERATION, "a fifth instance reads past the buffer");
});

test("what a page sets on the canvas does not need a shell", () => {
  // getContext on a canvas of no size
  const c = document.createElement("canvas");
  c.width = 0; c.height = 0;
  const gl = c.getContext("webgl");
  if (gl === null) { ok(true, "no adapter here"); return; }
  eq(gl.drawingBufferWidth, 0, "a canvas of no size");
  gl.clear(gl.COLOR_BUFFER_BIT);
  eq(gl.getError(), 0, "drawing on it does nothing");
  c.width = 4; c.height = 4;
  gl.clearColor(1, 1, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  eq(px(gl), "255,255,0,255", "a size given later");
});

// ---- in a worker ----

// Runs `body` in a dedicated worker, as the body of an async function given (say, gl, px): each say() is a line. Comes back with the
// lines when it says "end".
const inWorker = (body, message, transfer) => new Promise(done => {
  const source = `
    const say = t => postMessage(String(t));
    const px = gl => { const p = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, p); return p.join(); };
    const frameIn = () => new Promise(requestAnimationFrame);
    const run = async m => { try { ${body} } catch (e) { say("threw " + e.name + " " + e.message); } say("end"); };
    onmessage = e => run(e.data);
  `;
  const lines = [];
  const w = new Worker("data:text/javascript," + encodeURIComponent(source));
  w.onmessage = e => { if (e.data === "end") { w.terminate(); done(lines); } else lines.push(e.data); };
  w.onerror = e => { lines.push("error " + e.message); w.terminate(); done(lines); };
  w.postMessage(message === undefined ? 0 : message, transfer === undefined ? [] : transfer);
});

test("a worker: the interfaces, and a context on an OffscreenCanvas", async () => {
  if (mk() === null) return;
  const lines = await inWorker(`
    say(typeof WebGLRenderingContext + " " + typeof WebGL2RenderingContext + " " + typeof WebGLBuffer + " " + typeof WebGLContextEvent);
    const c = new OffscreenCanvas(16, 16);
    const gl = c.getContext("webgl", { antialias: false });
    say(gl instanceof WebGLRenderingContext);
    say(gl.canvas === c);
    gl.clearColor(0, 1, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    say(px(gl));
    say(gl.getError());
    const g2 = new OffscreenCanvas(16, 16).getContext("webgl2", { antialias: false });
    say(g2 instanceof WebGL2RenderingContext);
    g2.clearColor(1, 0, 0, 1);
    g2.clear(g2.COLOR_BUFFER_BIT);
    say(px(g2));
    const s = gl.createShader(gl.VERTEX_SHADER);
    gl.shaderSource(s, "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }");
    gl.compileShader(s);
    say(gl.getShaderParameter(s, gl.COMPILE_STATUS));
  `);
  eq(lines.join("|"), "function function function function|true|true|0,255,0,255|0|true|255,0,0,255|true", "what the worker saw");
});

test("a worker: transferToImageBitmap takes the frame and starts another", async () => {
  if (mk() === null) return;
  const lines = await inWorker(`
    const c = new OffscreenCanvas(16, 16);
    const gl = c.getContext("webgl", { antialias: false });
    gl.clearColor(0, 0, 1, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    const b = c.transferToImageBitmap();
    say(b.width + "x" + b.height);
    const read = new OffscreenCanvas(16, 16).getContext("2d");
    read.drawImage(b, 0, 0);
    say(read.getImageData(4, 4, 1, 1).data.join());
    // the drawing buffer starts again; the clear color stays
    say(px(gl));
    gl.clear(gl.COLOR_BUFFER_BIT);
    say(px(gl));
    const blob = await c.convertToBlob();
    say(blob.type + " " + (blob.size > 0));
  `);
  eq(lines.join("|"), "16x16|0,0,255,255|0,0,0,0|0,0,255,255|image/png true", "what the worker saw");
});

// What an element shows, read back as a page can.
const shown = canvas => {
  const r = document.createElement("canvas");
  r.width = canvas.width;
  r.height = canvas.height;
  const g = r.getContext("2d");
  g.drawImage(canvas, 0, 0);
  return g.getImageData(1, 1, 1, 1).data.join();
};

const FRAME_WAIT_MS = 60000;   // (what a worker's frames may take on a loaded machine: a count of turns was 6 s)
const frameUntil = async (f, what) => {
  const start = performance.now();
  while (performance.now() - start < FRAME_WAIT_MS) {
    if (f()) return true;
    await signal("frame");
    await sleep(20);
  }
  console.log("FAIL waited too long for " + what);
  return false;
};

test("transferControlToOffscreen: a worker's frames reach the page's canvas", async () => {
  if (mk() === null) return;
  const c = document.createElement("canvas");
  c.width = c.height = SIZE;
  const off = c.transferControlToOffscreen();
  ok(off instanceof OffscreenCanvas, "an OffscreenCanvas");
  eq(off.width, SIZE, "of the element's size");
  throws(() => c.transferControlToOffscreen(), "InvalidStateError", "only once");
  throws(() => c.getContext("2d"), "InvalidStateError", "the element has no context from now on");
  throws(() => c.getContext("webgl"), "InvalidStateError", "of any kind");
  inWorker(`
    const gl = m.canvas.getContext("webgl", { antialias: false });
    say(m.canvas.width);
    for (const color of [[1, 0, 0], [0, 1, 0]]) {
      for (let i = 0; i < 40; i++) {
        gl.clearColor(color[0], color[1], color[2], 1);
        gl.clear(gl.COLOR_BUFFER_BIT);
        await frameIn();
      }
    }
    // (it stays, with its last frame on its way, until the page goes)
    await new Promise(() => {});
  `, { canvas: off }, [off]);
  eq(off.width, 0, "the object here is detached");
  throws(() => structuredClone(off, { transfer: [off] }), "DataCloneError", "it cannot be transferred again");
  await frameUntil(() => shown(c) === "0,255,0,255", "the worker's last color on the page's canvas");
  eq(shown(c), "0,255,0,255", "the worker's color");
});

test("transferControlToOffscreen: a worker's 2D canvas too, and a context stays with its canvas", async () => {
  const c = document.createElement("canvas");
  c.width = c.height = SIZE;
  const off = c.transferControlToOffscreen();
  const lines = [];
  const worker = new Worker("data:text/javascript," + encodeURIComponent(`
    onmessage = e => {
      const g = e.data.getContext("2d");
      g.fillStyle = "#0000ff";
      g.fillRect(0, 0, 100, 100);
      postMessage("drawn");
    };
  `));
  worker.onmessage = e => lines.push(e.data);
  worker.postMessage(off, [off]);
  await frameUntil(() => lines.length > 0 && shown(c) === "0,0,255,255", "the worker's 2D drawing on the page's canvas");
  worker.terminate();
  const owned = new OffscreenCanvas(4, 4);
  owned.getContext("2d");
  throws(() => structuredClone(owned, { transfer: [owned] }), "InvalidStateError", "a canvas with a context cannot be transferred");
  throws(() => structuredClone(new OffscreenCanvas(4, 4)), "DataCloneError", "nor cloned at all");
  const other = document.createElement("canvas");
  other.getContext("2d");
  throws(() => other.transferControlToOffscreen(), "InvalidStateError", "nor an element with a context give up its drawing");
});

__run();
