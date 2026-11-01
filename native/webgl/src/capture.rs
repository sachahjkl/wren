//! Transform feedback and query objects (WebGL 2), which wgpu has not.
//!
//! **Transform feedback.** A draw with feedback active runs the program's vertex stage once more, in a pass of its own: each
//! vertex once, as a point out of the clip volume, with the vertex shader translated so that it stores what it was asked to
//! capture in the bound buffers (`translate::capture_variant`). That takes vertex shaders that write to storage
//! (`Features::VERTEX_WRITABLE_STORAGE`): an adapter without it has `MAX_TRANSFORM_FEEDBACK_*` at 0 and `beginTransformFeedback`
//! is `INVALID_OPERATION`. Vertices go where GL puts them: the position comes from `gl_VertexIndex` and `gl_InstanceIndex`.
//! Strips, fans and loops write each vertex to a buffer of the draw, then their primitives are copied out one vertex at a time.
//! The shadow of a buffer written that way is out of date until something reads it (`buffer_sync`).
//!
//! **Queries.** `ANY_SAMPLES_PASSED*` are occlusion queries, one slot per pass a GL query crosses; slots are resolved at
//! each submit and read back when mapped. A GL query's result is available when all its slots are. `TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN`
//! is counted here: it is known from the draw. That a result only shows on a later task is the realm's (web_webgl.js).

use crate::draw::{SlotLayout, LINES, LINE_LOOP, LINE_STRIP, POINTS, TRIANGLES, TRIANGLE_FAN, TRIANGLE_STRIP};
use crate::gl::*;
use crate::translate;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Buffers a program may capture to (MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS: the minimum of OpenGL ES 3.0).
pub const MAX_TF_BUFFERS: usize = 4;
/// Components, the minimums of OpenGL ES 3.0.
pub const MAX_TF_INTERLEAVED_COMPONENTS: u32 = 64;
pub const MAX_TF_SEPARATE_COMPONENTS: u32 = 4;
/// Occlusion slots between two submits. More draws in pieces than this and the context submits.
const OCCLUSION_SLOTS: u32 = 512;
/// Bytes of an occlusion result.
const OCCLUSION_RESULT_BYTES: u64 = 8;

pub const GL_TRANSFORM_FEEDBACK: u32 = 0x8E22;
pub const INTERLEAVED_ATTRIBS: u32 = 0x8C8C;
pub const SEPARATE_ATTRIBS: u32 = 0x8C8D;
pub const ANY_SAMPLES_PASSED: u32 = 0x8C2F;
pub const ANY_SAMPLES_PASSED_CONSERVATIVE: u32 = 0x8D6A;
pub const TF_PRIMITIVES_WRITTEN: u32 = 0x8C88;
pub const QUERY_RESULT: u32 = 0x8866;
pub const QUERY_RESULT_AVAILABLE: u32 = 0x8867;

/// A transform feedback object: what is bound to it and how far it has written.
#[derive(Clone, Default)]
pub struct TfObject {
    pub binds: [(u32, u64, u64); MAX_TF_BUFFERS],
    pub active: bool,
    pub paused: bool,
    pub mode: u32,
    pub program: u32,
    /// Bytes written since it began, per buffer.
    pub written: [u64; MAX_TF_BUFFERS],
}

/// What a linked program captures.
#[derive(Clone, Default)]
pub struct TfProgram {
    pub vars: Vec<translate::CaptureVar>,
    /// Words per vertex in each buffer.
    pub stride_words: Vec<u32>,
    pub separate: bool,
    pub module: std::cell::OnceCell<Option<wgpu::ShaderModule>>,
    pub layout: Option<wgpu::BindGroupLayout>,
    pub pipelines: HashMap<(Vec<SlotLayout>, Vec<BindKind>), Option<wgpu::RenderPipeline>>,
}

/// A query object.
#[derive(Clone, Copy, Default)]
pub struct QueryObj {
    pub target: u32,
    pub active: bool,
    pub ended: bool,
    pub any_samples: bool,
    pub primitives: u64,
    /// Slots not yet read back.
    pub pending: u32,
}

/// The occlusion queries of the open encoder, and those on their way back.
#[derive(Default)]
pub struct Occlusion {
    pub enabled: bool,
    pub set: Option<wgpu::QuerySet>,
    pub resolve: Option<wgpu::Buffer>,
    pub open: bool,
    pub slots: Vec<u32>,
    pub batches: Vec<OcclusionBatch>,
}

pub struct OcclusionBatch {
    staging: wgpu::Buffer,
    slots: Vec<u32>,
    ready: Arc<AtomicBool>,
}

/// What a draw does to the bound buffers, once it is checked.
struct Plan {
    /// Vertices the vertex stage runs for, per instance.
    verts: u32,
    prims: u64,
    /// Per primitive, vertices in the order they are written (relative to the first vertex); empty: as they come.
    expand: Vec<u32>,
    instances: u32,
    per_prim: u32,
}

impl Ctx {
    /// Whether this device can capture at all.
    pub fn tf_available(&self) -> bool {
        self.is_webgl2() && self.features.contains(wgpu::Features::VERTEX_WRITABLE_STORAGE) && self.device.limits().max_storage_buffers_per_shader_stage >= MAX_TF_BUFFERS as u32 && self.device.limits().max_bind_groups >= 4
    }

    fn tf_current(&mut self) -> &mut TfObject {
        let id = self.st.tf_bound;
        self.tf_objects.entry(id).or_default()
    }

    /// Transform feedback is capturing right now.
    pub fn tf_capturing(&mut self) -> bool {
        let t = self.tf_current();
        t.active && !t.paused
    }

    /// Whether a buffer is bound to the feedback that is active (it may not be read while it is written).
    fn tf_writes_to(&mut self, id: u32) -> bool {
        let t = self.tf_current();
        t.active && t.binds.iter().any(|b| b.0 == id)
    }

    pub fn tf_varyings(&mut self, program: u32, mode: u32, names: &[u8]) {
        if mode != INTERLEAVED_ATTRIBS && mode != SEPARATE_ATTRIBS {
            return self.set_error(INVALID_ENUM);
        }
        let p = self.programs.entry(program).or_insert_with(new_program);
        let text = String::from_utf8_lossy(names);
        p.tf_names = if text.is_empty() { Vec::new() } else { text.split('\n').map(str::to_string).collect() };
        p.tf_mode = mode;
        if mode == SEPARATE_ATTRIBS && p.tf_names.len() > MAX_TF_BUFFERS {
            p.tf_names.clear();
            self.set_error(INVALID_VALUE);
        }
    }

    pub fn bind_tf(&mut self, target: u32, id: u32) {
        if target != GL_TRANSFORM_FEEDBACK {
            return self.set_error(INVALID_ENUM);
        }
        if self.tf_capturing() {
            return self.set_error(INVALID_OPERATION);
        }
        self.st.tf_bound = id;
        self.tf_objects.entry(id).or_default();
    }

    pub fn delete_tf(&mut self, id: u32) {
        if id == 0 {
            return;
        }
        if self.tf_objects.get(&id).is_some_and(|t| t.active) {
            return self.set_error(INVALID_OPERATION);
        }
        self.tf_objects.remove(&id);
        if self.st.tf_bound == id {
            self.st.tf_bound = 0;
        }
    }

    pub fn begin_tf(&mut self, mode: u32) {
        if !matches!(mode, POINTS | LINES | TRIANGLES) {
            return self.set_error(INVALID_ENUM);
        }
        if !self.tf_available() {
            return self.set_error(INVALID_OPERATION);
        }
        let pid = self.st.program;
        let Some(buffers) = self.programs.get(&pid).and_then(|p| p.linked.as_ref()).map(|l| l.tf.stride_words.len()) else { return self.set_error(INVALID_OPERATION) };
        if buffers == 0 {
            return self.set_error(INVALID_OPERATION);
        }
        let t = self.tf_current();
        if t.active || t.binds[..buffers].iter().any(|b| b.0 == 0) {
            return self.set_error(INVALID_OPERATION);
        }
        t.active = true;
        t.paused = false;
        t.mode = mode;
        t.program = pid;
        t.written = [0; MAX_TF_BUFFERS];
    }

    pub fn end_tf(&mut self) {
        let t = self.tf_current();
        if !t.active {
            return self.set_error(INVALID_OPERATION);
        }
        t.active = false;
        t.paused = false;
    }

    pub fn pause_tf(&mut self) {
        let t = self.tf_current();
        if !t.active || t.paused {
            return self.set_error(INVALID_OPERATION);
        }
        t.paused = true;
    }

    pub fn resume_tf(&mut self) {
        let program = self.st.program;
        let t = self.tf_current();
        if !t.active || !t.paused || t.program != program {
            return self.set_error(INVALID_OPERATION);
        }
        t.paused = false;
    }

    /// bindBufferBase and bindBufferRange on TRANSFORM_FEEDBACK_BUFFER.
    pub fn bind_tf_buffer(&mut self, index: u32, id: u32, off: u64, size: u64) {
        if index as usize >= MAX_TF_BUFFERS {
            return self.set_error(INVALID_VALUE);
        }
        if off % 4 != 0 || (size != u32::MAX as u64 && size % 4 != 0) {
            return self.set_error(INVALID_VALUE);
        }
        if self.tf_current().active {
            return self.set_error(INVALID_OPERATION);
        }
        if id != 0 {
            self.buffers.entry(id).or_insert_with(new_buf);
        }
        self.tf_current().binds[index as usize] = (id, off, size);
        self.st.tf_buffer = id;
    }

    // ---- a draw with feedback active ----

    /// The checks of OpenGL ES 3.0 and WebGL 2; what the draw will write.
    fn tf_plan(&mut self, l: &Linked, mode: u32, first_count: u32, instances: u32) -> Result<Plan, u32> {
        let tf = self.tf_current().clone();
        let (per_prim, prims_of): (u32, fn(u32) -> u32) = match (tf.mode, mode) {
            (POINTS, POINTS) => (1, |n| n),
            (LINES, LINES) => (2, |n| n / 2),
            (LINES, LINE_STRIP) => (2, |n| n.saturating_sub(1)),
            (LINES, LINE_LOOP) => (2, |n| if n >= 2 { n } else { 0 }),
            (TRIANGLES, TRIANGLES) => (3, |n| n / 3),
            (TRIANGLES, TRIANGLE_STRIP | TRIANGLE_FAN) => (3, |n| n.saturating_sub(2)),
            _ => return Err(INVALID_OPERATION),
        };
        let prims = prims_of(first_count);
        let out_vertices = prims as u64 * per_prim as u64 * instances as u64;
        // the room there is (GL: an overflow is an error, before anything is drawn)
        for (i, stride) in l.tf.stride_words.iter().enumerate() {
            let (id, off, size) = tf.binds[i];
            let have = self.buffers.get(&id).map_or(0, |b| b.shadow.len()) as u64;
            let room = if size == u32::MAX as u64 { have.saturating_sub(off) } else { size.min(have.saturating_sub(off)) };
            if tf.written[i] + out_vertices * *stride as u64 * 4 > room {
                return Err(INVALID_OPERATION);
            }
        }
        let expand: Vec<u32> = match mode {
            LINE_STRIP => (0..prims).flat_map(|p| [p, p + 1]).collect(),
            LINE_LOOP => (0..prims).flat_map(|p| [p, (p + 1) % first_count]).collect(),
            // (GL's order: every other triangle swaps its first two)
            TRIANGLE_STRIP => (0..prims).flat_map(|p| if p % 2 == 0 { [p, p + 1, p + 2] } else { [p + 1, p, p + 2] }).collect(),
            TRIANGLE_FAN => (0..prims).flat_map(|p| [0, p + 1, p + 2]).collect(),
            _ => Vec::new(),
        };
        // the direct modes write only whole primitives
        let verts = if expand.is_empty() { prims * per_prim } else { first_count };
        Ok(Plan { verts, prims: prims as u64 * instances as u64, expand, instances, per_prim })
    }

    /// The capture's layout, its pipeline for these streams.
    fn tf_pipeline(&mut self, l: &mut Linked, slots: &[SlotLayout], binds: &[BindKind]) -> Result<Option<wgpu::RenderPipeline>, u32> {
        let key = (slots.to_vec(), binds.to_vec());
        if let Some(p) = l.tf.pipelines.get(&key) {
            return Ok(p.clone());
        }
        let device = self.device.clone();
        let caps = self.caps.clone();
        let (shader, map, vars) = (l.vs_shader.clone(), l.map.clone(), l.tf.vars.clone());
        let stride = l.tf.stride_words.clone();
        let module = l.tf.module.get_or_init(|| match translate::capture_variant(&shader, &map, &caps, &vars, &stride) {
            Ok(m) => crate::draw::shader_module(&device, m),
            // (a shader the link accepted and this translation did not: the draw says so on the console)
            Err(_) => None,
        });
        let Some(module) = module.clone() else {
            self.warn("WebGL: this program cannot capture its varyings".to_string());
            l.tf.pipelines.insert(key, None);
            return Ok(None);
        };
        if l.tf.layout.is_none() {
            let mut entries: Vec<wgpu::BindGroupLayoutEntry> = (0..l.tf.stride_words.len() as u32)
                .map(|binding| wgpu::BindGroupLayoutEntry {
                    binding,
                    visibility: wgpu::ShaderStages::VERTEX,
                    ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Storage { read_only: false }, has_dynamic_offset: false, min_binding_size: None },
                    count: None,
                })
                .collect();
            entries.push(wgpu::BindGroupLayoutEntry {
                binding: translate::CAPTURE_PARAMS_BINDING,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: true, min_binding_size: wgpu::BufferSize::new(translate::CAPTURE_PARAMS_BYTES) },
                count: None,
            });
            l.tf.layout = Some(device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &entries }));
        }
        let bgl0 = l.bgl0.as_ref().ok_or(0u32)?;
        let bgl1 = l.layouts.get(binds).map(|x| x.0.clone()).ok_or(0u32)?;
        let empty = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor { label: None, entries: &[] });
        let bgl2 = l.bgl2.as_ref().unwrap_or(&empty);
        let tf_layout = l.tf.layout.as_ref().ok_or(0u32)?;
        let layouts = [Some(bgl0), Some(&bgl1), Some(bgl2), Some(tf_layout)];
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor { label: None, bind_group_layouts: &layouts, immediate_size: 0 });
        let attrs: Vec<Vec<wgpu::VertexAttribute>> = slots.iter().map(|s| s.attrs.iter().map(|(format, offset, loc)| wgpu::VertexAttribute { format: *format, offset: *offset as u64, shader_location: *loc }).collect()).collect();
        let buffers: Vec<Option<wgpu::VertexBufferLayout<'_>>> = slots
            .iter()
            .zip(attrs.iter())
            .map(|(s, a)| Some(wgpu::VertexBufferLayout { array_stride: s.stride as u64, step_mode: if s.instance { wgpu::VertexStepMode::Instance } else { wgpu::VertexStepMode::Vertex }, attributes: a }))
            .collect();
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let p = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("wren webgl capture"),
            layout: Some(&layout),
            vertex: wgpu::VertexState { module: &module, entry_point: Some("main"), compilation_options: Default::default(), buffers: &buffers },
            primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::PointList, ..Default::default() },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: CAPTURE_TARGET,
                depth_write_enabled: Some(false),
                depth_compare: Some(wgpu::CompareFunction::Always),
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: Default::default(),
            fragment: None,
            multiview_mask: None,
            cache: None,
        });
        let made = if let Some(e) = pollster::block_on(validation.pop()) {
            self.warn(format!("WebGL: the device refused the capture's pipeline: {}", e));
            None
        } else {
            Some(p)
        };
        l.tf.pipelines.insert(key, made.clone());
        Ok(made)
    }

    /// The pass that runs the vertex stage for its varyings. Called with everything the draw would use made, before its own pass.
    #[allow(clippy::too_many_arguments)]
    pub fn tf_capture(
        &mut self,
        l: &mut Linked,
        mode: u32,
        first: u32,
        count: u32,
        instances: u32,
        slots: &[SlotLayout],
        slot_buffers: &[(wgpu::Buffer, u64)],
        binds: &[BindKind],
        tex_group: Option<&wgpu::BindGroup>,
        block_group: Option<&wgpu::BindGroup>,
    ) -> Result<(), u32> {
        let plan = self.tf_plan(l, mode, count, instances)?;
        if plan.prims == 0 {
            return Ok(());
        }
        let Some(pipeline) = self.tf_pipeline(l, slots, binds)? else { return Err(INVALID_OPERATION) };
        let tf = self.tf_current().clone();
        let n_buffers = l.tf.stride_words.len();
        let device = self.device.clone();
        let align = self.device.limits().min_storage_buffer_offset_alignment as u64;
        // where to write: the bound buffers, or a buffer of this draw when primitives have to be put together afterwards
        let direct = plan.expand.is_empty();
        let mut targets: Vec<(wgpu::Buffer, u64, u64)> = Vec::with_capacity(n_buffers); // (buffer, offset bound, bytes bound)
        let mut bases = [0u32; MAX_TF_BUFFERS];
        for i in 0..n_buffers {
            if direct {
                let (id, off, _) = tf.binds[i];
                let b = self.buffers.get_mut(&id).ok_or(INVALID_OPERATION)?;
                let gpu = b.gpu.clone().ok_or(INVALID_OPERATION)?;
                let at = off + tf.written[i];
                let start = at / align * align;
                bases[i] = ((at - start) / 4) as u32;
                // (a binding has a largest size; the room was checked against what is written)
                let largest = self.device.limits().max_storage_buffer_binding_size as u64 / 4 * 4;
                targets.push((gpu.clone(), start, (gpu.size() - start).min(largest)));
            } else {
                let bytes = plan.verts as u64 * plan.instances as u64 * l.tf.stride_words[i] as u64 * 4;
                let temp = device.create_buffer(&wgpu::BufferDescriptor { label: Some("wren webgl capture"), size: bytes.max(4), usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC, mapped_at_creation: false });
                targets.push((temp, 0, bytes.max(4)));
            }
        }
        // the parameters, in the ring
        let mut params = [0u8; translate::CAPTURE_PARAMS_BYTES as usize];
        params[0..4].copy_from_slice(&first.to_ne_bytes());
        params[4..8].copy_from_slice(&plan.verts.to_ne_bytes());
        for (i, b) in bases.iter().enumerate() {
            params[16 + i * 4..20 + i * 4].copy_from_slice(&b.to_ne_bytes());
        }
        let ubo = self.limits.ubo_align;
        let params_at = self.ring_alloc_public(&params, ubo).map_err(|_| OUT_OF_MEMORY)?;
        let mut entries: Vec<wgpu::BindGroupEntry> = targets
            .iter()
            .enumerate()
            .map(|(i, (b, off, size))| wgpu::BindGroupEntry { binding: i as u32, resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: b, offset: *off, size: wgpu::BufferSize::new(*size) }) })
            .collect();
        entries.push(wgpu::BindGroupEntry {
            binding: translate::CAPTURE_PARAMS_BINDING,
            resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding { buffer: &self.ring, offset: 0, size: wgpu::BufferSize::new(translate::CAPTURE_PARAMS_BYTES) }),
        });
        let group = device.create_bind_group(&wgpu::BindGroupDescriptor { label: None, layout: l.tf.layout.as_ref().ok_or(0u32)?, entries: &entries });
        let empty_group = self.utility_empty_group_public();
        self.end_pass();
        self.ensure_encoder();
        let view = self.capture_target_view();
        {
            let enc = self.encoder.as_mut().ok_or(0u32)?;
            let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("wren webgl capture"),
                color_attachments: &[],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment { view: &view, depth_ops: Some(wgpu::Operations { load: wgpu::LoadOp::Clear(1.0), store: wgpu::StoreOp::Discard }), stencil_ops: None }),
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&pipeline);
            let bg0 = l.bg0.as_ref().ok_or(0u32)?;
            if l.fs_image.is_empty() {
                pass.set_bind_group(0, bg0, &[l.vs_at]);
            } else {
                pass.set_bind_group(0, bg0, &[l.vs_at, l.fs_at]);
            }
            pass.set_bind_group(1, tex_group.unwrap_or(&empty_group), &[]);
            pass.set_bind_group(2, block_group.unwrap_or(&empty_group), &[]);
            pass.set_bind_group(3, &group, &[params_at]);
            for (i, (b, off)) in slot_buffers.iter().enumerate() {
                pass.set_vertex_buffer(i as u32, b.slice(*off..));
            }
            pass.draw(first..first + plan.verts, 0..plan.instances);
        }
        // strips, fans and loops: their primitives, vertex by vertex
        if !direct {
            let enc = self.encoder.as_mut().ok_or(0u32)?;
            for i in 0..n_buffers {
                let (id, off, _) = tf.binds[i];
                let stride = l.tf.stride_words[i] as u64 * 4;
                let gpu = self.buffers.get(&id).and_then(|b| b.gpu.clone()).ok_or(INVALID_OPERATION)?;
                let mut to = off + tf.written[i];
                for inst in 0..plan.instances as u64 {
                    for v in &plan.expand {
                        enc.copy_buffer_to_buffer(&targets[i].0, (inst * plan.verts as u64 + *v as u64) * stride, &gpu, to, stride);
                        to += stride;
                    }
                }
            }
        }
        // what it wrote
        let out = plan.prims * plan.per_prim as u64;
        let bytes: Vec<u64> = l.tf.stride_words.iter().map(|s| out * *s as u64 * 4).collect();
        let id = self.st.tf_bound;
        if let Some(t) = self.tf_objects.get_mut(&id) {
            for (i, b) in bytes.iter().enumerate() {
                t.written[i] += *b;
            }
        }
        for i in 0..n_buffers {
            let bid = tf.binds[i].0;
            if let Some(b) = self.buffers.get_mut(&bid) {
                b.gpu_newer = true;
                b.version += 1;
                b.max_index.clear();
                b.converted.clear();
                b.expanded.clear();
            }
        }
        let q = self.st.tf_query;
        if q != 0 {
            if let Some(o) = self.queries.get_mut(&q) {
                o.primitives += plan.prims;
            }
        }
        Ok(())
    }

    /// What a draw may not do while feedback is active: read a buffer it writes (WebGL 2).
    pub fn tf_check_reads(&mut self, l: &Linked, vao: &Vao) -> Result<(), u32> {
        if !self.tf_current().active {
            return Ok(());
        }
        for (_, ty, arr, loc, _) in &l.attributes {
            for k in 0..ty.cols * (*arr).max(1) {
                let index = (*loc + k) as usize;
                if index < MAX_ATTRIBS && vao.attrs[index].enabled && self.tf_writes_to(vao.attrs[index].buffer) {
                    return Err(INVALID_OPERATION);
                }
            }
        }
        for binding in l.block_bindings.clone() {
            let id = self.st.ubo_ranges[binding as usize].0;
            if id != 0 && self.tf_writes_to(id) {
                return Err(INVALID_OPERATION);
            }
        }
        Ok(())
    }

    fn capture_target_view(&mut self) -> wgpu::TextureView {
        if let Some(v) = &self.capture_target {
            return v.clone();
        }
        let t = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("wren webgl capture"),
            size: wgpu::Extent3d { width: 1, height: 1, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: CAPTURE_TARGET,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        let v = t.create_view(&Default::default());
        self.capture_target = Some(v.clone());
        v
    }

    /// The shadow of a buffer that feedback wrote: brought back before something reads or patches it.
    pub fn buffer_sync(&mut self, id: u32) {
        let Some(b) = self.buffers.get(&id) else { return };
        if !b.gpu_newer {
            return;
        }
        let Some(gpu) = b.gpu.clone() else { return };
        let size = (b.shadow.len() as u64).div_ceil(4) * 4;
        let staging = self.device.create_buffer(&wgpu::BufferDescriptor { label: Some("wren webgl sync"), size: size.max(4), usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
        self.end_pass();
        self.ensure_encoder();
        if let Some(enc) = self.encoder.as_mut() {
            enc.copy_buffer_to_buffer(&gpu, 0, &staging, 0, size);
        }
        self.submit();
        let slice = staging.slice(..);
        let ok = Arc::new(AtomicBool::new(false));
        let done = ok.clone();
        slice.map_async(wgpu::MapMode::Read, move |r| done.store(r.is_ok(), Ordering::SeqCst));
        let _ = self.device.poll(wgpu::PollType::wait_indefinitely());
        if ok.load(Ordering::SeqCst) {
            if let Ok(view) = slice.get_mapped_range() {
                if let Some(b) = self.buffers.get_mut(&id) {
                    let n = b.shadow.len();
                    b.shadow.copy_from_slice(&view[..n]);
                    b.gpu_newer = false;
                }
            }
            staging.unmap();
        }
    }

    // ---- queries ----

    fn query_slot(target: u32) -> Option<bool> {
        match target {
            ANY_SAMPLES_PASSED | ANY_SAMPLES_PASSED_CONSERVATIVE => Some(true),
            TF_PRIMITIVES_WRITTEN => Some(false),
            _ => None,
        }
    }

    pub fn begin_query(&mut self, target: u32, id: u32) {
        let Some(occlusion) = Self::query_slot(target) else { return self.set_error(INVALID_ENUM) };
        if id == 0 || (occlusion && self.st.occlusion_query != 0) || (!occlusion && self.st.tf_query != 0) {
            return self.set_error(INVALID_OPERATION);
        }
        let q = self.queries.entry(id).or_default();
        if q.active || (q.target != 0 && q.target != target) {
            return self.set_error(INVALID_OPERATION);
        }
        *q = QueryObj { target, active: true, ..QueryObj::default() };
        if occlusion {
            self.st.occlusion_query = id;
            if !self.occlusion.enabled {
                // (a set is attached when a pass starts: the next one has it)
                self.occlusion.enabled = true;
                self.end_pass();
            }
        } else {
            self.st.tf_query = id;
        }
    }

    pub fn end_query(&mut self, target: u32) {
        let Some(occlusion) = Self::query_slot(target) else { return self.set_error(INVALID_ENUM) };
        let id = if occlusion { self.st.occlusion_query } else { self.st.tf_query };
        let wanted = self.queries.get(&id).map_or(0, |q| q.target);
        if id == 0 || (wanted != target) {
            return self.set_error(INVALID_OPERATION);
        }
        if occlusion {
            self.occlusion_close();
            self.st.occlusion_query = 0;
        } else {
            self.st.tf_query = 0;
        }
        if let Some(q) = self.queries.get_mut(&id) {
            q.active = false;
            q.ended = true;
        }
    }

    pub fn delete_query(&mut self, id: u32) {
        if self.st.occlusion_query == id && id != 0 {
            self.occlusion_close();
            self.st.occlusion_query = 0;
        }
        if self.st.tf_query == id {
            self.st.tf_query = 0;
        }
        self.queries.remove(&id);
    }

    /// The occlusion query set a new pass carries, if the context has used one.
    pub fn occlusion_set_for_pass(&mut self) -> Option<wgpu::QuerySet> {
        if !self.occlusion.enabled {
            return None;
        }
        if self.occlusion.set.is_none() {
            self.occlusion.set = Some(self.device.create_query_set(&wgpu::QuerySetDescriptor { label: Some("wren webgl occlusion"), ty: wgpu::QueryType::Occlusion, count: OCCLUSION_SLOTS }));
            self.occlusion.resolve = Some(self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("wren webgl occlusion"),
                size: OCCLUSION_SLOTS as u64 * OCCLUSION_RESULT_BYTES,
                usage: wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC,
                mapped_at_creation: false,
            }));
        }
        self.occlusion.set.clone()
    }

    /// Before a draw's pass: the slots of this encoder are not all taken.
    pub fn occlusion_room(&mut self) {
        if self.st.occlusion_query != 0 && self.occlusion.slots.len() as u32 >= OCCLUSION_SLOTS {
            self.submit();
        }
    }

    /// (a pass open, which has the set) A draw counts for the query that is active.
    pub fn occlusion_open_for_draw(&mut self) {
        let q = self.st.occlusion_query;
        if q == 0 || self.occlusion.open {
            return;
        }
        let slot = self.occlusion.slots.len() as u32;
        let Some(pass) = self.pass.as_mut() else { return };
        pass.begin_occlusion_query(slot);
        self.occlusion.open = true;
        self.occlusion.slots.push(q);
        if let Some(o) = self.queries.get_mut(&q) {
            o.pending += 1;
        }
    }

    /// The open slot ends: before the pass does, or the query.
    pub fn occlusion_close(&mut self) {
        if !self.occlusion.open {
            return;
        }
        self.occlusion.open = false;
        if let Some(pass) = self.pass.as_mut() {
            pass.end_occlusion_query();
        }
    }

    /// (before an encoder is finished) The slots it wrote go to a staging buffer.
    pub fn occlusion_resolve(&mut self) -> Option<(wgpu::Buffer, Vec<u32>)> {
        if self.occlusion.slots.is_empty() {
            return None;
        }
        let n = self.occlusion.slots.len() as u32;
        let (set, resolve) = (self.occlusion.set.clone()?, self.occlusion.resolve.clone()?);
        let staging = self.device.create_buffer(&wgpu::BufferDescriptor { label: Some("wren webgl occlusion"), size: n as u64 * OCCLUSION_RESULT_BYTES, usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
        let enc = self.encoder.as_mut()?;
        enc.resolve_query_set(&set, 0..n, &resolve, 0);
        enc.copy_buffer_to_buffer(&resolve, 0, &staging, 0, n as u64 * OCCLUSION_RESULT_BYTES);
        Some((staging, std::mem::take(&mut self.occlusion.slots)))
    }

    /// (after the submit) It comes back when it can.
    pub fn occlusion_submitted(&mut self, staging: wgpu::Buffer, slots: Vec<u32>) {
        let ready = Arc::new(AtomicBool::new(false));
        let flag = ready.clone();
        staging.slice(..).map_async(wgpu::MapMode::Read, move |r| flag.store(r.is_ok(), Ordering::SeqCst));
        self.occlusion.batches.push(OcclusionBatch { staging, slots, ready });
    }

    /// What has come back.
    fn occlusion_collect(&mut self) {
        let batches = std::mem::take(&mut self.occlusion.batches);
        for batch in batches {
            if !batch.ready.load(Ordering::SeqCst) {
                self.occlusion.batches.push(batch);
                continue;
            }
            if let Ok(view) = batch.staging.slice(..).get_mapped_range() {
                for (i, q) in batch.slots.iter().enumerate() {
                    let at = i * OCCLUSION_RESULT_BYTES as usize;
                    let v = u64::from_ne_bytes(view[at..at + OCCLUSION_RESULT_BYTES as usize].try_into().unwrap_or([0; 8]));
                    if let Some(o) = self.queries.get_mut(q) {
                        o.any_samples |= v != 0;
                        o.pending = o.pending.saturating_sub(1);
                    }
                }
            }
            batch.staging.unmap();
        }
    }

    /// getQueryParameter, as the device knows it: (available, value). `wait`: for the result, as GL's call blocks.
    pub fn query_answer(&mut self, id: u32, wait: bool) -> Option<(bool, u32)> {
        let q = *self.queries.get(&id)?;
        if q.active {
            return None;
        }
        if q.pending > 0 {
            // (what it waits for may not have been sent)
            if self.occlusion.slots.iter().any(|s| *s == id) {
                self.occlusion_close();
                self.submit();
            }
            let _ = self.device.poll(if wait { wgpu::PollType::wait_indefinitely() } else { wgpu::PollType::Poll });
            self.occlusion_collect();
        }
        let q = *self.queries.get(&id)?;
        let value = if q.target == TF_PRIMITIVES_WRITTEN { q.primitives.min(u32::MAX as u64) as u32 } else { q.any_samples as u32 };
        Some((q.pending == 0, value))
    }
}

/// The format of the attachment of a capture's pass, which nothing is ever drawn to.
pub const CAPTURE_TARGET: wgpu::TextureFormat = wgpu::TextureFormat::Depth16Unorm;

/// A vertex attribute with a divisor above 1: wgpu steps once per instance, so the values are written out per instance.
pub fn expand_divided(shadow: &[u8], offset: usize, stride: usize, size: usize, divisor: u32, instances: u32) -> Option<(Vec<u8>, u32)> {
    let out_stride = size.div_ceil(4) * 4;
    let total = (instances as usize).checked_mul(out_stride)?;
    if total > MAX_CONVERTED_STREAM_BYTES {
        return None;
    }
    let mut data = vec![0u8; total];
    for i in 0..instances as usize {
        let at = offset + (i / divisor as usize) * stride;
        let source = shadow.get(at..at + size)?;
        data[i * out_stride..i * out_stride + size].copy_from_slice(source);
    }
    Some((data, out_stride as u32))
}
