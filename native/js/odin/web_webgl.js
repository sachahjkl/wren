// WebGL 1 and 2 (https://registry.khronos.org/webgl/specs/latest/) over the natives of web_webgl.odin, run the first time a script
// of a window or a worker asks for a context or reads one of the interfaces. Here: the objects, Web IDL's conversions and overloads, and a
// command buffer; calls are written to it and sent at the end of the task, or when something has to wait for an answer.
// OpenGL ES's rules and the errors of getError are on the device's side (native/webgl: a thread per context in the GPU process); what is
// checked here is what only the realm can know: which object is whose. What it uses of the realm is taken here, so what the
// page replaces later does not reach it.
(function (native, global) {
  "use strict";
  const TE = TypeError, I32 = Int32Array, F32 = Float32Array, U32 = Uint32Array, U8 = Uint8Array, AB = ArrayBuffer;
  const isView = AB.isView, isArray = Array.isArray, MapC = Map, WeakMapC = WeakMap, defineProperty = Object.defineProperty;
  const microtask = global.queueMicrotask, Ev = global.Event, dispatch = global.EventTarget.prototype.dispatchEvent;
  const TD = global.TextDecoder, setTimeoutFn = global.setTimeout;
  const HTMLCanvas = global.HTMLCanvasElement, Offscreen = global.OffscreenCanvas, ImageDataC = global.ImageData;
  // (a worker has no elements)
  const canvasGetWidth = HTMLCanvas === undefined ? undefined : Object.getOwnPropertyDescriptor(HTMLCanvas.prototype, "width").get;
  const utf8 = new TD();
  const S = Symbol("webgl"), TOKEN = {};

  // How long between tries to get a lost context back, and how many: a hung GPU process is ended after some 30 s (webgl.gpu_hang_ms).
  const RESTORE_WAIT_MS = 1000, RESTORE_TRIES = 120;

  // ---- what ops.rs says ----
  // (which target a query goes by: a context has one of each active)
  const QUERY_SLOT = { 0x8C2F: 0, 0x8D6A: 0, 0x8C88: 1 };
  const OP = { TF_VARYINGS: 100, BIND_TF: 101, BEGIN_TF: 102, END_TF: 103, PAUSE_TF: 104, RESUME_TF: 105, DELETE_TF: 106, BEGIN_QUERY: 107, END_QUERY: 108, DELETE_QUERY: 109, ACTIVE_TEXTURE: 1, ATTACH_SHADER: 2, DETACH_SHADER: 3, BIND_ATTRIB_LOCATION: 4, BIND_BUFFER: 5, BIND_FRAMEBUFFER: 6, BIND_RENDERBUFFER: 7, BIND_TEXTURE: 8,
    BLEND_COLOR: 9, BLEND_EQUATION: 10, BLEND_FUNC: 11, BUFFER_DATA: 12, BUFFER_SUB_DATA: 13, CLEAR: 14, CLEAR_COLOR: 15, CLEAR_DEPTH: 16, CLEAR_STENCIL: 17, COLOR_MASK: 18,
    COMPILE_SHADER: 19, SHADER_SOURCE: 20, COMPRESSED_TEX_IMAGE: 21, COMPRESSED_TEX_SUB_IMAGE: 22, COPY_TEX_IMAGE: 23, COPY_TEX_SUB_IMAGE: 24, DELETE_BUFFER: 25, DELETE_FRAMEBUFFER: 26,
    DELETE_PROGRAM: 27, DELETE_RENDERBUFFER: 28, DELETE_SHADER: 29, DELETE_TEXTURE: 30, CULL_FACE: 31, DEPTH_FUNC: 32, DEPTH_MASK: 33, DEPTH_RANGE: 34, DISABLE: 35, ENABLE: 36,
    DISABLE_ATTRIB: 37, ENABLE_ATTRIB: 38, DRAW_ARRAYS: 39, DRAW_ELEMENTS: 40, FRAMEBUFFER_RENDERBUFFER: 42, FRAMEBUFFER_TEXTURE: 43, FRONT_FACE: 44, GENERATE_MIPMAP: 45, HINT: 46,
    LINE_WIDTH: 47, LINK_PROGRAM: 48, PIXEL_STOREI: 49, POLYGON_OFFSET: 50, RENDERBUFFER_STORAGE: 51, SAMPLE_COVERAGE: 52, SCISSOR: 53, STENCIL_FUNC: 54, STENCIL_MASK: 55, STENCIL_OP: 56,
    TEX_IMAGE: 57, TEX_SUB_IMAGE: 58, TEX_IMAGE_SOURCE: 59, TEX_PARAMETER_I: 60, TEX_PARAMETER_F: 61, UNIFORM: 62, USE_PROGRAM: 63, VERTEX_ATTRIB: 65, VERTEX_ATTRIB_POINTER: 66,
    VERTEX_ATTRIB_DIVISOR: 67, VIEWPORT: 68, BIND_VAO: 69, DELETE_VAO: 70, ERROR: 71, BLIT_FRAMEBUFFER: 72, FRAMEBUFFER_TEXTURE_LAYER: 73, READ_BUFFER: 75, DRAW_BUFFERS: 76,
    CLEAR_BUFFER: 77, BIND_BUFFER_RANGE: 78, UNIFORM_BLOCK_BINDING: 79, TEX_STORAGE: 80, COPY_BUFFER_SUB_DATA: 81, BIND_SAMPLER: 82, DELETE_SAMPLER: 83, SAMPLER_PARAMETER_I: 84,
    SAMPLER_PARAMETER_F: 85, ENABLE_EXTENSION: 86, COPY_TEX_SUB_IMAGE_3D: 87 };
  const Q = { ERROR: 1, PARAMETER: 2, SHADER: 3, SHADER_LOG: 4, PROGRAM: 5, PROGRAM_LOG: 6, ACTIVE_ATTRIB: 7, ACTIVE_UNIFORM: 8, ATTRIB_LOCATION: 9, UNIFORM_LOCATION: 10, UNIFORM: 11,
    FRAMEBUFFER_STATUS: 12, READ_PIXELS: 13, TEX_PARAMETER: 14, BUFFER_PARAMETER: 15, RENDERBUFFER_PARAMETER: 16, ATTACHMENT_PARAMETER: 17, VERTEX_ATTRIB: 18, SAMPLER_PARAMETER: 19,
    INDEXED: 20, BUFFER_SUB_DATA: 21, BLOCK: 22, UNIFORM_INDICES: 23, ACTIVE_UNIFORMS: 24, FINISH: 25, SNAPSHOT: 26, VALIDATE: 27, FORMAT_SAMPLES: 28, FRAG_DATA_LOCATION: 29, TF_VARYING: 30, QUERY: 31 };
  const TAG = { NULL: 0, INT: 1, FLOAT: 2, BOOL: 3, INTS: 4, FLOATS: 5, BOOLS: 6, STRING: 7, OBJECT: 8, UINT: 9, UINTS: 10 };
  const OBJ_BUFFER = 1, OBJ_FRAMEBUFFER = 2, OBJ_RENDERBUFFER = 3, OBJ_TEXTURE = 4, OBJ_PROGRAM = 5, OBJ_VAO = 6, OBJ_SAMPLER = 7, OBJ_SHADER = 8;
  // The extensions the device side is told of.
  const EXT = { element_index_uint: 1, standard_derivatives: 2, vao: 3, instanced: 4, texture_float: 5, texture_half_float: 6, texture_float_linear: 7, texture_half_float_linear: 8,
    blend_minmax: 9, depth_texture: 10, anisotropic: 11, frag_depth: 12, shader_texture_lod: 13, srgb: 14, color_buffer_float: 15, color_buffer_half_float: 16, draw_buffers: 17, s3tc: 18 };

  const INVALID_ENUM = 0x500, INVALID_VALUE = 0x501, INVALID_OPERATION = 0x502, OUT_OF_MEMORY = 0x505, CONTEXT_LOST = 0x9242;
  // The commands of what runs thousands of times a frame, as locals of this function (a property read costs here).
  const OP_UNIFORM = OP.UNIFORM, OP_DRAW_ARRAYS = OP.DRAW_ARRAYS, OP_DRAW_ELEMENTS = OP.DRAW_ELEMENTS;
  const COMMAND_WORDS = 1 << 16;   // the command buffer of a context (flushed when it is nearly full)
  const FLUSH_AT = COMMAND_WORDS - 256;   // room left for the largest fixed command
  const REPLY_BYTES = 1 << 20;
  const INFO_WORDS = 8;
  const WHOLE_BUFFER = -1;   // BIND_BUFFER_RANGE: no size (u32::MAX on the wire)
  const DRAWING_BUFFER_FORMAT = 0x8058;   // RGBA8
  const SOURCE_COMMAND_WORDS = 13;   // TEX_IMAGE_SOURCE before its bytes (the browser fills in the source's size)
  const MAX_BUFFER_BYTES = 2 ** 31 - 1;   // larger than any buffer a context can hold

  // The constants of the WebGL IDL (Khronos, webgl.idl and webgl2.idl).
  const CONSTANTS1 = {
    DEPTH_BUFFER_BIT: 0x00000100, STENCIL_BUFFER_BIT: 0x00000400, COLOR_BUFFER_BIT: 0x00004000, POINTS: 0x0000, LINES: 0x0001, LINE_LOOP: 0x0002, 
    LINE_STRIP: 0x0003, TRIANGLES: 0x0004, TRIANGLE_STRIP: 0x0005, TRIANGLE_FAN: 0x0006, ZERO: 0, ONE: 1, SRC_COLOR: 0x0300, ONE_MINUS_SRC_COLOR: 0x0301, 
    SRC_ALPHA: 0x0302, ONE_MINUS_SRC_ALPHA: 0x0303, DST_ALPHA: 0x0304, ONE_MINUS_DST_ALPHA: 0x0305, DST_COLOR: 0x0306, ONE_MINUS_DST_COLOR: 0x0307, 
    SRC_ALPHA_SATURATE: 0x0308, FUNC_ADD: 0x8006, BLEND_EQUATION: 0x8009, BLEND_EQUATION_RGB: 0x8009, BLEND_EQUATION_ALPHA: 0x883D, FUNC_SUBTRACT: 
    0x800A, FUNC_REVERSE_SUBTRACT: 0x800B, BLEND_DST_RGB: 0x80C8, BLEND_SRC_RGB: 0x80C9, BLEND_DST_ALPHA: 0x80CA, BLEND_SRC_ALPHA: 0x80CB, 
    CONSTANT_COLOR: 0x8001, ONE_MINUS_CONSTANT_COLOR: 0x8002, CONSTANT_ALPHA: 0x8003, ONE_MINUS_CONSTANT_ALPHA: 0x8004, BLEND_COLOR: 0x8005, 
    ARRAY_BUFFER: 0x8892, ELEMENT_ARRAY_BUFFER: 0x8893, ARRAY_BUFFER_BINDING: 0x8894, ELEMENT_ARRAY_BUFFER_BINDING: 0x8895, STREAM_DRAW: 0x88E0, 
    STATIC_DRAW: 0x88E4, DYNAMIC_DRAW: 0x88E8, BUFFER_SIZE: 0x8764, BUFFER_USAGE: 0x8765, CURRENT_VERTEX_ATTRIB: 0x8626, FRONT: 0x0404, BACK: 0x0405, 
    FRONT_AND_BACK: 0x0408, CULL_FACE: 0x0B44, BLEND: 0x0BE2, DITHER: 0x0BD0, STENCIL_TEST: 0x0B90, DEPTH_TEST: 0x0B71, SCISSOR_TEST: 0x0C11, 
    POLYGON_OFFSET_FILL: 0x8037, SAMPLE_ALPHA_TO_COVERAGE: 0x809E, SAMPLE_COVERAGE: 0x80A0, NO_ERROR: 0, INVALID_ENUM: 0x0500, INVALID_VALUE: 0x0501, 
    INVALID_OPERATION: 0x0502, OUT_OF_MEMORY: 0x0505, CW: 0x0900, CCW: 0x0901, LINE_WIDTH: 0x0B21, ALIASED_POINT_SIZE_RANGE: 0x846D, 
    ALIASED_LINE_WIDTH_RANGE: 0x846E, CULL_FACE_MODE: 0x0B45, FRONT_FACE: 0x0B46, DEPTH_RANGE: 0x0B70, DEPTH_WRITEMASK: 0x0B72, DEPTH_CLEAR_VALUE: 
    0x0B73, DEPTH_FUNC: 0x0B74, STENCIL_CLEAR_VALUE: 0x0B91, STENCIL_FUNC: 0x0B92, STENCIL_FAIL: 0x0B94, STENCIL_PASS_DEPTH_FAIL: 0x0B95, 
    STENCIL_PASS_DEPTH_PASS: 0x0B96, STENCIL_REF: 0x0B97, STENCIL_VALUE_MASK: 0x0B93, STENCIL_WRITEMASK: 0x0B98, STENCIL_BACK_FUNC: 0x8800, 
    STENCIL_BACK_FAIL: 0x8801, STENCIL_BACK_PASS_DEPTH_FAIL: 0x8802, STENCIL_BACK_PASS_DEPTH_PASS: 0x8803, STENCIL_BACK_REF: 0x8CA3, 
    STENCIL_BACK_VALUE_MASK: 0x8CA4, STENCIL_BACK_WRITEMASK: 0x8CA5, VIEWPORT: 0x0BA2, SCISSOR_BOX: 0x0C10, COLOR_CLEAR_VALUE: 0x0C22, COLOR_WRITEMASK: 
    0x0C23, UNPACK_ALIGNMENT: 0x0CF5, PACK_ALIGNMENT: 0x0D05, MAX_TEXTURE_SIZE: 0x0D33, MAX_VIEWPORT_DIMS: 0x0D3A, SUBPIXEL_BITS: 0x0D50, RED_BITS: 
    0x0D52, GREEN_BITS: 0x0D53, BLUE_BITS: 0x0D54, ALPHA_BITS: 0x0D55, DEPTH_BITS: 0x0D56, STENCIL_BITS: 0x0D57, POLYGON_OFFSET_UNITS: 0x2A00, 
    POLYGON_OFFSET_FACTOR: 0x8038, TEXTURE_BINDING_2D: 0x8069, SAMPLE_BUFFERS: 0x80A8, SAMPLES: 0x80A9, SAMPLE_COVERAGE_VALUE: 0x80AA, 
    SAMPLE_COVERAGE_INVERT: 0x80AB, COMPRESSED_TEXTURE_FORMATS: 0x86A3, DONT_CARE: 0x1100, FASTEST: 0x1101, NICEST: 0x1102, GENERATE_MIPMAP_HINT: 0x8192, 
    BYTE: 0x1400, UNSIGNED_BYTE: 0x1401, SHORT: 0x1402, UNSIGNED_SHORT: 0x1403, INT: 0x1404, UNSIGNED_INT: 0x1405, FLOAT: 0x1406, DEPTH_COMPONENT: 
    0x1902, ALPHA: 0x1906, RGB: 0x1907, RGBA: 0x1908, LUMINANCE: 0x1909, LUMINANCE_ALPHA: 0x190A, UNSIGNED_SHORT_4_4_4_4: 0x8033, UNSIGNED_SHORT_5_5_5_1: 
    0x8034, UNSIGNED_SHORT_5_6_5: 0x8363, FRAGMENT_SHADER: 0x8B30, VERTEX_SHADER: 0x8B31, MAX_VERTEX_ATTRIBS: 0x8869, MAX_VERTEX_UNIFORM_VECTORS: 0x8DFB, 
    MAX_VARYING_VECTORS: 0x8DFC, MAX_COMBINED_TEXTURE_IMAGE_UNITS: 0x8B4D, MAX_VERTEX_TEXTURE_IMAGE_UNITS: 0x8B4C, MAX_TEXTURE_IMAGE_UNITS: 0x8872, 
    MAX_FRAGMENT_UNIFORM_VECTORS: 0x8DFD, SHADER_TYPE: 0x8B4F, DELETE_STATUS: 0x8B80, LINK_STATUS: 0x8B82, VALIDATE_STATUS: 0x8B83, ATTACHED_SHADERS: 
    0x8B85, ACTIVE_UNIFORMS: 0x8B86, ACTIVE_ATTRIBUTES: 0x8B89, SHADING_LANGUAGE_VERSION: 0x8B8C, CURRENT_PROGRAM: 0x8B8D, NEVER: 0x0200, LESS: 0x0201, 
    EQUAL: 0x0202, LEQUAL: 0x0203, GREATER: 0x0204, NOTEQUAL: 0x0205, GEQUAL: 0x0206, ALWAYS: 0x0207, KEEP: 0x1E00, REPLACE: 0x1E01, INCR: 0x1E02, DECR: 
    0x1E03, INVERT: 0x150A, INCR_WRAP: 0x8507, DECR_WRAP: 0x8508, VENDOR: 0x1F00, RENDERER: 0x1F01, VERSION: 0x1F02, NEAREST: 0x2600, LINEAR: 0x2601, 
    NEAREST_MIPMAP_NEAREST: 0x2700, LINEAR_MIPMAP_NEAREST: 0x2701, NEAREST_MIPMAP_LINEAR: 0x2702, LINEAR_MIPMAP_LINEAR: 0x2703, TEXTURE_MAG_FILTER: 
    0x2800, TEXTURE_MIN_FILTER: 0x2801, TEXTURE_WRAP_S: 0x2802, TEXTURE_WRAP_T: 0x2803, TEXTURE_2D: 0x0DE1, TEXTURE: 0x1702, TEXTURE_CUBE_MAP: 0x8513, 
    TEXTURE_BINDING_CUBE_MAP: 0x8514, TEXTURE_CUBE_MAP_POSITIVE_X: 0x8515, TEXTURE_CUBE_MAP_NEGATIVE_X: 0x8516, TEXTURE_CUBE_MAP_POSITIVE_Y: 0x8517, 
    TEXTURE_CUBE_MAP_NEGATIVE_Y: 0x8518, TEXTURE_CUBE_MAP_POSITIVE_Z: 0x8519, TEXTURE_CUBE_MAP_NEGATIVE_Z: 0x851A, MAX_CUBE_MAP_TEXTURE_SIZE: 0x851C, 
    TEXTURE0: 0x84C0, TEXTURE1: 0x84C1, TEXTURE2: 0x84C2, TEXTURE3: 0x84C3, TEXTURE4: 0x84C4, TEXTURE5: 0x84C5, TEXTURE6: 0x84C6, TEXTURE7: 0x84C7, 
    TEXTURE8: 0x84C8, TEXTURE9: 0x84C9, TEXTURE10: 0x84CA, TEXTURE11: 0x84CB, TEXTURE12: 0x84CC, TEXTURE13: 0x84CD, TEXTURE14: 0x84CE, TEXTURE15: 0x84CF, 
    TEXTURE16: 0x84D0, TEXTURE17: 0x84D1, TEXTURE18: 0x84D2, TEXTURE19: 0x84D3, TEXTURE20: 0x84D4, TEXTURE21: 0x84D5, TEXTURE22: 0x84D6, TEXTURE23: 
    0x84D7, TEXTURE24: 0x84D8, TEXTURE25: 0x84D9, TEXTURE26: 0x84DA, TEXTURE27: 0x84DB, TEXTURE28: 0x84DC, TEXTURE29: 0x84DD, TEXTURE30: 0x84DE, 
    TEXTURE31: 0x84DF, ACTIVE_TEXTURE: 0x84E0, REPEAT: 0x2901, CLAMP_TO_EDGE: 0x812F, MIRRORED_REPEAT: 0x8370, FLOAT_VEC2: 0x8B50, FLOAT_VEC3: 0x8B51, 
    FLOAT_VEC4: 0x8B52, INT_VEC2: 0x8B53, INT_VEC3: 0x8B54, INT_VEC4: 0x8B55, BOOL: 0x8B56, BOOL_VEC2: 0x8B57, BOOL_VEC3: 0x8B58, BOOL_VEC4: 0x8B59, 
    FLOAT_MAT2: 0x8B5A, FLOAT_MAT3: 0x8B5B, FLOAT_MAT4: 0x8B5C, SAMPLER_2D: 0x8B5E, SAMPLER_CUBE: 0x8B60, VERTEX_ATTRIB_ARRAY_ENABLED: 0x8622, 
    VERTEX_ATTRIB_ARRAY_SIZE: 0x8623, VERTEX_ATTRIB_ARRAY_STRIDE: 0x8624, VERTEX_ATTRIB_ARRAY_TYPE: 0x8625, VERTEX_ATTRIB_ARRAY_NORMALIZED: 0x886A, 
    VERTEX_ATTRIB_ARRAY_POINTER: 0x8645, VERTEX_ATTRIB_ARRAY_BUFFER_BINDING: 0x889F, IMPLEMENTATION_COLOR_READ_TYPE: 0x8B9A, 
    IMPLEMENTATION_COLOR_READ_FORMAT: 0x8B9B, COMPILE_STATUS: 0x8B81, LOW_FLOAT: 0x8DF0, MEDIUM_FLOAT: 0x8DF1, HIGH_FLOAT: 0x8DF2, LOW_INT: 0x8DF3, 
    MEDIUM_INT: 0x8DF4, HIGH_INT: 0x8DF5, FRAMEBUFFER: 0x8D40, RENDERBUFFER: 0x8D41, RGBA4: 0x8056, RGB5_A1: 0x8057, RGBA8: 0x8058, RGB565: 0x8D62, 
    DEPTH_COMPONENT16: 0x81A5, STENCIL_INDEX8: 0x8D48, DEPTH_STENCIL: 0x84F9, RENDERBUFFER_WIDTH: 0x8D42, RENDERBUFFER_HEIGHT: 0x8D43, 
    RENDERBUFFER_INTERNAL_FORMAT: 0x8D44, RENDERBUFFER_RED_SIZE: 0x8D50, RENDERBUFFER_GREEN_SIZE: 0x8D51, RENDERBUFFER_BLUE_SIZE: 0x8D52, 
    RENDERBUFFER_ALPHA_SIZE: 0x8D53, RENDERBUFFER_DEPTH_SIZE: 0x8D54, RENDERBUFFER_STENCIL_SIZE: 0x8D55, FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE: 0x8CD0, 
    FRAMEBUFFER_ATTACHMENT_OBJECT_NAME: 0x8CD1, FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL: 0x8CD2, FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE: 0x8CD3, 
    COLOR_ATTACHMENT0: 0x8CE0, DEPTH_ATTACHMENT: 0x8D00, STENCIL_ATTACHMENT: 0x8D20, DEPTH_STENCIL_ATTACHMENT: 0x821A, NONE: 0, FRAMEBUFFER_COMPLETE: 
    0x8CD5, FRAMEBUFFER_INCOMPLETE_ATTACHMENT: 0x8CD6, FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT: 0x8CD7, FRAMEBUFFER_INCOMPLETE_DIMENSIONS: 0x8CD9, 
    FRAMEBUFFER_UNSUPPORTED: 0x8CDD, FRAMEBUFFER_BINDING: 0x8CA6, RENDERBUFFER_BINDING: 0x8CA7, MAX_RENDERBUFFER_SIZE: 0x84E8, 
    INVALID_FRAMEBUFFER_OPERATION: 0x0506, UNPACK_FLIP_Y_WEBGL: 0x9240, UNPACK_PREMULTIPLY_ALPHA_WEBGL: 0x9241, CONTEXT_LOST_WEBGL: 0x9242, 
    UNPACK_COLORSPACE_CONVERSION_WEBGL: 0x9243, BROWSER_DEFAULT_WEBGL: 0x9244, 
  };
  const CONSTANTS2 = {
    READ_BUFFER: 0x0C02, UNPACK_ROW_LENGTH: 0x0CF2, UNPACK_SKIP_ROWS: 0x0CF3, UNPACK_SKIP_PIXELS: 0x0CF4, PACK_ROW_LENGTH: 0x0D02, PACK_SKIP_ROWS: 
    0x0D03, PACK_SKIP_PIXELS: 0x0D04, COLOR: 0x1800, DEPTH: 0x1801, STENCIL: 0x1802, RED: 0x1903, RGB8: 0x8051, RGB10_A2: 0x8059, TEXTURE_BINDING_3D: 
    0x806A, UNPACK_SKIP_IMAGES: 0x806D, UNPACK_IMAGE_HEIGHT: 0x806E, TEXTURE_3D: 0x806F, TEXTURE_WRAP_R: 0x8072, MAX_3D_TEXTURE_SIZE: 0x8073, 
    UNSIGNED_INT_2_10_10_10_REV: 0x8368, MAX_ELEMENTS_VERTICES: 0x80E8, MAX_ELEMENTS_INDICES: 0x80E9, TEXTURE_MIN_LOD: 0x813A, TEXTURE_MAX_LOD: 0x813B, 
    TEXTURE_BASE_LEVEL: 0x813C, TEXTURE_MAX_LEVEL: 0x813D, MIN: 0x8007, MAX: 0x8008, DEPTH_COMPONENT24: 0x81A6, MAX_TEXTURE_LOD_BIAS: 0x84FD, 
    TEXTURE_COMPARE_MODE: 0x884C, TEXTURE_COMPARE_FUNC: 0x884D, CURRENT_QUERY: 0x8865, QUERY_RESULT: 0x8866, QUERY_RESULT_AVAILABLE: 0x8867, STREAM_READ: 
    0x88E1, STREAM_COPY: 0x88E2, STATIC_READ: 0x88E5, STATIC_COPY: 0x88E6, DYNAMIC_READ: 0x88E9, DYNAMIC_COPY: 0x88EA, MAX_DRAW_BUFFERS: 0x8824, 
    DRAW_BUFFER0: 0x8825, DRAW_BUFFER1: 0x8826, DRAW_BUFFER2: 0x8827, DRAW_BUFFER3: 0x8828, DRAW_BUFFER4: 0x8829, DRAW_BUFFER5: 0x882A, DRAW_BUFFER6: 
    0x882B, DRAW_BUFFER7: 0x882C, DRAW_BUFFER8: 0x882D, DRAW_BUFFER9: 0x882E, DRAW_BUFFER10: 0x882F, DRAW_BUFFER11: 0x8830, DRAW_BUFFER12: 0x8831, 
    DRAW_BUFFER13: 0x8832, DRAW_BUFFER14: 0x8833, DRAW_BUFFER15: 0x8834, MAX_FRAGMENT_UNIFORM_COMPONENTS: 0x8B49, MAX_VERTEX_UNIFORM_COMPONENTS: 0x8B4A, 
    SAMPLER_3D: 0x8B5F, SAMPLER_2D_SHADOW: 0x8B62, FRAGMENT_SHADER_DERIVATIVE_HINT: 0x8B8B, PIXEL_PACK_BUFFER: 0x88EB, PIXEL_UNPACK_BUFFER: 0x88EC, 
    PIXEL_PACK_BUFFER_BINDING: 0x88ED, PIXEL_UNPACK_BUFFER_BINDING: 0x88EF, FLOAT_MAT2x3: 0x8B65, FLOAT_MAT2x4: 0x8B66, FLOAT_MAT3x2: 0x8B67, 
    FLOAT_MAT3x4: 0x8B68, FLOAT_MAT4x2: 0x8B69, FLOAT_MAT4x3: 0x8B6A, SRGB: 0x8C40, SRGB8: 0x8C41, SRGB8_ALPHA8: 0x8C43, COMPARE_REF_TO_TEXTURE: 0x884E, 
    RGBA32F: 0x8814, RGB32F: 0x8815, RGBA16F: 0x881A, RGB16F: 0x881B, VERTEX_ATTRIB_ARRAY_INTEGER: 0x88FD, MAX_ARRAY_TEXTURE_LAYERS: 0x88FF, 
    MIN_PROGRAM_TEXEL_OFFSET: 0x8904, MAX_PROGRAM_TEXEL_OFFSET: 0x8905, MAX_VARYING_COMPONENTS: 0x8B4B, TEXTURE_2D_ARRAY: 0x8C1A, 
    TEXTURE_BINDING_2D_ARRAY: 0x8C1D, R11F_G11F_B10F: 0x8C3A, UNSIGNED_INT_10F_11F_11F_REV: 0x8C3B, RGB9_E5: 0x8C3D, UNSIGNED_INT_5_9_9_9_REV: 0x8C3E, 
    TRANSFORM_FEEDBACK_BUFFER_MODE: 0x8C7F, MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS: 0x8C80, TRANSFORM_FEEDBACK_VARYINGS: 0x8C83, 
    TRANSFORM_FEEDBACK_BUFFER_START: 0x8C84, TRANSFORM_FEEDBACK_BUFFER_SIZE: 0x8C85, TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN: 0x8C88, RASTERIZER_DISCARD: 
    0x8C89, MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS: 0x8C8A, MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS: 0x8C8B, INTERLEAVED_ATTRIBS: 0x8C8C, 
    SEPARATE_ATTRIBS: 0x8C8D, TRANSFORM_FEEDBACK_BUFFER: 0x8C8E, TRANSFORM_FEEDBACK_BUFFER_BINDING: 0x8C8F, RGBA32UI: 0x8D70, RGB32UI: 0x8D71, RGBA16UI: 
    0x8D76, RGB16UI: 0x8D77, RGBA8UI: 0x8D7C, RGB8UI: 0x8D7D, RGBA32I: 0x8D82, RGB32I: 0x8D83, RGBA16I: 0x8D88, RGB16I: 0x8D89, RGBA8I: 0x8D8E, RGB8I: 
    0x8D8F, RED_INTEGER: 0x8D94, RGB_INTEGER: 0x8D98, RGBA_INTEGER: 0x8D99, SAMPLER_2D_ARRAY: 0x8DC1, SAMPLER_2D_ARRAY_SHADOW: 0x8DC4, 
    SAMPLER_CUBE_SHADOW: 0x8DC5, UNSIGNED_INT_VEC2: 0x8DC6, UNSIGNED_INT_VEC3: 0x8DC7, UNSIGNED_INT_VEC4: 0x8DC8, INT_SAMPLER_2D: 0x8DCA, INT_SAMPLER_3D: 
    0x8DCB, INT_SAMPLER_CUBE: 0x8DCC, INT_SAMPLER_2D_ARRAY: 0x8DCF, UNSIGNED_INT_SAMPLER_2D: 0x8DD2, UNSIGNED_INT_SAMPLER_3D: 0x8DD3, 
    UNSIGNED_INT_SAMPLER_CUBE: 0x8DD4, UNSIGNED_INT_SAMPLER_2D_ARRAY: 0x8DD7, DEPTH_COMPONENT32F: 0x8CAC, DEPTH32F_STENCIL8: 0x8CAD, 
    FLOAT_32_UNSIGNED_INT_24_8_REV: 0x8DAD, FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING: 0x8210, FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE: 0x8211, 
    FRAMEBUFFER_ATTACHMENT_RED_SIZE: 0x8212, FRAMEBUFFER_ATTACHMENT_GREEN_SIZE: 0x8213, FRAMEBUFFER_ATTACHMENT_BLUE_SIZE: 0x8214, 
    FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE: 0x8215, FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE: 0x8216, FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE: 0x8217, 
    FRAMEBUFFER_DEFAULT: 0x8218, UNSIGNED_INT_24_8: 0x84FA, DEPTH24_STENCIL8: 0x88F0, UNSIGNED_NORMALIZED: 0x8C17, DRAW_FRAMEBUFFER_BINDING: 0x8CA6, 
    READ_FRAMEBUFFER: 0x8CA8, DRAW_FRAMEBUFFER: 0x8CA9, READ_FRAMEBUFFER_BINDING: 0x8CAA, RENDERBUFFER_SAMPLES: 0x8CAB, 
    FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER: 0x8CD4, MAX_COLOR_ATTACHMENTS: 0x8CDF, COLOR_ATTACHMENT1: 0x8CE1, COLOR_ATTACHMENT2: 0x8CE2, COLOR_ATTACHMENT3: 
    0x8CE3, COLOR_ATTACHMENT4: 0x8CE4, COLOR_ATTACHMENT5: 0x8CE5, COLOR_ATTACHMENT6: 0x8CE6, COLOR_ATTACHMENT7: 0x8CE7, COLOR_ATTACHMENT8: 0x8CE8, 
    COLOR_ATTACHMENT9: 0x8CE9, COLOR_ATTACHMENT10: 0x8CEA, COLOR_ATTACHMENT11: 0x8CEB, COLOR_ATTACHMENT12: 0x8CEC, COLOR_ATTACHMENT13: 0x8CED, 
    COLOR_ATTACHMENT14: 0x8CEE, COLOR_ATTACHMENT15: 0x8CEF, FRAMEBUFFER_INCOMPLETE_MULTISAMPLE: 0x8D56, MAX_SAMPLES: 0x8D57, HALF_FLOAT: 0x140B, RG: 
    0x8227, RG_INTEGER: 0x8228, R8: 0x8229, RG8: 0x822B, R16F: 0x822D, R32F: 0x822E, RG16F: 0x822F, RG32F: 0x8230, R8I: 0x8231, R8UI: 0x8232, R16I: 
    0x8233, R16UI: 0x8234, R32I: 0x8235, R32UI: 0x8236, RG8I: 0x8237, RG8UI: 0x8238, RG16I: 0x8239, RG16UI: 0x823A, RG32I: 0x823B, RG32UI: 0x823C, 
    VERTEX_ARRAY_BINDING: 0x85B5, R8_SNORM: 0x8F94, RG8_SNORM: 0x8F95, RGB8_SNORM: 0x8F96, RGBA8_SNORM: 0x8F97, SIGNED_NORMALIZED: 0x8F9C, 
    COPY_READ_BUFFER: 0x8F36, COPY_WRITE_BUFFER: 0x8F37, COPY_READ_BUFFER_BINDING: 0x8F36, COPY_WRITE_BUFFER_BINDING: 0x8F37, UNIFORM_BUFFER: 0x8A11, 
    UNIFORM_BUFFER_BINDING: 0x8A28, UNIFORM_BUFFER_START: 0x8A29, UNIFORM_BUFFER_SIZE: 0x8A2A, MAX_VERTEX_UNIFORM_BLOCKS: 0x8A2B, 
    MAX_FRAGMENT_UNIFORM_BLOCKS: 0x8A2D, MAX_COMBINED_UNIFORM_BLOCKS: 0x8A2E, MAX_UNIFORM_BUFFER_BINDINGS: 0x8A2F, MAX_UNIFORM_BLOCK_SIZE: 0x8A30, 
    MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS: 0x8A31, MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS: 0x8A33, UNIFORM_BUFFER_OFFSET_ALIGNMENT: 0x8A34, 
    ACTIVE_UNIFORM_BLOCKS: 0x8A36, UNIFORM_TYPE: 0x8A37, UNIFORM_SIZE: 0x8A38, UNIFORM_BLOCK_INDEX: 0x8A3A, UNIFORM_OFFSET: 0x8A3B, UNIFORM_ARRAY_STRIDE: 
    0x8A3C, UNIFORM_MATRIX_STRIDE: 0x8A3D, UNIFORM_IS_ROW_MAJOR: 0x8A3E, UNIFORM_BLOCK_BINDING: 0x8A3F, UNIFORM_BLOCK_DATA_SIZE: 0x8A40, 
    UNIFORM_BLOCK_ACTIVE_UNIFORMS: 0x8A42, UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES: 0x8A43, UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER: 0x8A44, 
    UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER: 0x8A46, INVALID_INDEX: 0xFFFFFFFF, MAX_VERTEX_OUTPUT_COMPONENTS: 0x9122, MAX_FRAGMENT_INPUT_COMPONENTS: 
    0x9125, MAX_SERVER_WAIT_TIMEOUT: 0x9111, OBJECT_TYPE: 0x9112, SYNC_CONDITION: 0x9113, SYNC_STATUS: 0x9114, SYNC_FLAGS: 0x9115, SYNC_FENCE: 0x9116, 
    SYNC_GPU_COMMANDS_COMPLETE: 0x9117, UNSIGNALED: 0x9118, SIGNALED: 0x9119, ALREADY_SIGNALED: 0x911A, TIMEOUT_EXPIRED: 0x911B, CONDITION_SATISFIED: 
    0x911C, WAIT_FAILED: 0x911D, SYNC_FLUSH_COMMANDS_BIT: 0x00000001, VERTEX_ATTRIB_ARRAY_DIVISOR: 0x88FE, ANY_SAMPLES_PASSED: 0x8C2F, 
    ANY_SAMPLES_PASSED_CONSERVATIVE: 0x8D6A, SAMPLER_BINDING: 0x8919, RGB10_A2UI: 0x906F, INT_2_10_10_10_REV: 0x8D9F, TRANSFORM_FEEDBACK: 0x8E22, 
    TRANSFORM_FEEDBACK_PAUSED: 0x8E23, TRANSFORM_FEEDBACK_ACTIVE: 0x8E24, TRANSFORM_FEEDBACK_BINDING: 0x8E25, TEXTURE_IMMUTABLE_FORMAT: 0x912F, 
    MAX_ELEMENT_INDEX: 0x8D6B, TEXTURE_IMMUTABLE_LEVELS: 0x82DF, TIMEOUT_IGNORED: -1, MAX_CLIENT_WAIT_TIMEOUT_WEBGL: 0x9247, 
  };

  // The `length` of each operation of the IDL.
  const LENGTHS = {
    activeTexture: 1, attachShader: 2, beginQuery: 2, beginTransformFeedback: 1, bindAttribLocation: 3, bindBuffer: 2, bindBufferBase: 3,
    bindBufferRange: 5, bindFramebuffer: 2, bindRenderbuffer: 2, bindSampler: 2, bindTexture: 2, bindTransformFeedback: 2, bindVertexArray: 1,
    blendColor: 4, blendEquation: 1, blendEquationSeparate: 2, blendFunc: 2, blendFuncSeparate: 4, blitFramebuffer: 10, bufferData: 3, bufferSubData: 3,
    checkFramebufferStatus: 1, clear: 1, clearBufferfi: 4, clearBufferfv: 3, clearBufferiv: 3, clearBufferuiv: 3, clearColor: 4, clearDepth: 1,
    clearStencil: 1, clientWaitSync: 3, colorMask: 4, compileShader: 1, compressedTexImage2D: 7, compressedTexImage3D: 8, compressedTexSubImage2D: 8,
    compressedTexSubImage3D: 10, copyBufferSubData: 5, copyTexImage2D: 8, copyTexSubImage2D: 8, copyTexSubImage3D: 9, createBuffer: 0,
    createFramebuffer: 0, createProgram: 0, createQuery: 0, createRenderbuffer: 0, createSampler: 0, createShader: 1, createTexture: 0,
    createTransformFeedback: 0, createVertexArray: 0, cullFace: 1, deleteBuffer: 1, deleteFramebuffer: 1, deleteProgram: 1, deleteQuery: 1,
    deleteRenderbuffer: 1, deleteSampler: 1, deleteShader: 1, deleteSync: 1, deleteTexture: 1, deleteTransformFeedback: 1, deleteVertexArray: 1,
    depthFunc: 1, depthMask: 1, depthRange: 2, detachShader: 2, disable: 1, disableVertexAttribArray: 1, drawArrays: 3, drawArraysInstanced: 4,
    drawBuffers: 1, drawElements: 4, drawElementsInstanced: 5, drawRangeElements: 6, drawingBufferStorage: 3, enable: 1, enableVertexAttribArray: 1,
    endQuery: 1, endTransformFeedback: 0, fenceSync: 2, finish: 0, flush: 0, framebufferRenderbuffer: 4, framebufferTexture2D: 5,
    framebufferTextureLayer: 5, frontFace: 1, generateMipmap: 1, getActiveAttrib: 2, getActiveUniform: 2, getActiveUniformBlockName: 2,
    getActiveUniformBlockParameter: 3, getActiveUniforms: 3, getAttachedShaders: 1, getAttribLocation: 2, getBufferParameter: 2, getBufferSubData: 3,
    getContextAttributes: 0, getError: 0, getExtension: 1, getFragDataLocation: 2, getFramebufferAttachmentParameter: 3, getIndexedParameter: 2,
    getInternalformatParameter: 3, getParameter: 1, getProgramInfoLog: 1, getProgramParameter: 2, getQuery: 2, getQueryParameter: 2,
    getRenderbufferParameter: 2, getSamplerParameter: 2, getShaderInfoLog: 1, getShaderParameter: 2, getShaderPrecisionFormat: 2, getShaderSource: 1,
    getSupportedExtensions: 0, getSyncParameter: 2, getTexParameter: 2, getTransformFeedbackVarying: 2, getUniform: 2, getUniformBlockIndex: 2,
    getUniformIndices: 2, getUniformLocation: 2, getVertexAttrib: 2, getVertexAttribOffset: 2, hint: 2, invalidateFramebuffer: 2,
    invalidateSubFramebuffer: 6, isBuffer: 1, isContextLost: 0, isEnabled: 1, isFramebuffer: 1, isProgram: 1, isQuery: 1, isRenderbuffer: 1, isSampler: 1,
    isShader: 1, isSync: 1, isTexture: 1, isTransformFeedback: 1, isVertexArray: 1, lineWidth: 1, linkProgram: 1, pauseTransformFeedback: 0,
    pixelStorei: 2, polygonOffset: 2, readBuffer: 1, readPixels: 7, renderbufferStorage: 4, renderbufferStorageMultisample: 5, resumeTransformFeedback: 0,
    sampleCoverage: 2, samplerParameterf: 3, samplerParameteri: 3, scissor: 4, shaderSource: 2, stencilFunc: 3, stencilFuncSeparate: 4, stencilMask: 1,
    stencilMaskSeparate: 2, stencilOp: 3, stencilOpSeparate: 4, texImage2D: 6, texImage3D: 10, texParameterf: 3, texParameteri: 3, texStorage2D: 5,
    texStorage3D: 6, texSubImage2D: 7, texSubImage3D: 11, transformFeedbackVaryings: 3, uniform1f: 2, uniform1fv: 2, uniform1i: 2, uniform1iv: 2,
    uniform1ui: 2, uniform1uiv: 2, uniform2f: 3, uniform2fv: 2, uniform2i: 3, uniform2iv: 2, uniform2ui: 3, uniform2uiv: 2, uniform3f: 4, uniform3fv: 2,
    uniform3i: 4, uniform3iv: 2, uniform3ui: 4, uniform3uiv: 2, uniform4f: 5, uniform4fv: 2, uniform4i: 5, uniform4iv: 2, uniform4ui: 5, uniform4uiv: 2,
    uniformBlockBinding: 3, uniformMatrix2fv: 3, uniformMatrix2x3fv: 3, uniformMatrix2x4fv: 3, uniformMatrix3fv: 3, uniformMatrix3x2fv: 3,
    uniformMatrix3x4fv: 3, uniformMatrix4fv: 3, uniformMatrix4x2fv: 3, uniformMatrix4x3fv: 3, useProgram: 1, validateProgram: 1, vertexAttrib1f: 2,
    vertexAttrib1fv: 2, vertexAttrib2f: 3, vertexAttrib2fv: 2, vertexAttrib3f: 4, vertexAttrib3fv: 2, vertexAttrib4f: 5, vertexAttrib4fv: 2,
    vertexAttribDivisor: 2, vertexAttribI4i: 5, vertexAttribI4iv: 2, vertexAttribI4ui: 5, vertexAttribI4uiv: 2, vertexAttribIPointer: 5,
    vertexAttribPointer: 6, viewport: 4, waitSync: 3
  };

  const OBJECT_NAMES = ["WebGLBuffer", "WebGLFramebuffer", "WebGLProgram", "WebGLRenderbuffer", "WebGLShader", "WebGLTexture"];
  const OBJECT2_NAMES = ["WebGLQuery", "WebGLSampler", "WebGLSync", "WebGLTransformFeedback", "WebGLVertexArrayObject"];

  // ---- the interfaces with no constructor ----
  const illegal = () => { throw new TE("Illegal constructor"); };
  const tagged = (cls, name) => {
    defineProperty(cls.prototype, Symbol.toStringTag, { value: name, configurable: true });
    defineProperty(cls, "name", { value: name, configurable: true });
    return cls;
  };
  const WebGLObject = tagged(class { constructor() { if (arguments[0] !== TOKEN) illegal(); } }, "WebGLObject");
  const classes = { WebGLObject };
  const makeClass = name => {
    const c = tagged(class extends WebGLObject { constructor() { super(arguments[0]); } }, name);
    classes[name] = c;
    global[name] = c;
    return c;
  };
  const makeIface = (name, members) => {
    const c = tagged(class { constructor() { if (arguments[0] !== TOKEN) illegal(); } }, name);
    for (const m of members) {
      const get = function () { const v = this[S]; if (v === undefined) throw new TE("Illegal invocation"); return v[m]; };
      defineProperty(get, "name", { value: "get " + m, configurable: true });
      defineProperty(c.prototype, m, { get, enumerable: true, configurable: true });
    }
    classes[name] = c;
    return c;
  };
  for (const n of OBJECT_NAMES.concat(OBJECT2_NAMES)) makeClass(n);
  const Location = makeIface("WebGLUniformLocation", []);
  const ActiveInfo = makeIface("WebGLActiveInfo", ["size", "type", "name"]);
  const PrecisionFormat = makeIface("WebGLShaderPrecisionFormat", ["rangeMin", "rangeMax", "precision"]);
  const { WebGLBuffer, WebGLFramebuffer, WebGLProgram, WebGLRenderbuffer, WebGLShader, WebGLTexture, WebGLQuery, WebGLSampler, WebGLSync, WebGLTransformFeedback, WebGLVertexArrayObject } = classes;

  class WebGLContextEvent extends Ev {
    #message;
    constructor(type, init) {
      if (arguments.length < 1) throw new TE("WebGLContextEvent needs a type");
      super(type, init);
      const m = init !== undefined && init !== null ? init.statusMessage : undefined;
      this.#message = m === undefined ? "" : String(m);
    }
    get statusMessage() { return this.#message; }
  }
  defineProperty(WebGLContextEvent.prototype, Symbol.toStringTag, { value: "WebGLContextEvent", configurable: true });

  // ---- a context's state ----
  class State {
    constructor(ref, webgl2, canvas, attrs, info) {
      this.ref = ref;
      this.webgl2 = webgl2;
      this.canvas = canvas;
      this.attrs = attrs;
      this.info = info;
      this.buffer = new AB(COMMAND_WORDS * 4);
      this.w = new I32(this.buffer);
      this.f = new F32(this.buffer);
      this.b = new U8(this.buffer);
      this.n = 0;
      this.reply = new AB(REPLY_BYTES);
      this.rw = new I32(this.reply);
      this.rf = new F32(this.reply);
      this.ru = new U32(this.reply);
      this.rb = new U8(this.reply);
      this.scheduled = false;
      this.drew = false;
      this.lost = false;
      this.lostError = false;
      this.generation = 1;
      this.nextId = 1;
      this.objects = new MapC();
      this.queries = [null, null];   // the active queries: of samples, of primitives
      this.exts = new MapC();
      this.program = null;
      this.programLink = 0;
      this.preventedRestore = false;
      this.limit = 0;
      this.flushNow = () => { this.scheduled = false; this.limit = 0; flush(this); };
    }
  }

  const flush = s => {
    if (s.n === 0 && !s.drew) return;
    const drew = s.drew;
    native.submit(s.ref, s.buffer, s.n, drew);
    s.n = 0;
    s.drew = false;
  };

  // Commands wait for the end of the task (or the next thing that must wait for the device).
  // (each call looks at s.limit alone: 0 until something is scheduled, then the point where the buffer is flushed)
  const later = s => {
    if (!s.scheduled) {
      s.scheduled = true;
      s.limit = FLUSH_AT;
      microtask(s.flushNow);
    }
    if (s.n >= FLUSH_AT) flush(s);
  };

  // Room for a command with a variable part of `words`.
  const room = (s, words) => {
    if (s.n + words + 64 >= COMMAND_WORDS) {
      flush(s);
      if (words + 64 >= COMMAND_WORDS) return false;
    }
    return true;
  };

  const the = o => {
    const s = o === null || o === undefined ? undefined : o[S];
    if (s === undefined || s.w === undefined) throw new TE("Illegal invocation");
    return s;
  };

  // An error of the realm's rules: it takes its place among the device's, in order.
  const fail = (s, code) => {
    s.w[s.n] = OP.ERROR;
    s.w[s.n + 1] = code;
    s.n += 2;
    if (s.n >= s.limit) later(s);
  };

  const op0 = (name, op) => function () { const s = this[S]; if (s.lost) return; s.w[s.n] = op; s.n += 1; if (s.n >= s.limit) later(s); };
  const op1 = op => function (a) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = op; w[n + 1] = a; s.n = n + 2; if (s.n >= s.limit) later(s); };
  const op2 = op => function (a, b) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = op; w[n + 1] = a; w[n + 2] = b; s.n = n + 3; if (s.n >= s.limit) later(s); };
  const op4 = op => function (a, b, c, d) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = op; w[n + 1] = a; w[n + 2] = b; w[n + 3] = c; w[n + 4] = d; s.n = n + 5; if (s.n >= s.limit) later(s); };
  const opf1 = op => function (a) { const s = this[S]; if (s.lost) return; const n = s.n; s.w[n] = op; s.f[n + 1] = a; s.n = n + 2; if (s.n >= s.limit) later(s); };
  const opf2 = op => function (a, b) { const s = this[S]; if (s.lost) return; const n = s.n, f = s.f; s.w[n] = op; f[n + 1] = a; f[n + 2] = b; s.n = n + 3; if (s.n >= s.limit) later(s); };
  const opf4 = op => function (a, b, c, d) { const s = this[S]; if (s.lost) return; const n = s.n, f = s.f; s.w[n] = op; f[n + 1] = a; f[n + 2] = b; f[n + 3] = c; f[n + 4] = d; s.n = n + 5; if (s.n >= s.limit) later(s); };

  // What is asked and waited for. Words first; a string or nothing after. The answer lies in s.reply.
  const ask = (s, words, text) => {
    flush(s);
    const w = s.w;
    for (let i = 0; i < words.length; i++) w[i] = words[i];
    let n = words.length;
    let r;
    if (text !== undefined) r = native.queryText(s.ref, s.buffer, n, text, s.reply);
    else r = native.query(s.ref, s.buffer, n, s.reply);
    if (r < 0) { checkLost(s); return -1; }
    if (r > REPLY_BYTES) {
      // too large for the buffer of answers: a larger one, once
      s.reply = new AB(r);
      s.rw = new I32(s.reply);
      s.rf = new F32(s.reply);
      s.ru = new U32(s.reply);
      s.rb = new U8(s.reply);
      r = text !== undefined ? native.queryText(s.ref, s.buffer, n, text, s.reply) : native.query(s.ref, s.buffer, n, s.reply);
    }
    return r;
  };

  const objectOf = (s, id) => {
    const o = s.objects.get(id);
    return o === undefined ? null : o;
  };

  // The value in the answer.
  const value = s => {
    const w = s.rw, f = s.rf, u = s.ru;
    switch (w[0]) {
      case TAG.NULL: return null;
      case TAG.INT: return w[1];
      case TAG.UINT: return u[1];
      case TAG.FLOAT: return f[1];
      case TAG.BOOL: return w[1] !== 0;
      case TAG.INTS: return new I32(s.reply.slice(8, 8 + w[1] * 4));
      case TAG.UINTS: return new U32(s.reply.slice(8, 8 + w[1] * 4));
      case TAG.FLOATS: return new F32(s.reply.slice(8, 8 + w[1] * 4));
      case TAG.BOOLS: { const r = []; for (let i = 0; i < w[1]; i++) r.push(w[2 + i] !== 0); return r; }
      case TAG.STRING: return utf8.decode(new U8(s.reply, 8, w[1]));
      case TAG.OBJECT: return objectOf(s, w[2]);
    }
    return null;
  };

  const ifAlive = (s, words, text, otherwise) => {
    if (s.lost) return otherwise;
    return ask(s, words, text) < 0 ? otherwise : value(s);
  };

  // ---- objects ----
  const newObject = (s, cls) => {
    const o = new cls(TOKEN);
    const id = s.nextId++;
    o[S] = { ctx: s, id, generation: s.generation, deleted: false, bound: false };
    s.objects.set(id, o);
    return o;
  };

  // The id of an argument of this class: 0 for null. Undefined: refused (the error is set).
  const idOf = (s, o, cls) => {
    if (o === null || o === undefined) return 0;
    if (!(o instanceof cls)) throw new TE("The argument is not a " + cls.name);
    const m = o[S];
    if (m.ctx !== s || m.generation !== s.generation) { fail(s, INVALID_OPERATION); return undefined; }
    if (m.deleted) { fail(s, INVALID_OPERATION); return undefined; }
    return m.id;
  };

  const required = (o, cls) => {
    if (!(o instanceof cls)) throw new TE("The argument is not a " + cls.name);
  };

  const deleter = (cls, op) => function (o) {
    const s = this[S];
    if (s.lost || o === null || o === undefined) return;
    if (!(o instanceof cls)) throw new TE("The argument is not a " + cls.name);
    const m = o[S];
    if (m.ctx !== s || m.generation !== s.generation) { fail(s, INVALID_OPERATION); return; }
    if (m.deleted) return;
    m.deleted = true;
    s.objects.delete(m.id);
    const w = s.w, n = s.n;
    w[n] = op;
    w[n + 1] = m.id;
    s.n = n + 2;
    if (s.n >= s.limit) later(s);
  };

  const isObject = cls => function (o) {
    const s = this[S];
    if (s.lost || o === null || o === undefined) return false;
    if (!(o instanceof cls)) throw new TE("The argument is not a " + cls.name);
    const m = o[S];
    return m.ctx === s && m.generation === s.generation && !m.deleted && m.bound;
  };

  const creator = cls => function () {
    const s = this[S];
    if (s.lost) return null;
    return newObject(s, cls);
  };

  const binder = (cls, op) => function (target, o) {
    const s = this[S];
    if (s.lost) return;
    const id = idOf(s, o, cls);
    if (id === undefined) return;
    if (id !== 0) o[S].bound = true;
    const w = s.w, n = s.n;
    w[n] = op;
    w[n + 1] = target;
    w[n + 2] = id;
    s.n = n + 3;
    if (s.n >= s.limit) later(s);
  };

  // ---- data ----
  // The bytes of a view: a whole buffer, or (WebGL 2) from an offset of elements for a length of elements.
  const viewBytes = (view, offset, length) => {
    if (offset === 0 && length === 0) return new U8(view.buffer, view.byteOffset, view.byteLength);
    const size = view.BYTES_PER_ELEMENT || 1;
    const count = view.byteLength / size;
    offset = offset >>> 0;
    if (offset > count) return null;
    const n = length === 0 ? count - offset : length >>> 0;
    if (offset + n > count) return null;
    return new U8(view.buffer, view.byteOffset + offset * size, n * size);
  };

  const sendWith = (s, data) => { native.submitData(s.ref, s.buffer, s.n, data); s.n = 0; };

  const bufferData = function (target, data, usage, srcOffset, length) {
    const s = this[S];
    if (s.lost) return;
    flush(s);
    const w = s.w;
    w[0] = OP.BUFFER_DATA;
    w[1] = target;
    w[2] = usage;
    if (typeof data === "number") {
      const size = Math.trunc(data);
      if (size < 0) return fail(s, INVALID_VALUE);
      if (size > MAX_BUFFER_BYTES) return fail(s, OUT_OF_MEMORY);
      w[3] = size; w[4] = 0; w[5] = 0;
      s.n = 6;
      return flush(s);
    }
    if (data === null || data === undefined) return fail(s, INVALID_VALUE);
    let bytes;
    if (data instanceof AB) bytes = new U8(data);
    else if (isView(data)) bytes = srcOffset === undefined ? new U8(data.buffer, data.byteOffset, data.byteLength) : viewBytes(data, srcOffset >>> 0, (length || 0) >>> 0);
    else if (typeof data === "object" && typeof data.byteLength === "number") bytes = new U8(data);
    else { w[3] = Math.trunc(Number(data)) >>> 0; w[4] = 0; w[5] = 0; s.n = 6; return flush(s); }
    if (bytes === null) return fail(s, INVALID_VALUE);
    w[3] = 0; w[4] = 1; w[5] = bytes.length;
    s.n = 6;
    sendWith(s, bytes);
  };

  const bufferSubData = function (target, offset, data, srcOffset, length) {
    const s = this[S];
    if (s.lost) return;
    if (data === null || data === undefined) return fail(s, INVALID_VALUE);
    let bytes;
    if (data instanceof AB) bytes = new U8(data);
    else if (isView(data)) bytes = srcOffset === undefined ? new U8(data.buffer, data.byteOffset, data.byteLength) : viewBytes(data, srcOffset >>> 0, (length || 0) >>> 0);
    else throw new TE("bufferSubData: not a buffer");
    if (bytes === null) return fail(s, INVALID_VALUE);
    if (offset < 0) return fail(s, INVALID_VALUE);
    flush(s);
    const w = s.w;
    w[0] = OP.BUFFER_SUB_DATA;
    w[1] = target;
    w[2] = offset;
    w[3] = bytes.length;
    s.n = 4;
    sendWith(s, bytes);
  };

  // A string for the device (a shader's source, a name).
  const withText = (s, text) => { native.submitText(s.ref, s.buffer, s.n, text); s.n = 0; };

  const tryUniform = (s, loc) => {
    // the location of a program in use, for its last link
    const m = loc[S];
    if (m.program !== s.program || m.link !== s.programLink) { fail(s, INVALID_OPERATION); return false; }
    return true;
  };

  // uniform1f and friends. kind: components, with (1 << 4) int, (2 << 4) uint.
  const uf = (count, base) => function (loc, a, b, c, d) {
    const s = this[S];
    if (s.lost || loc === null || loc === undefined) return;
    // (one object looked at once: this runs thousands of times a frame)
    const m = loc[S];
    if (m === undefined || m.value === undefined) throw new TE("The argument is not a WebGLUniformLocation");
    if (m.program !== s.program || m.link !== s.programLink) return fail(s, INVALID_OPERATION);
    const w = s.w, n = s.n;
    w[n] = OP_UNIFORM;
    w[n + 1] = m.value;
    w[n + 2] = count | (base << 4);
    w[n + 3] = 1;
    w[n + 4] = count * 4;
    if (base === 0) {
      const f = s.f;
      f[n + 5] = a;
      if (count > 1) f[n + 6] = b;
      if (count > 2) f[n + 7] = c;
      if (count > 3) f[n + 8] = d;
    } else {
      w[n + 5] = a;
      if (count > 1) w[n + 6] = b;
      if (count > 2) w[n + 7] = c;
      if (count > 3) w[n + 8] = d;
    }
    s.n = n + 5 + count;
    if (s.n >= s.limit) later(s);
  };

  const isSequence = v => isView(v) || isArray(v) || (v !== null && typeof v === "object" && typeof v[Symbol.iterator] === "function");

  // A sequence of numbers as a typed array of what the device reads.
  const numbers = (v, Type) => {
    if (v instanceof Type) return v;
    if (!isSequence(v)) throw new TE("The argument is not a sequence of numbers");
    return new Type(v);
  };

  const put = (s, n, data, Type) => {
    if (Type === F32) s.f.set(data, n);
    else s.w.set(data, n);
  };

  const uv = (count, base, Type) => function (loc, v, srcOffset, srcLength) {
    const s = this[S];
    if (s.lost) return;
    if (loc === null || loc === undefined) return;
    if (!(loc instanceof Location)) throw new TE("The argument is not a WebGLUniformLocation");
    if (!tryUniform(s, loc)) return;
    let data = numbers(v, Type);
    if (srcOffset !== undefined || srcLength !== undefined) {
      const o = srcOffset >>> 0, l = srcLength >>> 0;
      if (o > data.length || (l !== 0 && o + l > data.length)) return fail(s, INVALID_VALUE);
      data = data.subarray(o, l === 0 ? data.length : o + l);
    }
    const len = data.length;
    if (len === 0 || len % count !== 0) return fail(s, INVALID_VALUE);
    if (!room(s, len + 8)) return fail(s, INVALID_VALUE);
    const w = s.w, n = s.n;
    w[n] = OP.UNIFORM;
    w[n + 1] = loc[S].value;
    w[n + 2] = count | (base << 4);
    w[n + 3] = len / count;
    w[n + 4] = len * 4;
    put(s, n + 5, data, Type);
    s.n = n + 5 + len;
    if (s.n >= s.limit) later(s);
  };

  const um = (cols, rows) => function (loc, transpose, v, srcOffset, srcLength) {
    const s = this[S];
    if (s.lost) return;
    if (loc === null || loc === undefined) return;
    if (!(loc instanceof Location)) throw new TE("The argument is not a WebGLUniformLocation");
    if (!tryUniform(s, loc)) return;
    if (transpose && !s.webgl2) return fail(s, INVALID_VALUE);
    let data = numbers(v, F32);
    if (srcOffset !== undefined || srcLength !== undefined) {
      const o = srcOffset >>> 0, l = srcLength >>> 0;
      if (o > data.length || (l !== 0 && o + l > data.length)) return fail(s, INVALID_VALUE);
      data = data.subarray(o, l === 0 ? data.length : o + l);
    }
    const each = cols * rows, len = data.length;
    if (len === 0 || len % each !== 0) return fail(s, INVALID_VALUE);
    if (!room(s, len + 8)) return fail(s, INVALID_VALUE);
    const w = s.w, n = s.n;
    w[n] = OP.UNIFORM;
    w[n + 1] = loc[S].value;
    w[n + 2] = 0x100 | (cols << 4) | rows;
    w[n + 3] = len / each;
    w[n + 4] = len * 4;
    if (transpose) {
      const f = s.f;
      for (let i = 0, at = n + 5; i < len; i += each) {
        for (let c = 0; c < cols; c++) for (let r = 0; r < rows; r++) f[at++] = data[i + r * cols + c];
      }
    } else {
      s.f.set(data, n + 5);
    }
    s.n = n + 5 + len;
    if (s.n >= s.limit) later(s);
  };

  // vertexAttrib1f and friends.
  const vaf = count => function (i, a, b, c, d) {
    const s = this[S];
    if (s.lost) return;
    const n = s.n, w = s.w, f = s.f;
    w[n] = OP.VERTEX_ATTRIB; w[n + 1] = i; w[n + 2] = 0;
    f[n + 3] = a;
    f[n + 4] = count > 1 ? b : 0;
    f[n + 5] = count > 2 ? c : 0;
    f[n + 6] = count > 3 ? d : 1;
    s.n = n + 7;
    if (s.n >= s.limit) later(s);
  };
  const vav = count => function (i, v) {
    const data = numbers(v, F32);
    const s = this[S];
    if (s.lost) return;
    if (data.length < count) return fail(s, INVALID_VALUE);
    const n = s.n, w = s.w, f = s.f;
    w[n] = OP.VERTEX_ATTRIB; w[n + 1] = i; w[n + 2] = 0;
    f[n + 3] = data[0];
    f[n + 4] = count > 1 ? data[1] : 0;
    f[n + 5] = count > 2 ? data[2] : 0;
    f[n + 6] = count > 3 ? data[3] : 1;
    s.n = n + 7;
    if (s.n >= s.limit) later(s);
  };

  // ---- textures ----
  // Is this one of the things texImage2D reads as an image? (null: no.)
  const isTexSource = v => v !== null && typeof v === "object" && !isView(v) && !(v instanceof AB);

  // A texture image from typed data (or nothing, or a pixel unpack buffer's offset).
  const texImage = (s, target, level, internal, w, h, d, border, format, type, data, is3d, srcOffset) => {
    const c = s.w;
    flush(s);
    c[0] = OP.TEX_IMAGE; c[1] = target; c[2] = level; c[3] = internal; c[4] = w; c[5] = h; c[6] = d; c[7] = border; c[8] = format; c[9] = type;
    c[11] = is3d ? 1 : 0;
    if (typeof data === "number") {
      // an offset into PIXEL_UNPACK_BUFFER
      c[10] = 2; c[12] = data; c[13] = 0;
      s.n = 14;
      return flush(s);
    }
    if (data === null || data === undefined) {
      c[10] = 0; c[12] = 0; c[13] = 0;
      s.n = 14;
      return flush(s);
    }
    if (!isView(data)) throw new TE("The pixels are not an ArrayBufferView");
    if (data.getFloat32) return fail(s, INVALID_OPERATION);
    const bytes = srcOffset ? viewBytes(data, srcOffset >>> 0, 0) : new U8(data.buffer, data.byteOffset, data.byteLength);
    if (bytes === null) return fail(s, INVALID_OPERATION);
    c[10] = 1; c[12] = 0; c[13] = bytes.length;
    s.n = 14;
    sendWith(s, bytes);
  };

  const texSubImage = (s, target, level, x, y, z, w, h, d, format, type, data, is3d, srcOffset) => {
    const c = s.w;
    flush(s);
    c[0] = OP.TEX_SUB_IMAGE; c[1] = target; c[2] = level; c[3] = x; c[4] = y; c[5] = z; c[6] = w; c[7] = h; c[8] = d; c[9] = format; c[10] = type; c[11] = is3d ? 1 : 0;
    if (typeof data === "number") {
      c[12] = 2; c[13] = data; c[14] = 0;
      s.n = 15;
      return flush(s);
    }
    if (data === null || data === undefined) {
      c[12] = 0; c[13] = 0; c[14] = 0;
      s.n = 15;
      return flush(s);
    }
    if (!isView(data)) throw new TE("The pixels are not an ArrayBufferView");
    const bytes = srcOffset ? viewBytes(data, srcOffset >>> 0, 0) : new U8(data.buffer, data.byteOffset, data.byteLength);
    if (bytes === null) return fail(s, INVALID_OPERATION);
    c[12] = 1; c[13] = 0; c[14] = bytes.length;
    s.n = 15;
    sendWith(s, bytes);
  };

  // An image: the browser reads its pixels and adds them to the command. A cross-origin image throws SecurityError.
  const texSource = (s, target, level, internal, format, type, source, sub, x, y, z) => {
    if (source instanceof ImageDataC) {
      flush(s);
      const c = s.w;
      c[0] = OP.TEX_IMAGE_SOURCE; c[1] = source.width; c[2] = source.height; c[3] = 0; c[4] = target; c[5] = level; c[6] = internal; c[7] = format; c[8] = type; c[9] = sub ? 1 : 0; c[10] = x; c[11] = y; c[12] = z;
      const data = source.data;
      c[13] = data.byteLength;
      s.n = 14;
      return sendWith(s, new U8(data.buffer, data.byteOffset, data.byteLength));
    }
    syncCanvas(source);
    flush(s);
    const c = s.w;
    c[0] = OP.TEX_IMAGE_SOURCE; c[1] = 0; c[2] = 0; c[3] = 0; c[4] = target; c[5] = level; c[6] = internal; c[7] = format; c[8] = type; c[9] = sub ? 1 : 0; c[10] = x; c[11] = y; c[12] = z;
    s.n = 0;   // (the command is not left in the buffer: this may throw)
    const r = native.upload(s.ref, s.buffer, SOURCE_COMMAND_WORDS, source);
    if (r === 1) fail(s, INVALID_VALUE);
  };

  const texImage2D = function (target, level, internal, a, b, c, d, e, f, g) {
    const s = this[S];
    if (s.lost) return;
    const n = arguments.length;
    if (n === 6) {
      // (target, level, internal, format, type, source)
      if (!isTexSource(c)) throw new TE("The source is not an image");
      return texSource(s, target, level, internal, a, b, c, false, 0, 0, 0);
    }
    if (n < 9 && n !== 6) throw new TE("texImage2D: wrong number of arguments");
    // (target, level, internal, width, height, border, format, type, pixels[, srcOffset])
    if (isTexSource(f) && s.webgl2) {
      return texSourceSized(s, target, level, internal, a, b, c, d, e, f);
    }
    texImage(s, target, level, internal, a, b, 1, c, d, e, f, false, n > 9 ? g : 0);
  };

  // WebGL 2's texImage2D(target, level, internal, width, height, border, format, type, source): the size says what is expected of the source.
  const texSourceSized = (s, target, level, internal, w, h, border, format, type, source) => {
    if (border !== 0) return fail(s, INVALID_VALUE);
    texSource(s, target, level, internal, format, type, source, false, 0, 0, 0);
  };

  const texSubImage2D = function (target, level, x, y, a, b, c, d, e, f) {
    const s = this[S];
    if (s.lost) return;
    const n = arguments.length;
    if (n === 7) {
      // (target, level, x, y, format, type, source)
      if (!isTexSource(c)) throw new TE("The source is not an image");
      return texSource(s, target, level, 0, a, b, c, true, x, y, 0);
    }
    if (n < 9) throw new TE("texSubImage2D: wrong number of arguments");
    if (isTexSource(e) && s.webgl2) return texSource(s, target, level, 0, c, d, e, true, x, y, 0);
    texSubImage(s, target, level, x, y, 0, a, b, 1, c, d, e, false, n > 9 ? f : 0);
  };

  // ---- getContext ----
  const contextOf = new WeakMapC();

  const attributes = (o, s) => {
    const get = (name, dflt) => {
      if (o === null || o === undefined || typeof o !== "object") return dflt;
      const v = o[name];
      return v === undefined ? dflt : !!v;
    };
    let power = "default";
    if (o !== null && typeof o === "object") {
      const p = o.powerPreference;
      if (p === "low-power" || p === "high-performance") power = p;
    }
    return {
      alpha: get("alpha", true), depth: get("depth", true), stencil: get("stencil", false), antialias: get("antialias", true),
      premultipliedAlpha: get("premultipliedAlpha", true), preserveDrawingBuffer: get("preserveDrawingBuffer", false), powerPreference: power,
      failIfMajorPerformanceCaveat: get("failIfMajorPerformanceCaveat", false), desynchronized: false, xrCompatible: false,
    };
  };

  const fire = (target, type, message, cancelable) => {
    const e = new WebGLContextEvent(type, { statusMessage: message, cancelable: !!cancelable, bubbles: false });
    apply(dispatch, target, [e]);
    return e;
  };
  const apply = Reflect.apply;

  const users = new MapC();   // the number the browser's news come with -> the context's state
  let nextUser = 1;

  const getContext = (canvas, kind, options) => {
    const known = contextOf.get(canvas);
    const webgl2 = kind === "webgl2";
    if (known !== undefined) return known[S].webgl2 === webgl2 ? known : null;
    const a = attributes(options);
    const offscreen = Offscreen !== undefined && canvas instanceof Offscreen;
    const info = new I32(INFO_WORDS);
    const user = nextUser++;
    const ref = native.create(canvas, offscreen, webgl2, a.alpha, a.depth, a.stencil, a.antialias, a.premultipliedAlpha, a.preserveDrawingBuffer, a.failIfMajorPerformanceCaveat, user, info);
    if (ref === null) {
      const message = native.createError();
      if (message !== "") fire(canvas, "webglcontextcreationerror", message, true);
      return null;
    }
    const s = new State(ref, webgl2, canvas, a, info);
    s.user = user;
    users.set(user, s);
    a.antialias = a.antialias && info[1] !== 0;
    const gl = new (webgl2 ? WebGL2RenderingContext : WebGLRenderingContext)(TOKEN);
    gl[S] = s;
    s.gl = gl;
    contextOf.set(canvas, gl);
    return gl;
  };

  // The browser's news: 1 the context was lost.
  const notify = (user, kind) => {
    const s = users.get(user);
    if (s === undefined) return;
    if (kind === 1) contextLost(s);
  };

  const markLost = s => {
    s.lost = true;
    s.lostError = true;
    s.n = 0;
    s.drew = false;
    s.generation++;
    s.program = null;
    s.objects.clear();
  };

  const fireLost = s => {
    const e = fire(s.canvas, "webglcontextlost", "", true);
    s.preventedRestore = e.defaultPrevented;
  };

  // Lost by anything but the page itself: a page that said it can (preventDefault) gets its context back when a device can be had.
  // The GPU process may be gone, or be going, or over its limit on restarts: this tries again for a while.
  const contextLost = s => {
    if (s.lost) return;
    markLost(s);
    fireLost(s);
    if (s.preventedRestore) restoreSoon(s, RESTORE_TRIES);
  };

  const restoreSoon = (s, tries) => {
    setTimeoutFn(() => {
      if (!s.lost) return;
      restore(s);
      if (s.lost && tries > 1) restoreSoon(s, tries - 1);
    }, RESTORE_WAIT_MS);
  };

  // A context lost while the page was running: seen at the next call that waits.
  const checkLost = s => { if (!s.lost && native.isLost(s.ref)) contextLost(s); };

  const restore = s => {
    if (!s.lost) return;
    if (!native.restore(s.ref)) return;
    s.lost = false;
    s.lostError = false;
    s.program = null;
    s.queries[0] = s.queries[1] = null;
    fire(s.canvas, "webglcontextrestored", "", false);
  };

  // A canvas with WebGL about to be read (toDataURL, drawImage, texImage2D): what was drawn so far, in its bitmap.
  // `commit`: the frame ends with this (transferToImageBitmap).
  const syncCanvas = (canvas, commit) => {
    if (canvas === null || typeof canvas !== "object") return;
    const gl = contextOf.get(canvas);
    if (gl === undefined) return;
    const s = gl[S];
    if (s.lost) return;
    flush(s);
    if (commit === true) native.commit(s.ref); else native.snapshot(s.ref);
  };

  // ---- the interface ----
  const commands = (proto, webgl2) => {
    const m = {
      activeTexture: op1(OP.ACTIVE_TEXTURE),
      attachShader(p, o) {
        const s = this[S]; required(p, WebGLProgram); required(o, WebGLShader);
        if (s.lost) return;
        const a = idOf(s, p, WebGLProgram), b = idOf(s, o, WebGLShader);
        if (a === undefined || b === undefined) return;
        const w = s.w, n = s.n;
        w[n] = OP.ATTACH_SHADER; w[n + 1] = a; w[n + 2] = b;
        s.n = n + 3;
        if (s.n >= s.limit) later(s);
      },
      detachShader(p, o) {
        const s = this[S]; required(p, WebGLProgram); required(o, WebGLShader);
        if (s.lost) return;
        const a = idOf(s, p, WebGLProgram), b = idOf(s, o, WebGLShader);
        if (a === undefined || b === undefined) return;
        const w = s.w, n = s.n;
        w[n] = OP.DETACH_SHADER; w[n + 1] = a; w[n + 2] = b;
        s.n = n + 3;
        if (s.n >= s.limit) later(s);
      },
      bindAttribLocation(p, index, name) {
        const s = this[S]; required(p, WebGLProgram);
        if (s.lost) return;
        const a = idOf(s, p, WebGLProgram);
        if (a === undefined) return;
        flush(s);
        const w = s.w;
        w[0] = OP.BIND_ATTRIB_LOCATION; w[1] = a; w[2] = index;
        s.n = 3;
        withText(s, String(name));
      },
      bindBuffer: binder(WebGLBuffer, OP.BIND_BUFFER),
      bindFramebuffer: binder(WebGLFramebuffer, OP.BIND_FRAMEBUFFER),
      bindRenderbuffer: binder(WebGLRenderbuffer, OP.BIND_RENDERBUFFER),
      bindTexture: binder(WebGLTexture, OP.BIND_TEXTURE),
      blendColor: opf4(OP.BLEND_COLOR),
      blendEquation(mode) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.BLEND_EQUATION; w[n + 1] = mode; w[n + 2] = mode; s.n = n + 3; if (s.n >= s.limit) later(s); },
      blendEquationSeparate: op2(OP.BLEND_EQUATION),
      blendFunc(a, b) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.BLEND_FUNC; w[n + 1] = a; w[n + 2] = b; w[n + 3] = a; w[n + 4] = b; s.n = n + 5; if (s.n >= s.limit) later(s); },
      blendFuncSeparate: op4(OP.BLEND_FUNC),
      bufferData,
      bufferSubData,
      checkFramebufferStatus(t) { return ifAlive(the(this), [Q.FRAMEBUFFER_STATUS, t], undefined, 0x8CDD); },
      clear(mask) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.CLEAR; w[n + 1] = mask; s.n = n + 2; s.drew = true; if (s.n >= s.limit) later(s); },
      clearColor: opf4(OP.CLEAR_COLOR),
      clearDepth: opf1(OP.CLEAR_DEPTH),
      clearStencil: op1(OP.CLEAR_STENCIL),
      colorMask(a, b, c, d) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.COLOR_MASK; w[n + 1] = a ? 1 : 0; w[n + 2] = b ? 1 : 0; w[n + 3] = c ? 1 : 0; w[n + 4] = d ? 1 : 0; s.n = n + 5; if (s.n >= s.limit) later(s); },
      compileShader(o) {
        const s = this[S]; required(o, WebGLShader);
        if (s.lost) return;
        const id = idOf(s, o, WebGLShader);
        if (id === undefined) return;
        const w = s.w, n = s.n;
        w[n] = OP.COMPILE_SHADER; w[n + 1] = id;
        s.n = n + 2;
        if (s.n >= s.limit) later(s);
      },
      compressedTexImage2D(target, level, internal, width, height, border, data, srcOffset, srcLength) {
        const s = this[S];
        if (s.lost) return;
        flush(s);
        const c = s.w;
        if (!isView(data)) throw new TE("compressedTexImage2D: not a view");
        const bytes = viewBytes(data, (srcOffset || 0) >>> 0, (srcLength || 0) >>> 0);
        if (bytes === null) return fail(s, INVALID_VALUE);
        c[0] = OP.COMPRESSED_TEX_IMAGE; c[1] = target; c[2] = level; c[3] = internal; c[4] = width; c[5] = height; c[6] = 1; c[7] = border; c[8] = 0; c[9] = bytes.length;
        s.n = 10;
        sendWith(s, bytes);
      },
      compressedTexSubImage2D(target, level, x, y, width, height, format, data, srcOffset, srcLength) {
        const s = this[S];
        if (s.lost) return;
        flush(s);
        const c = s.w;
        if (!isView(data)) throw new TE("compressedTexSubImage2D: not a view");
        const bytes = viewBytes(data, (srcOffset || 0) >>> 0, (srcLength || 0) >>> 0);
        if (bytes === null) return fail(s, INVALID_VALUE);
        c[0] = OP.COMPRESSED_TEX_SUB_IMAGE; c[1] = target; c[2] = level; c[3] = x; c[4] = y; c[5] = 0; c[6] = width; c[7] = height; c[8] = 1; c[9] = format; c[10] = bytes.length;
        s.n = 11;
        sendWith(s, bytes);
      },
      copyTexImage2D(target, level, internal, x, y, width, height, border) {
        const s = this[S];
        if (s.lost) return;
        const c = s.w, n = s.n;
        c[n] = OP.COPY_TEX_IMAGE; c[n + 1] = target; c[n + 2] = level; c[n + 3] = internal; c[n + 4] = x; c[n + 5] = y; c[n + 6] = width; c[n + 7] = height; c[n + 8] = border;
        s.n = n + 9;
        if (s.n >= s.limit) later(s);
      },
      copyTexSubImage2D(target, level, xo, yo, x, y, width, height) {
        const s = this[S];
        if (s.lost) return;
        const c = s.w, n = s.n;
        c[n] = OP.COPY_TEX_SUB_IMAGE; c[n + 1] = target; c[n + 2] = level; c[n + 3] = xo; c[n + 4] = yo; c[n + 5] = x; c[n + 6] = y; c[n + 7] = width; c[n + 8] = height;
        s.n = n + 9;
        if (s.n >= s.limit) later(s);
      },
      createBuffer: creator(WebGLBuffer),
      createFramebuffer: creator(WebGLFramebuffer),
      createProgram() {
        const s = this[S];
        if (s.lost) return null;
        const o = newObject(s, WebGLProgram);
        o[S].bound = true;
        o[S].link = 0;
        o[S].shaders = [];
        return o;
      },
      createRenderbuffer: creator(WebGLRenderbuffer),
      createShader(type) {
        const s = this[S];
        if (s.lost) return null;
        if (type !== this.VERTEX_SHADER && type !== this.FRAGMENT_SHADER) { fail(s, INVALID_ENUM); return null; }
        const o = newObject(s, WebGLShader);
        o[S].bound = true;
        o[S].stage = type;
        o[S].source = "";
        return o;
      },
      createTexture: creator(WebGLTexture),
      cullFace: op1(OP.CULL_FACE),
      deleteBuffer: deleter(WebGLBuffer, OP.DELETE_BUFFER),
      deleteFramebuffer: deleter(WebGLFramebuffer, OP.DELETE_FRAMEBUFFER),
      deleteProgram: deleter(WebGLProgram, OP.DELETE_PROGRAM),
      deleteRenderbuffer: deleter(WebGLRenderbuffer, OP.DELETE_RENDERBUFFER),
      deleteShader: deleter(WebGLShader, OP.DELETE_SHADER),
      deleteTexture: deleter(WebGLTexture, OP.DELETE_TEXTURE),
      depthFunc: op1(OP.DEPTH_FUNC),
      depthMask(v) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.DEPTH_MASK; w[n + 1] = v ? 1 : 0; s.n = n + 2; if (s.n >= s.limit) later(s); },
      depthRange: opf2(OP.DEPTH_RANGE),
      disable: op1(OP.DISABLE),
      disableVertexAttribArray: op1(OP.DISABLE_ATTRIB),
      drawArrays(mode, first, count) {
        const s = this[S];
        if (s.lost) return;
        const w = s.w, n = s.n;
        w[n] = OP_DRAW_ARRAYS; w[n + 1] = mode; w[n + 2] = first; w[n + 3] = count; w[n + 4] = 1;
        s.n = n + 5;
        s.drew = true;
        if (s.n >= s.limit) later(s);
      },
      drawElements(mode, count, type, offset) {
        const s = this[S];
        if (s.lost) return;
        const w = s.w, n = s.n;
        w[n] = OP_DRAW_ELEMENTS; w[n + 1] = mode; w[n + 2] = count; w[n + 3] = type; w[n + 4] = offset; w[n + 5] = 1;
        s.n = n + 6;
        s.drew = true;
        if (s.n >= s.limit) later(s);
      },
      enable: op1(OP.ENABLE),
      enableVertexAttribArray: op1(OP.ENABLE_ATTRIB),
      finish() { const s = this[S]; if (!s.lost) ask(s, [Q.FINISH]); },
      flush() { const s = this[S]; if (!s.lost) flush(s); },
      framebufferRenderbuffer(t, a, rt, o) {
        const s = this[S];
        if (s.lost) return;
        const id = idOf(s, o, WebGLRenderbuffer);
        if (id === undefined) return;
        const w = s.w, n = s.n;
        w[n] = OP.FRAMEBUFFER_RENDERBUFFER; w[n + 1] = t; w[n + 2] = a; w[n + 3] = rt; w[n + 4] = id;
        s.n = n + 5;
        if (s.n >= s.limit) later(s);
      },
      framebufferTexture2D(t, a, tt, o, level) {
        const s = this[S];
        if (s.lost) return;
        const id = idOf(s, o, WebGLTexture);
        if (id === undefined) return;
        const w = s.w, n = s.n;
        w[n] = OP.FRAMEBUFFER_TEXTURE; w[n + 1] = t; w[n + 2] = a; w[n + 3] = tt; w[n + 4] = id; w[n + 5] = level;
        s.n = n + 6;
        if (s.n >= s.limit) later(s);
      },
      frontFace: op1(OP.FRONT_FACE),
      generateMipmap: op1(OP.GENERATE_MIPMAP),
      getActiveAttrib(p, index) { return activeInfo(the(this), p, index, Q.ACTIVE_ATTRIB); },
      getActiveUniform(p, index) { return activeInfo(the(this), p, index, Q.ACTIVE_UNIFORM); },
      getAttachedShaders(p) {
        const s = this[S]; required(p, WebGLProgram);
        if (s.lost) return null;
        const id = idOf(s, p, WebGLProgram);
        if (id === undefined) return null;
        return p[S].shaders.filter(x => !x[S].deleted || x[S].attached);
      },
      getAttribLocation(p, name) {
        const s = this[S]; required(p, WebGLProgram);
        if (s.lost) return -1;
        const id = idOf(s, p, WebGLProgram);
        if (id === undefined) return -1;
        return ifAlive(s, [Q.ATTRIB_LOCATION, id], String(name), -1);
      },
      getBufferParameter(t, p) { return ifAlive(the(this), [Q.BUFFER_PARAMETER, t, p], undefined, null); },
      getContextAttributes() { const s = this[S]; return s.lost ? null : Object.assign({}, s.attrs); },
      getError() {
        const s = this[S];
        if (s.lost) {
          if (s.lostError) { s.lostError = false; return CONTEXT_LOST; }
          return 0;
        }
        const r = ask(s, [Q.ERROR]);
        if (r < 0) { checkLost(s); if (s.lost) { s.lostError = false; return CONTEXT_LOST; } return 0; }
        return value(s);
      },
      getExtension(name) {
        const s = this[S];
        if (s.lost) return null;
        return extension(s, String(name));
      },
      getFramebufferAttachmentParameter(t, a, p) { return ifAlive(the(this), [Q.ATTACHMENT_PARAMETER, t, a, p], undefined, null); },
      getParameter(p) {
        const s = this[S];
        if (s.lost) return null;
        return ifAlive(s, [Q.PARAMETER, p], undefined, null);
      },
      getProgramInfoLog(p) {
        const s = this[S]; required(p, WebGLProgram);
        if (s.lost) return null;
        const id = idOf(s, p, WebGLProgram);
        if (id === undefined) return null;
        return ifAlive(s, [Q.PROGRAM_LOG, id], undefined, null);
      },
      getProgramParameter(p, pname) {
        const s = this[S]; required(p, WebGLProgram);
        if (s.lost) return pname === 0x8B82 ? false : null;
        const id = idOf(s, p, WebGLProgram);
        if (id === undefined) return null;
        if (pname === 0x91B1) { if (s.exts.has("KHR_parallel_shader_compile")) return true; fail(s, INVALID_ENUM); return null; }
        return ifAlive(s, [Q.PROGRAM, id, pname], undefined, null);
      },
      getRenderbufferParameter(t, p) { return ifAlive(the(this), [Q.RENDERBUFFER_PARAMETER, t, p], undefined, null); },
      getShaderInfoLog(o) {
        const s = this[S]; required(o, WebGLShader);
        if (s.lost) return null;
        const id = idOf(s, o, WebGLShader);
        if (id === undefined) return null;
        return ifAlive(s, [Q.SHADER_LOG, id], undefined, null);
      },
      getShaderParameter(o, pname) {
        const s = this[S]; required(o, WebGLShader);
        if (s.lost) return pname === 0x8B81 ? false : null;
        const id = idOf(s, o, WebGLShader);
        if (id === undefined) return null;
        if (pname === 0x91B1) { if (s.exts.has("KHR_parallel_shader_compile")) return true; fail(s, INVALID_ENUM); return null; }
        return ifAlive(s, [Q.SHADER, id, pname], undefined, null);
      },
      getShaderPrecisionFormat(stage, precision) {
        const s = this[S];
        if (s.lost) return null;
        if (stage !== 0x8B31 && stage !== 0x8B30) { fail(s, INVALID_ENUM); return null; }
        const f = new PrecisionFormat(TOKEN);
        let v;
        switch (precision) {
          case 0x8DF0: case 0x8DF1: case 0x8DF2: v = { rangeMin: 127, rangeMax: 127, precision: 23 }; break;   // the floats
          case 0x8DF3: case 0x8DF4: case 0x8DF5: v = { rangeMin: 31, rangeMax: 30, precision: 0 }; break;      // the ints
          default: fail(s, INVALID_ENUM); return null;
        }
        f[S] = v;
        return f;
      },
      getShaderSource(o) {
        const s = this[S]; required(o, WebGLShader);
        if (s.lost) return null;
        const id = idOf(s, o, WebGLShader);
        if (id === undefined) return null;
        return o[S].source;
      },
      getSupportedExtensions() {
        const s = this[S];
        if (s.lost) return null;
        return supported(s).slice();
      },
      getTexParameter(t, p) { return ifAlive(the(this), [Q.TEX_PARAMETER, t, p], undefined, null); },
      getUniform(p, loc) {
        const s = this[S]; required(p, WebGLProgram); required(loc, Location);
        if (s.lost) return null;
        const id = idOf(s, p, WebGLProgram);
        if (id === undefined) return null;
        if (loc[S].program !== p || loc[S].link !== p[S].link) { fail(s, INVALID_OPERATION); return null; }
        return ifAlive(s, [Q.UNIFORM, id, loc[S].value], undefined, null);
      },
      getUniformLocation(p, name) {
        const s = this[S]; required(p, WebGLProgram);
        if (s.lost) return null;
        const id = idOf(s, p, WebGLProgram);
        if (id === undefined) return null;
        const r = ask(s, [Q.UNIFORM_LOCATION, id], String(name));
        if (r < 0) return null;
        const v = s.rw[1];
        if (v < 0) return null;
        const l = new Location(TOKEN);
        l[S] = { value: v, program: p, link: p[S].link, generation: s.generation };
        return l;
      },
      getVertexAttrib(i, p) {
        const s = this[S];
        if (s.lost) return null;
        return ifAlive(s, [Q.VERTEX_ATTRIB, i, p], undefined, null);
      },
      getVertexAttribOffset(i, p) {
        const s = this[S];
        if (s.lost) return 0;
        const v = ifAlive(s, [Q.VERTEX_ATTRIB, i, p], undefined, 0);
        return v === null ? 0 : v;
      },
      hint: op2(OP.HINT),
      isBuffer: isObject(WebGLBuffer),
      isContextLost() { return the(this).lost; },
      isEnabled(cap) { const s = this[S]; if (s.lost) return false; const v = ifAlive(s, [Q.PARAMETER, cap], undefined, false); return v === null ? false : v; },
      isFramebuffer: isObject(WebGLFramebuffer),
      isProgram: isObject(WebGLProgram),
      isRenderbuffer: isObject(WebGLRenderbuffer),
      isShader: isObject(WebGLShader),
      isTexture: isObject(WebGLTexture),
      lineWidth: opf1(OP.LINE_WIDTH),
      linkProgram(p) {
        const s = this[S]; required(p, WebGLProgram);
        if (s.lost) return;
        const id = idOf(s, p, WebGLProgram);
        if (id === undefined) return;
        p[S].link++;
        if (s.program === p) s.programLink = p[S].link;
        const w = s.w, n = s.n;
        w[n] = OP.LINK_PROGRAM; w[n + 1] = id;
        s.n = n + 2;
        if (s.n >= s.limit) later(s);
      },
      pixelStorei(p, v) {
        const s = this[S];
        if (s.lost) return;
        const w = s.w, n = s.n;
        w[n] = OP.PIXEL_STOREI; w[n + 1] = p; w[n + 2] = typeof v === "boolean" ? (v ? 1 : 0) : v;
        s.n = n + 3;
        if (s.n >= s.limit) later(s);
      },
      polygonOffset: opf2(OP.POLYGON_OFFSET),
      readPixels(x, y, width, height, format, type, dst, dstOffset) {
        const s = this[S];
        if (s.lost) return;
        let pbo = 0, out = null;
        if (typeof dst === "number" && s.webgl2) {
          pbo = dst;
        } else {
          if (dst === null || !isView(dst)) throw new TE("readPixels: the destination is not a view");
          const off = dstOffset === undefined ? 0 : dstOffset >>> 0;
          out = viewBytes(dst, off, 0);
          if (out === null) return fail(s, INVALID_OPERATION);
          if (!matchingView(type, dst)) return fail(s, INVALID_OPERATION);
        }
        flush(s);
        const w = s.w;
        w[0] = Q.READ_PIXELS; w[1] = x; w[2] = y; w[3] = width; w[4] = height; w[5] = format; w[6] = type; w[7] = out === null ? 0 : out.length; w[8] = pbo;
        if (out === null) { native.query(s.ref, s.buffer, 9, s.reply); return; }
        const r = native.queryInto(s.ref, s.buffer, 9, out);
        if (r < 0) checkLost(s);
      },
      renderbufferStorage(t, internal, width, height) {
        const s = this[S];
        if (s.lost) return;
        const w = s.w, n = s.n;
        w[n] = OP.RENDERBUFFER_STORAGE; w[n + 1] = t; w[n + 2] = internal; w[n + 3] = width; w[n + 4] = height; w[n + 5] = 0;
        s.n = n + 6;
        if (s.n >= s.limit) later(s);
      },
      sampleCoverage(v, inv) { const s = this[S]; if (s.lost) return; const n = s.n; s.w[n] = OP.SAMPLE_COVERAGE; s.f[n + 1] = v; s.w[n + 2] = inv ? 1 : 0; s.n = n + 3; if (s.n >= s.limit) later(s); },
      scissor: op4(OP.SCISSOR),
      shaderSource(o, text) {
        const s = this[S]; required(o, WebGLShader);
        if (s.lost) return;
        const id = idOf(s, o, WebGLShader);
        if (id === undefined) return;
        const source = String(text);
        o[S].source = source;
        flush(s);
        const w = s.w;
        w[0] = OP.SHADER_SOURCE; w[1] = id; w[2] = o[S].stage;
        s.n = 3;
        withText(s, source);
      },
      stencilFunc(f, ref, mask) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.STENCIL_FUNC; w[n + 1] = 0x408; w[n + 2] = f; w[n + 3] = ref; w[n + 4] = mask; s.n = n + 5; if (s.n >= s.limit) later(s); },
      stencilFuncSeparate: op4(OP.STENCIL_FUNC),
      stencilMask(mask) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.STENCIL_MASK; w[n + 1] = 0x408; w[n + 2] = mask; s.n = n + 3; if (s.n >= s.limit) later(s); },
      stencilMaskSeparate: op2(OP.STENCIL_MASK),
      stencilOp(a, b, c) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.STENCIL_OP; w[n + 1] = 0x408; w[n + 2] = a; w[n + 3] = b; w[n + 4] = c; s.n = n + 5; if (s.n >= s.limit) later(s); },
      stencilOpSeparate: op4(OP.STENCIL_OP),
      texImage2D,
      texParameterf(t, p, v) { const s = this[S]; if (s.lost) return; const n = s.n; s.w[n] = OP.TEX_PARAMETER_F; s.w[n + 1] = t; s.w[n + 2] = p; s.f[n + 3] = v; s.n = n + 4; if (s.n >= s.limit) later(s); },
      texParameteri(t, p, v) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.TEX_PARAMETER_I; w[n + 1] = t; w[n + 2] = p; w[n + 3] = v; s.n = n + 4; if (s.n >= s.limit) later(s); },
      texSubImage2D,
      uniform1f: uf(1, 0), uniform2f: uf(2, 0), uniform3f: uf(3, 0), uniform4f: uf(4, 0),
      uniform1i: uf(1, 1), uniform2i: uf(2, 1), uniform3i: uf(3, 1), uniform4i: uf(4, 1),
      uniform1fv: uv(1, 0, F32), uniform2fv: uv(2, 0, F32), uniform3fv: uv(3, 0, F32), uniform4fv: uv(4, 0, F32),
      uniform1iv: uv(1, 1, I32), uniform2iv: uv(2, 1, I32), uniform3iv: uv(3, 1, I32), uniform4iv: uv(4, 1, I32),
      uniformMatrix2fv: um(2, 2), uniformMatrix3fv: um(3, 3), uniformMatrix4fv: um(4, 4),
      useProgram(p) {
        const s = this[S];
        if (s.lost) return;
        const id = idOf(s, p, WebGLProgram);
        if (id === undefined) return;
        s.program = p === undefined ? null : p;
        s.programLink = s.program === null ? 0 : s.program[S].link;
        const w = s.w, n = s.n;
        w[n] = OP.USE_PROGRAM; w[n + 1] = id;
        s.n = n + 2;
        if (s.n >= s.limit) later(s);
      },
      validateProgram(p) {
        const s = this[S]; required(p, WebGLProgram);
        if (s.lost) return;
        const id = idOf(s, p, WebGLProgram);
        if (id !== undefined) ask(s, [Q.VALIDATE, id]);
      },
      vertexAttrib1f: vaf(1), vertexAttrib2f: vaf(2), vertexAttrib3f: vaf(3), vertexAttrib4f: vaf(4),
      vertexAttrib1fv: vav(1), vertexAttrib2fv: vav(2), vertexAttrib3fv: vav(3), vertexAttrib4fv: vav(4),
      vertexAttribPointer(i, size, type, normalized, stride, offset) {
        const s = this[S];
        if (s.lost) return;
        if (offset < 0) return fail(s, INVALID_VALUE);
        const w = s.w, n = s.n;
        w[n] = OP.VERTEX_ATTRIB_POINTER; w[n + 1] = i; w[n + 2] = size; w[n + 3] = type; w[n + 4] = normalized ? 1 : 0; w[n + 5] = stride; w[n + 6] = offset; w[n + 7] = 0;
        s.n = n + 8;
        if (s.n >= s.limit) later(s);
      },
      viewport: op4(OP.VIEWPORT),
    };
    if (webgl2) Object.assign(m, commands2());
    for (const name of Object.keys(m)) {
      defineProperty(proto, name, { value: m[name], writable: true, enumerable: true, configurable: true });
      defineProperty(m[name], "name", { value: name, configurable: true });
      if (LENGTHS[name] !== undefined) defineProperty(m[name], "length", { value: LENGTHS[name], configurable: true });
    }
    const getter = (name, fn) => {
      defineProperty(fn, "name", { value: "get " + name, configurable: true });
      defineProperty(proto, name, { get: fn, enumerable: true, configurable: true });
    };
    getter("canvas", function () { return the(this).canvas; });
    getter("drawingBufferWidth", function () { const s = this[S]; return s.lost ? 0 : native.width(s.ref); });
    getter("drawingBufferHeight", function () { const s = this[S]; return s.lost ? 0 : native.height(s.ref); });
    getter("drawingBufferColorSpace", function () { the(this); return "srgb"; });
    getter("drawingBufferFormat", function () { the(this); return DRAWING_BUFFER_FORMAT; });
    getter("unpackColorSpace", function () { the(this); return "srgb"; });
  };

  const activeInfo = (s, p, index, what) => {
    required(p, WebGLProgram);
    if (s.lost) return null;
    const id = idOf(s, p, WebGLProgram);
    if (id === undefined) return null;
    const r = ask(s, [what, id, index]);
    if (r < 0 || s.rw[0] === TAG.NULL) return null;
    const info = new ActiveInfo(TOKEN);
    const w = s.rw;
    info[S] = { size: w[2], type: w[3], name: utf8.decode(new U8(s.reply, 20, w[4])) };
    return info;
  };

  // The view's type must be what readPixels' type says.
  const matchingView = (type, view) => {
    switch (type) {
      case 0x1401: return view instanceof U8 || view instanceof Uint8ClampedArray;
      case 0x1400: return view instanceof Int8Array;
      case 0x1403: case 0x8363: case 0x8033: case 0x8034: return view instanceof Uint16Array;
      case 0x1402: return view instanceof Int16Array;
      case 0x1405: case 0x8368: case 0x8C3B: case 0x8C3E: return view instanceof U32;
      case 0x1404: return view instanceof I32;
      case 0x1406: return view instanceof F32;
      case 0x140B: case 0x8D61: return view instanceof Uint16Array;
    }
    return true;
  };

  // ---- WebGL 2 ----
  const commands2 = () => ({
    beginQuery(t, q) {
      const s = this[S]; required(q, WebGLQuery);
      if (s.lost) return;
      const id = idOf(s, q, WebGLQuery);
      if (id === undefined) return;
      const slot = QUERY_SLOT[t];
      if (slot === undefined) return fail(s, INVALID_ENUM);
      if (s.queries[slot] || (q[S].target !== undefined && q[S].target !== t)) return fail(s, INVALID_OPERATION);
      q[S].target = t; q[S].bound = true; q[S].later = false;
      s.queries[slot] = q;
      const w = s.w, n = s.n;
      w[n] = OP.BEGIN_QUERY; w[n + 1] = t; w[n + 2] = id;
      s.n = n + 3;
      if (s.n >= s.limit) later(s);
    },
    endQuery(t) {
      const s = this[S];
      if (s.lost) return;
      const slot = QUERY_SLOT[t];
      if (slot === undefined) return fail(s, INVALID_ENUM);
      const q = s.queries[slot];
      if (!q || q[S].target !== t) return fail(s, INVALID_OPERATION);
      s.queries[slot] = null;
      // (WebGL 2: a result shows on a later task, never in the one that ended the query)
      setTimeoutFn(() => { q[S].later = true; }, 0);
      const w = s.w, n = s.n;
      w[n] = OP.END_QUERY; w[n + 1] = t;
      s.n = n + 2;
      if (s.n >= s.limit) later(s);
    },
    getQuery(t, p) {
      const s = the(this);
      const slot = QUERY_SLOT[t];
      if (slot === undefined || p !== 0x8865) { if (!s.lost) fail(s, INVALID_ENUM); return null; }
      const q = s.queries[slot];
      return q && q[S].target === t ? q : null;
    },
    getQueryParameter(q, p) {
      const s = this[S]; required(q, WebGLQuery);
      if (s.lost) return null;
      const id = idOf(s, q, WebGLQuery);
      if (id === undefined) return null;
      if (p !== 0x8866 && p !== 0x8867) { fail(s, INVALID_ENUM); return null; }
      if (q[S].target === undefined || s.queries[QUERY_SLOT[q[S].target]] === q) { fail(s, INVALID_OPERATION); return null; }
      if (!q[S].later) return p === 0x8867 ? false : 0;
      return ifAlive(s, [Q.QUERY, id, p], undefined, null);
    },
    createQuery: creator(WebGLQuery),
    deleteQuery(q) {
      if (q === null || q === undefined) return;
      const s = this[S]; required(q, WebGLQuery);
      if (s.lost) return;
      const id = idOf(s, q, WebGLQuery);
      if (id === undefined) return;
      const slot = QUERY_SLOT[q[S].target];
      if (slot !== undefined && s.queries[slot] === q) s.queries[slot] = null;
      q[S].deleted = true;
      s.objects.delete(id);
      const w = s.w, n = s.n;
      w[n] = OP.DELETE_QUERY; w[n + 1] = id;
      s.n = n + 2;
      if (s.n >= s.limit) later(s);
    },
    isQuery: isObject(WebGLQuery),
    createSampler() {
      const s = this[S];
      if (s.lost) return null;
      const o = newObject(s, WebGLSampler);
      o[S].bound = true;
      return o;
    },
    deleteSampler: deleter(WebGLSampler, OP.DELETE_SAMPLER),
    isSampler: isObject(WebGLSampler),
    bindSampler(unit, o) {
      const s = this[S];
      if (s.lost) return;
      const id = idOf(s, o, WebGLSampler);
      if (id === undefined) return;
      const w = s.w, n = s.n;
      w[n] = OP.BIND_SAMPLER; w[n + 1] = unit; w[n + 2] = id;
      s.n = n + 3;
      if (s.n >= s.limit) later(s);
    },
    samplerParameteri(o, p, v) {
      const s = this[S]; required(o, WebGLSampler);
      if (s.lost) return;
      const id = idOf(s, o, WebGLSampler);
      if (id === undefined) return;
      const w = s.w, n = s.n;
      w[n] = OP.SAMPLER_PARAMETER_I; w[n + 1] = id; w[n + 2] = p; w[n + 3] = v;
      s.n = n + 4;
      if (s.n >= s.limit) later(s);
    },
    samplerParameterf(o, p, v) {
      const s = this[S]; required(o, WebGLSampler);
      if (s.lost) return;
      const id = idOf(s, o, WebGLSampler);
      if (id === undefined) return;
      const n = s.n;
      s.w[n] = OP.SAMPLER_PARAMETER_F; s.w[n + 1] = id; s.w[n + 2] = p; s.f[n + 3] = v;
      s.n = n + 4;
      if (s.n >= s.limit) later(s);
    },
    getSamplerParameter(o, p) {
      const s = this[S]; required(o, WebGLSampler);
      if (s.lost) return null;
      const id = idOf(s, o, WebGLSampler);
      if (id === undefined) return null;
      return ifAlive(s, [Q.SAMPLER_PARAMETER, id, p], undefined, null);
    },
    fenceSync(c, f) {
      const s = this[S];
      if (s.lost) return null;
      if (c !== 0x9117 || f !== 0) { fail(s, c !== 0x9117 ? INVALID_ENUM : INVALID_VALUE); return null; }
      const o = new WebGLSync(TOKEN);
      flush(s);
      o[S] = { ctx: s, generation: s.generation, deleted: false, bound: true, id: 0 };
      return o;
    },
    isSync(o) { return o instanceof WebGLSync && !o[S].deleted; },
    deleteSync(o) { if (o !== null && o !== undefined) o[S].deleted = true; },
    clientWaitSync(o, f, t) {
      const s = this[S]; required(o, WebGLSync);
      if (s.lost) return 0x911D;
      ask(s, [Q.FINISH]);
      return 0x911A;   // ALREADY_SIGNALED: finished on this call
    },
    waitSync(o, f, t) { the(this); required(o, WebGLSync); },
    getSyncParameter(o, p) {
      const s = this[S]; required(o, WebGLSync);
      if (s.lost) return null;
      switch (p) {
        case 0x9112: return 0x9116;
        case 0x9113: ask(s, [Q.FINISH]); return 0x9119;
        case 0x9114: return 0x9117;
        case 0x9115: return 0;
      }
      fail(s, INVALID_ENUM);
      return null;
    },
    // Transform feedback is not there: the objects exist, starting it is an error.
    createTransformFeedback: creator(WebGLTransformFeedback),
    deleteTransformFeedback(o) {
      if (o === null || o === undefined) return;
      const s = this[S]; required(o, WebGLTransformFeedback);
      if (s.lost) return;
      const id = idOf(s, o, WebGLTransformFeedback);
      if (id === undefined) return;
      o[S].deleted = true;
      const w = s.w, n = s.n;
      w[n] = OP.DELETE_TF; w[n + 1] = id;
      s.n = n + 2;
      if (s.n >= s.limit) later(s);
    },
    isTransformFeedback: isObject(WebGLTransformFeedback),
    bindTransformFeedback(t, o) {
      const s = this[S];
      if (s.lost) return;
      const id = idOf(s, o, WebGLTransformFeedback);
      if (id === undefined) return;
      if (id !== 0) o[S].bound = true;
      const w = s.w, n = s.n;
      w[n] = OP.BIND_TF; w[n + 1] = t; w[n + 2] = id;
      s.n = n + 3;
      if (s.n >= s.limit) later(s);
    },
    beginTransformFeedback: op1(OP.BEGIN_TF),
    endTransformFeedback: op0("endTransformFeedback", OP.END_TF),
    pauseTransformFeedback: op0("pauseTransformFeedback", OP.PAUSE_TF),
    resumeTransformFeedback: op0("resumeTransformFeedback", OP.RESUME_TF),
    transformFeedbackVaryings(p, names, mode) {
      const s = this[S]; required(p, WebGLProgram);
      if (s.lost) return;
      const id = idOf(s, p, WebGLProgram);
      if (id === undefined) return;
      const list = [];
      for (const name of names) list.push(String(name));
      flush(s);
      const w = s.w;
      w[0] = OP.TF_VARYINGS; w[1] = id; w[2] = mode;
      s.n = 3;
      withText(s, list.join("\n"));
      p[S].tf = list;
      p[S].tfMode = mode;
    },
    getTransformFeedbackVarying(p, i) { return activeInfo(the(this), p, i, Q.TF_VARYING); },
    createVertexArray() {
      const s = this[S];
      return s.lost ? null : newObject(s, WebGLVertexArrayObject);
    },
    deleteVertexArray: deleter(WebGLVertexArrayObject, OP.DELETE_VAO),
    isVertexArray: isObject(WebGLVertexArrayObject),
    bindVertexArray(o) {
      const s = this[S];
      if (s.lost) return;
      const id = idOf(s, o, WebGLVertexArrayObject);
      if (id === undefined) return;
      if (id !== 0) o[S].bound = true;
      const w = s.w, n = s.n;
      w[n] = OP.BIND_VAO; w[n + 1] = id;
      s.n = n + 2;
      if (s.n >= s.limit) later(s);
    },
    drawArraysInstanced(mode, first, count, instances) {
      const s = this[S];
      if (s.lost) return;
      const w = s.w, n = s.n;
      w[n] = OP_DRAW_ARRAYS; w[n + 1] = mode; w[n + 2] = first; w[n + 3] = count; w[n + 4] = instances;
      s.n = n + 5;
      s.drew = true;
      if (s.n >= s.limit) later(s);
    },
    drawElementsInstanced(mode, count, type, offset, instances) {
      const s = this[S];
      if (s.lost) return;
      const w = s.w, n = s.n;
      w[n] = OP_DRAW_ELEMENTS; w[n + 1] = mode; w[n + 2] = count; w[n + 3] = type; w[n + 4] = offset; w[n + 5] = instances;
      s.n = n + 6;
      s.drew = true;
      if (s.n >= s.limit) later(s);
    },
    drawRangeElements(mode, start, end, count, type, offset) {
      const s = this[S];
      if (s.lost) return;
      if (end < start) return fail(s, INVALID_VALUE);
      const w = s.w, n = s.n;
      w[n] = OP_DRAW_ELEMENTS; w[n + 1] = mode; w[n + 2] = count; w[n + 3] = type; w[n + 4] = offset; w[n + 5] = 1;
      s.n = n + 6;
      s.drew = true;
      if (s.n >= s.limit) later(s);
    },
    vertexAttribDivisor: op2(OP.VERTEX_ATTRIB_DIVISOR),
    vertexAttribIPointer(i, size, type, stride, offset) {
      const s = this[S];
      if (s.lost) return;
      if (offset < 0) return fail(s, INVALID_VALUE);
      const w = s.w, n = s.n;
      w[n] = OP.VERTEX_ATTRIB_POINTER; w[n + 1] = i; w[n + 2] = size; w[n + 3] = type; w[n + 4] = 0; w[n + 5] = stride; w[n + 6] = offset; w[n + 7] = 1;
      s.n = n + 8;
      if (s.n >= s.limit) later(s);
    },
    vertexAttribI4i(i, a, b, c, d) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.VERTEX_ATTRIB; w[n + 1] = i; w[n + 2] = 1; w[n + 3] = a; w[n + 4] = b; w[n + 5] = c; w[n + 6] = d; s.n = n + 7; if (s.n >= s.limit) later(s); },
    vertexAttribI4ui(i, a, b, c, d) { const s = this[S]; if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.VERTEX_ATTRIB; w[n + 1] = i; w[n + 2] = 2; w[n + 3] = a; w[n + 4] = b; w[n + 5] = c; w[n + 6] = d; s.n = n + 7; if (s.n >= s.limit) later(s); },
    vertexAttribI4iv(i, v) { const s = this[S]; const d = numbers(v, I32); if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.VERTEX_ATTRIB; w[n + 1] = i; w[n + 2] = 1; w[n + 3] = d[0]; w[n + 4] = d[1]; w[n + 5] = d[2]; w[n + 6] = d[3]; s.n = n + 7; if (s.n >= s.limit) later(s); },
    vertexAttribI4uiv(i, v) { const s = this[S]; const d = numbers(v, U32); if (s.lost) return; const w = s.w, n = s.n; w[n] = OP.VERTEX_ATTRIB; w[n + 1] = i; w[n + 2] = 2; w[n + 3] = d[0]; w[n + 4] = d[1]; w[n + 5] = d[2]; w[n + 6] = d[3]; s.n = n + 7; if (s.n >= s.limit) later(s); },
    uniform1ui: uf(1, 2), uniform2ui: uf(2, 2), uniform3ui: uf(3, 2), uniform4ui: uf(4, 2),
    uniform1uiv: uv(1, 2, U32), uniform2uiv: uv(2, 2, U32), uniform3uiv: uv(3, 2, U32), uniform4uiv: uv(4, 2, U32),
    uniformMatrix2x3fv: um(2, 3), uniformMatrix2x4fv: um(2, 4), uniformMatrix3x2fv: um(3, 2), uniformMatrix3x4fv: um(3, 4), uniformMatrix4x2fv: um(4, 2), uniformMatrix4x3fv: um(4, 3),
    blitFramebuffer(a, b, c, d, e, f, g, h, mask, filter) {
      const s = this[S];
      if (s.lost) return;
      const w = s.w, n = s.n;
      w[n] = OP.BLIT_FRAMEBUFFER; w[n + 1] = a; w[n + 2] = b; w[n + 3] = c; w[n + 4] = d; w[n + 5] = e; w[n + 6] = f; w[n + 7] = g; w[n + 8] = h; w[n + 9] = mask; w[n + 10] = filter;
      s.n = n + 11;
      s.drew = true;
      if (s.n >= s.limit) later(s);
    },
    framebufferTextureLayer(t, a, o, level, layer) {
      const s = this[S];
      if (s.lost) return;
      const id = idOf(s, o, WebGLTexture);
      if (id === undefined) return;
      const w = s.w, n = s.n;
      w[n] = OP.FRAMEBUFFER_TEXTURE_LAYER; w[n + 1] = t; w[n + 2] = a; w[n + 3] = id; w[n + 4] = level; w[n + 5] = layer;
      s.n = n + 6;
      if (s.n >= s.limit) later(s);
    },
    invalidateFramebuffer(t, list) { the(this); },
    invalidateSubFramebuffer(t, list, x, y, w, h) { the(this); },
    readBuffer: op1(OP.READ_BUFFER),
    drawBuffers(list) { drawBuffersOf(the(this), list); },
    clearBufferfv(buffer, index, v, off) { clearBuffer(the(this), buffer, index, 0, numbers(v, F32), off); },
    clearBufferiv(buffer, index, v, off) { clearBuffer(the(this), buffer, index, 1, numbers(v, I32), off); },
    clearBufferuiv(buffer, index, v, off) { clearBuffer(the(this), buffer, index, 2, numbers(v, U32), off); },
    clearBufferfi(buffer, index, depth, stencil) {
      const s = this[S];
      if (s.lost) return;
      const n = s.n, w = s.w;
      w[n] = OP.CLEAR_BUFFER; w[n + 1] = buffer; w[n + 2] = index; w[n + 3] = 3; s.f[n + 4] = depth; w[n + 5] = stencil; w[n + 6] = 0; w[n + 7] = 0;
      s.n = n + 8;
      s.drew = true;
      if (s.n >= s.limit) later(s);
    },
    bindBufferBase(t, index, o) {
      const s = this[S];
      if (s.lost) return;
      const id = idOf(s, o, WebGLBuffer);
      if (id === undefined) return;
      if (id !== 0) o[S].bound = true;
      const w = s.w, n = s.n;
      w[n] = OP.BIND_BUFFER_RANGE; w[n + 1] = t; w[n + 2] = index; w[n + 3] = id; w[n + 4] = 0; w[n + 5] = WHOLE_BUFFER;
      s.n = n + 6;
      if (s.n >= s.limit) later(s);
    },
    bindBufferRange(t, index, o, offset, size) {
      const s = this[S];
      if (s.lost) return;
      const id = idOf(s, o, WebGLBuffer);
      if (id === undefined) return;
      if (id !== 0) o[S].bound = true;
      if (offset < 0 || (id !== 0 && size <= 0)) return fail(s, INVALID_VALUE);
      const w = s.w, n = s.n;
      w[n] = OP.BIND_BUFFER_RANGE; w[n + 1] = t; w[n + 2] = index; w[n + 3] = id; w[n + 4] = offset; w[n + 5] = size;
      s.n = n + 6;
      if (s.n >= s.limit) later(s);
    },
    copyBufferSubData(rt, wt, ro, wo, size) {
      const s = this[S];
      if (s.lost) return;
      if (ro < 0 || wo < 0 || size < 0) return fail(s, INVALID_VALUE);
      const w = s.w, n = s.n;
      w[n] = OP.COPY_BUFFER_SUB_DATA; w[n + 1] = rt; w[n + 2] = wt; w[n + 3] = ro; w[n + 4] = wo; w[n + 5] = size;
      s.n = n + 6;
      if (s.n >= s.limit) later(s);
    },
    getBufferSubData(t, offset, dst, dstOffset, length) {
      const s = this[S];
      if (s.lost) return;
      if (!isView(dst)) throw new TE("getBufferSubData: not a view");
      const size = dst.BYTES_PER_ELEMENT || 1;
      const count = dst.byteLength / size;
      const o = (dstOffset || 0) >>> 0;
      if (o > count) return fail(s, INVALID_VALUE);
      const l = (length || 0) >>> 0 || count - o;
      if (o + l > count) return fail(s, INVALID_VALUE);
      const out = new U8(dst.buffer, dst.byteOffset + o * size, l * size);
      flush(s);
      const w = s.w;
      w[0] = Q.BUFFER_SUB_DATA; w[1] = t; w[2] = offset; w[3] = out.length;
      const r = native.queryInto(s.ref, s.buffer, 4, out);
      if (r < 0) checkLost(s);
    },
    getIndexedParameter(t, i) { return ifAlive(the(this), [Q.INDEXED, t, i], undefined, null); },
    getFragDataLocation(p, name) {
      const s = this[S]; required(p, WebGLProgram);
      if (s.lost) return -1;
      const id = idOf(s, p, WebGLProgram);
      if (id === undefined) return -1;
      const v = ifAlive(s, [Q.FRAG_DATA_LOCATION, id], String(name), -1);
      return v === null ? -1 : v;
    },
    getInternalformatParameter(t, internal, p) {
      const s = this[S];
      if (s.lost) return null;
      if (p !== 0x80A9) { fail(s, INVALID_ENUM); return null; }
      return ifAlive(s, [Q.FORMAT_SAMPLES, t, internal], undefined, null);
    },
    getUniformBlockIndex(p, name) { return blockQuery(the(this), p, 0, 0, 0, String(name), 0xFFFFFFFF); },
    getActiveUniformBlockName(p, i) { return blockQuery(the(this), p, 1, i, 0, "", null); },
    getActiveUniformBlockParameter(p, i, q) { return blockQuery(the(this), p, 2, i, q, "", null); },
    uniformBlockBinding(p, index, binding) {
      const s = this[S]; required(p, WebGLProgram);
      if (s.lost) return;
      const id = idOf(s, p, WebGLProgram);
      if (id === undefined) return;
      const w = s.w, n = s.n;
      w[n] = OP.UNIFORM_BLOCK_BINDING; w[n + 1] = id; w[n + 2] = index; w[n + 3] = binding;
      s.n = n + 4;
      if (s.n >= s.limit) later(s);
    },
    getUniformIndices(p, names) {
      const s = this[S]; required(p, WebGLProgram);
      if (s.lost) return null;
      const id = idOf(s, p, WebGLProgram);
      if (id === undefined) return null;
      const out = [];
      // (asked one by one: names are few and this is not called per frame)
      for (const name of names) {
        const v = ifAlive(s, [Q.UNIFORM_INDICES, id, 1], String(name), null);
        out.push(v === null ? 0xFFFFFFFF : v[0]);
      }
      return out;
    },
    getActiveUniforms(p, indices, what) {
      const s = this[S]; required(p, WebGLProgram);
      if (s.lost) return null;
      const id = idOf(s, p, WebGLProgram);
      if (id === undefined) return null;
      const list = Array.from(indices);
      const v = ifAlive(s, [Q.ACTIVE_UNIFORMS, id, what, list.length].concat(list), undefined, null);
      return v === null ? null : Array.from(v);
    },
    texStorage2D(t, levels, internal, width, height) {
      const s = this[S];
      if (s.lost) return;
      const w = s.w, n = s.n;
      w[n] = OP.TEX_STORAGE; w[n + 1] = t; w[n + 2] = levels; w[n + 3] = internal; w[n + 4] = width; w[n + 5] = height; w[n + 6] = 1; w[n + 7] = 0;
      s.n = n + 8;
      if (s.n >= s.limit) later(s);
    },
    texStorage3D(t, levels, internal, width, height, depth) {
      const s = this[S];
      if (s.lost) return;
      const w = s.w, n = s.n;
      w[n] = OP.TEX_STORAGE; w[n + 1] = t; w[n + 2] = levels; w[n + 3] = internal; w[n + 4] = width; w[n + 5] = height; w[n + 6] = depth; w[n + 7] = 1;
      s.n = n + 8;
      if (s.n >= s.limit) later(s);
    },
    texImage3D(target, level, internal, width, height, depth, border, format, type, data, srcOffset) {
      const s = this[S];
      if (s.lost) return;
      if (isTexSource(data)) { fail(s, INVALID_OPERATION); return; }
      texImage(s, target, level, internal, width, height, depth, border, format, type, data, true, srcOffset || 0);
    },
    texSubImage3D(target, level, x, y, z, width, height, depth, format, type, data, srcOffset) {
      const s = this[S];
      if (s.lost) return;
      if (isTexSource(data)) { fail(s, INVALID_OPERATION); return; }
      texSubImage(s, target, level, x, y, z, width, height, depth, format, type, data, true, srcOffset || 0);
    },
    copyTexSubImage3D(target, level, xo, yo, zo, x, y, width, height) {
      const s = this[S];
      if (s.lost) return;
      const c = s.w, n = s.n;
      c[n] = OP.COPY_TEX_SUB_IMAGE_3D; c[n + 1] = target; c[n + 2] = level; c[n + 3] = xo; c[n + 4] = yo; c[n + 5] = zo; c[n + 6] = x; c[n + 7] = y; c[n + 8] = width; c[n + 9] = height;
      s.n = n + 10;
      if (s.n >= s.limit) later(s);
    },
    compressedTexImage3D() { const s = this[S]; if (!s.lost) fail(s, INVALID_ENUM); },
    compressedTexSubImage3D() { const s = this[S]; if (!s.lost) fail(s, INVALID_ENUM); },
    renderbufferStorageMultisample(t, samples, internal, width, height) {
      const s = this[S];
      if (s.lost) return;
      const w = s.w, n = s.n;
      w[n] = OP.RENDERBUFFER_STORAGE; w[n + 1] = t; w[n + 2] = internal; w[n + 3] = width; w[n + 4] = height; w[n + 5] = samples;
      s.n = n + 6;
      if (s.n >= s.limit) later(s);
    },
  });

  const blockQuery = (s, p, what, i, q, name, otherwise) => {
    required(p, WebGLProgram);
    if (s.lost) return otherwise;
    const id = idOf(s, p, WebGLProgram);
    if (id === undefined) return otherwise;
    const v = ifAlive(s, [Q.BLOCK, id, what, i, q], name, otherwise);
    return v === null ? otherwise : v;
  };

  const clearBuffer = (s, buffer, index, kind, data, off) => {
    if (s.lost) return;
    const o = off === undefined ? 0 : off >>> 0;
    const need = buffer === 0x1800 ? 4 : 1;
    if (o + need > data.length) return fail(s, INVALID_VALUE);
    const n = s.n, w = s.w;
    w[n] = OP.CLEAR_BUFFER; w[n + 1] = buffer; w[n + 2] = index; w[n + 3] = kind;
    for (let i = 0; i < 4; i++) {
      const v = i < need ? data[o + i] : 0;
      if (kind === 0) s.f[n + 4 + i] = v; else w[n + 4 + i] = v;
    }
    s.n = n + 8;
    s.drew = true;
    if (s.n >= s.limit) later(s);
  };

  const drawBuffersOf = (s, list) => {
    if (s.lost) return;
    const a = Array.from(list);
    if (a.length > 64) return fail(s, INVALID_VALUE);
    const n = s.n, w = s.w;
    w[n] = OP.DRAW_BUFFERS; w[n + 1] = a.length;
    for (let i = 0; i < a.length; i++) w[n + 2 + i] = a[i];
    s.n = n + 2 + a.length;
    if (s.n >= s.limit) later(s);
  };

  // ---- extensions ----
  const SUPPORTED1 = ["ANGLE_instanced_arrays", "EXT_blend_minmax", "EXT_color_buffer_half_float", "EXT_frag_depth", "EXT_shader_texture_lod", "EXT_sRGB", "EXT_texture_filter_anisotropic",
    "KHR_parallel_shader_compile", "OES_element_index_uint", "OES_fbo_render_mipmap", "OES_standard_derivatives", "OES_texture_float", "OES_texture_float_linear", "OES_texture_half_float",
    "OES_texture_half_float_linear", "OES_vertex_array_object", "WEBGL_color_buffer_float", "WEBGL_depth_texture", "WEBGL_draw_buffers", "WEBGL_lose_context"];
  const SUPPORTED2 = ["EXT_color_buffer_float", "EXT_color_buffer_half_float", "EXT_texture_filter_anisotropic", "KHR_parallel_shader_compile", "OES_texture_float_linear", "WEBGL_lose_context"];

  const supported = s => {
    const list = (s.webgl2 ? SUPPORTED2 : SUPPORTED1).slice();
    if (s.info[2] !== 0) list.push("WEBGL_compressed_texture_s3tc");
    if (s.info[4] !== 0 && s.webgl2) list.push("EXT_float_blend");
    if (s.info[3] === 0) {
      const at = list.indexOf("OES_texture_float_linear");
      if (at >= 0) list.splice(at, 1);
    }
    return list.sort();
  };

  const enableExt = (s, e) => {
    const n = s.n;
    s.w[n] = OP.ENABLE_EXTENSION;
    s.w[n + 1] = e;
    s.n = n + 2;
    if (s.n >= s.limit) later(s);
  };

  const iface = (name, proto, values) => {
    const c = tagged(class { constructor() { if (arguments[0] !== TOKEN) illegal(); } }, name);
    for (const k of Object.keys(values)) defineProperty(c.prototype, k, { value: values[k], enumerable: true });
    for (const k of Object.keys(proto)) {
      defineProperty(c.prototype, k, { value: proto[k], writable: true, enumerable: true, configurable: true });
    }
    return c;
  };

  const extDefs = {
    ANGLE_instanced_arrays: s => {
      enableExt(s, EXT.instanced);
      return iface("ANGLE_instanced_arrays", {
        drawArraysInstancedANGLE(mode, first, count, instances) { const g = this[S].gl; g2.drawArraysInstanced.call(g, mode, first, count, instances); },
        drawElementsInstancedANGLE(mode, count, type, offset, instances) { const g = this[S].gl; g2.drawElementsInstanced.call(g, mode, count, type, offset, instances); },
        vertexAttribDivisorANGLE(i, d) { const g = this[S].gl; g2.vertexAttribDivisor.call(g, i, d); },
      }, { VERTEX_ATTRIB_ARRAY_DIVISOR_ANGLE: 0x88FE });
    },
    EXT_blend_minmax: s => { enableExt(s, EXT.blend_minmax); return iface("EXT_blend_minmax", {}, { MIN_EXT: 0x8007, MAX_EXT: 0x8008 }); },
    EXT_color_buffer_half_float: s => { enableExt(s, EXT.color_buffer_half_float); return iface("EXT_color_buffer_half_float", {}, { RGBA16F_EXT: 0x881A, RGB16F_EXT: 0x881B, FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE_EXT: 0x8211, UNSIGNED_NORMALIZED_EXT: 0x8C17 }); },
    EXT_color_buffer_float: s => { enableExt(s, EXT.color_buffer_float); return iface("EXT_color_buffer_float", {}, {}); },
    EXT_float_blend: s => iface("EXT_float_blend", {}, {}),
    EXT_frag_depth: s => { enableExt(s, EXT.frag_depth); return iface("EXT_frag_depth", {}, {}); },
    EXT_shader_texture_lod: s => { enableExt(s, EXT.shader_texture_lod); return iface("EXT_shader_texture_lod", {}, {}); },
    EXT_sRGB: s => { enableExt(s, EXT.srgb); return iface("EXT_sRGB", {}, { SRGB_EXT: 0x8C40, SRGB_ALPHA_EXT: 0x8C42, SRGB8_ALPHA8_EXT: 0x8C43, FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING_EXT: 0x8210 }); },
    EXT_texture_filter_anisotropic: s => { enableExt(s, EXT.anisotropic); return iface("EXT_texture_filter_anisotropic", {}, { TEXTURE_MAX_ANISOTROPY_EXT: 0x84FE, MAX_TEXTURE_MAX_ANISOTROPY_EXT: 0x84FF }); },
    KHR_parallel_shader_compile: s => iface("KHR_parallel_shader_compile", {}, { COMPLETION_STATUS_KHR: 0x91B1 }),
    OES_element_index_uint: s => { enableExt(s, EXT.element_index_uint); return iface("OES_element_index_uint", {}, {}); },
    OES_fbo_render_mipmap: s => iface("OES_fbo_render_mipmap", {}, {}),
    OES_standard_derivatives: s => { enableExt(s, EXT.standard_derivatives); return iface("OES_standard_derivatives", {}, { FRAGMENT_SHADER_DERIVATIVE_HINT_OES: 0x8B8B }); },
    OES_texture_float: s => { enableExt(s, EXT.texture_float); return iface("OES_texture_float", {}, {}); },
    OES_texture_float_linear: s => { enableExt(s, EXT.texture_float_linear); return iface("OES_texture_float_linear", {}, {}); },
    OES_texture_half_float: s => { enableExt(s, EXT.texture_half_float); return iface("OES_texture_half_float", {}, { HALF_FLOAT_OES: 0x8D61 }); },
    OES_texture_half_float_linear: s => { enableExt(s, EXT.texture_half_float_linear); return iface("OES_texture_half_float_linear", {}, {}); },
    OES_vertex_array_object: s => {
      enableExt(s, EXT.vao);
      return iface("OES_vertex_array_object", {
        createVertexArrayOES() { return g2.createVertexArray.call(this[S].gl); },
        deleteVertexArrayOES(o) { g2.deleteVertexArray.call(this[S].gl, o); },
        isVertexArrayOES(o) { return g2.isVertexArray.call(this[S].gl, o); },
        bindVertexArrayOES(o) { g2.bindVertexArray.call(this[S].gl, o); },
      }, { VERTEX_ARRAY_BINDING_OES: 0x85B5 });
    },
    WEBGL_color_buffer_float: s => { enableExt(s, EXT.color_buffer_float); return iface("WEBGL_color_buffer_float", {}, { RGBA32F_EXT: 0x8814, FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE_EXT: 0x8211, UNSIGNED_NORMALIZED_EXT: 0x8C17 }); },
    WEBGL_compressed_texture_s3tc: s => { enableExt(s, EXT.s3tc); return iface("WEBGL_compressed_texture_s3tc", {}, { COMPRESSED_RGB_S3TC_DXT1_EXT: 0x83F0, COMPRESSED_RGBA_S3TC_DXT1_EXT: 0x83F1, COMPRESSED_RGBA_S3TC_DXT3_EXT: 0x83F2, COMPRESSED_RGBA_S3TC_DXT5_EXT: 0x83F3 }); },
    WEBGL_depth_texture: s => { enableExt(s, EXT.depth_texture); return iface("WEBGL_depth_texture", {}, { UNSIGNED_INT_24_8_WEBGL: 0x84FA }); },
    WEBGL_draw_buffers: s => {
      enableExt(s, EXT.draw_buffers);
      const values = { MAX_COLOR_ATTACHMENTS_WEBGL: 0x8CDF, MAX_DRAW_BUFFERS_WEBGL: 0x8824 };
      for (let i = 0; i < 16; i++) {
        values["COLOR_ATTACHMENT" + i + "_WEBGL"] = 0x8CE0 + i;
        values["DRAW_BUFFER" + i + "_WEBGL"] = 0x8825 + i;
      }
      return iface("WEBGL_draw_buffers", { drawBuffersWEBGL(list) { drawBuffersOf(this[S], list); } }, values);
    },
    WEBGL_lose_context: s => iface("WEBGL_lose_context", {
      loseContext() {
        const st = this[S];
        if (st.lost) { fail(st, INVALID_OPERATION); return; }
        flush(st);
        native.lose(st.ref);
        markLost(st);
        // the event comes in a task of its own, as the specification says
        setTimeoutFn(() => fireLost(st), 0);
      },
      restoreContext() {
        const st = this[S];
        if (!st.lost) { fail(st, INVALID_OPERATION); return; }
        if (!st.preventedRestore) return;
        setTimeoutFn(() => restore(st), 0);
      },
    }, {}),
  };

  // An extension's object: one per context. (Its `this` gives the context's state.)
  const extension = (s, name) => {
    let found = null;
    for (const n of supported(s)) if (n.toLowerCase() === name.toLowerCase()) found = n;
    if (found === null) return null;
    const known = s.exts.get(found);
    if (known !== undefined) return known;
    const def = extDefs[found];
    if (def === undefined) return null;
    const cls = def(s);
    const o = new cls(TOKEN);
    if (found === "WEBGL_lose_context" || found === "WEBGL_draw_buffers") o[S] = s; else o[S] = s;
    s.exts.set(found, o);
    return o;
  };

  // ---- the two contexts ----
  const defineConstants = (cls, table) => {
    for (const k of Object.keys(table)) {
      const d = { value: table[k], enumerable: true };
      defineProperty(cls, k, d);
      defineProperty(cls.prototype, k, d);
    }
  };

  const WebGLRenderingContext = tagged(class { constructor() { if (arguments[0] !== TOKEN) illegal(); } }, "WebGLRenderingContext");
  const WebGL2RenderingContext = tagged(class { constructor() { if (arguments[0] !== TOKEN) illegal(); } }, "WebGL2RenderingContext");
  defineConstants(WebGLRenderingContext, CONSTANTS1);
  defineConstants(WebGL2RenderingContext, CONSTANTS1);
  defineConstants(WebGL2RenderingContext, CONSTANTS2);
  commands(WebGLRenderingContext.prototype, false);
  commands(WebGL2RenderingContext.prototype, true);
  const g2 = WebGL2RenderingContext.prototype;

  // Reading a WebGL canvas from elsewhere needs what was drawn so far: these functions of the realm look first.
  const before = (proto, name) => {
    const d = proto && Object.getOwnPropertyDescriptor(proto, name);
    if (d === undefined || typeof d.value !== "function") return;
    const f = d.value;
    const wrapped = { [name](source) { syncCanvas(name === "drawImage" || name === "createPattern" || name === "createImageBitmap" ? source : this, name === "transferToImageBitmap"); return apply(f, this, arguments); } }[name];
    defineProperty(wrapped, "length", { value: f.length, configurable: true });
    defineProperty(proto, name, { value: wrapped, writable: d.writable, enumerable: d.enumerable, configurable: d.configurable });
  };
  if (HTMLCanvas !== undefined) {
    before(HTMLCanvas.prototype, "toDataURL");
    before(HTMLCanvas.prototype, "toBlob");
  }
  if (Offscreen !== undefined) {
    before(Offscreen.prototype, "convertToBlob");
    before(Offscreen.prototype, "transferToImageBitmap");
  }
  if (global.CanvasRenderingContext2D !== undefined) {
    before(global.CanvasRenderingContext2D.prototype, "drawImage");
    before(global.CanvasRenderingContext2D.prototype, "createPattern");
  }
  if (global.OffscreenCanvasRenderingContext2D !== undefined) before(global.OffscreenCanvasRenderingContext2D.prototype, "drawImage");
  if (typeof global.createImageBitmap === "function") before(global, "createImageBitmap");

  return { getContext, notify, syncCanvas, WebGLRenderingContext, WebGL2RenderingContext, WebGLContextEvent, ...classes };
})
