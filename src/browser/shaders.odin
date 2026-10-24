package browser

import "toolkit:draw"
import "toolkit:render"
import "wb:style"

////////////////////////////////
// Built-in shaders: `-wren-shader: <name> <numbers>` on a box of one of the browser's own pages (style/wren_shader.odin; a web page
// cannot name one: the property is invalid there). The box is filled by a fragment shader of the toolkit (docs/shaders.md) over its
// background, inside the background's rounded clip, before its border and its content.
//
// The registry below is the only way to a shader: a name selects an entry, each entry declares its arguments, its textures (made
// here, natively, never taken from the page) and its passes (a blend mode each). Nothing a page writes reaches a shader but numbers.
//
// What the shader reads, as vec4 slots of the draw (app_param): 0 = the engine's (the box in device pixels, pixels per CSS pixel, 1
// when the user asked for less motion), 1 = the pass (x), then the arguments of the property, four to a slot from slot 2. A missing
// argument is its default. Where the shader cannot be had (the renderer refused the module, a picture is being recorded) nothing
// is drawn and the box keeps its CSS background: every page that uses a shader gives it one that reads well without.

Shader_Texture :: enum u8 { None, Card_Normals }

Shader_Pass :: struct {
	blend: render.App_Blend,
}

Shader_Def :: struct {
	name:      string,
	wgsl:      string,
	dxbc:      []u8,
	hash:      string,
	args:      []string,                                   // their names, in the order the property gives them (documentation, and the count)
	defaults:  []f32,                                      // the value of an argument the property does not give
	textures:  [render.MAX_APP_TEXTURES]Shader_Texture,
	passes:    []Shader_Pass,
}

CARD_FOIL_WGSL :: #load("shaders/card_foil.wgsl", string)
CARD_FOIL_DXBC :: #load("shaders/card_foil.dxbc")
CARD_FOIL_HASH :: #load("shaders/card_foil.sha256", string)

@(private = "file") CARD_FOIL_PASSES := [?]Shader_Pass{{.Normal}, {.Add}}

SHADERS := [?]Shader_Def{
	{
		name = "card-foil", wgsl = CARD_FOIL_WGSL, dxbc = CARD_FOIL_DXBC, hash = CARD_FOIL_HASH,
		args = {"sweep", "pointer-x", "pointer-y", "live", "intensity"},
		defaults = {0.5, 0.5, 0.5, 0, 1},
		textures = {0 = .Card_Normals},
		passes = CARD_FOIL_PASSES[:],
	},
}

shader_def :: proc(name: string) -> ^Shader_Def {
	for &d in SHADERS { if d.name == name { return &d } }
	return nil
}

// The shader and textures of one entry on one renderer (the UI thread's).
@(private)
Shader_State :: struct {
	renderer: u64,                  // render.renderer_id
	device:   u64,                  // render.Renderer.device_generation: textures lose their contents with the device
	handle:   render.App_Shader,
	textures: [render.MAX_APP_TEXTURES]render.Texture,
	failed:   bool,                 // the renderer refused it: not tried again until the renderer changes
	live:     bool,
}

@(private) @(thread_local) shader_states: [len(SHADERS)]Shader_State

// The state of entry `i` ready for `r`: made on first use, made again when the renderer was replaced, its textures filled again when
// the device was lost. The GPU objects belong to the renderer, which frees them when it is destroyed (nothing here owns memory).
@(private = "file")
shader_ready :: proc(r: ^render.Renderer, i: int) -> ^Shader_State {
	st := &shader_states[i]
	id := render.renderer_id(r)
	d := &SHADERS[i]
	if st.live && st.renderer == id {
		if st.device == r.device_generation || st.failed { return st }
		// a lost device: the renderer made the shader and the textures again under the same handles; their contents are gone
		st.device = r.device_generation
		for tk, k in d.textures { if tk != .None { shader_texture_fill(r, tk, st.textures[k]) } }
		return st
	}
	st^ = {renderer = id, device = r.device_generation, live = true}
	st.handle = render.create_app_shader(r, {name = d.name, wgsl = d.wgsl, dxbc = d.dxbc, hash = d.hash})
	if st.handle == 0 { st.failed = true; return st }
	for tk, k in d.textures {
		if tk == .None { continue }
		tex := shader_texture(r, tk)
		if tex == 0 { st.failed = true; render.destroy_app_shader(r, st.handle); st.handle = 0; return st }
		st.textures[k] = tex
	}
	return st
}

// A texture a shader asks for, made natively and uploaded.
@(private = "file")
shader_texture :: proc(r: ^render.Renderer, kind: Shader_Texture) -> render.Texture {
	tex: render.Texture
	switch kind {
	case .None: return 0
	case .Card_Normals: tex = render.create_texture_data(r, NORMAL_W, NORMAL_H, .RGBA8, mips = true)
	}
	if tex != 0 { shader_texture_fill(r, kind, tex) }
	return tex
}

@(private = "file")
shader_texture_fill :: proc(r: ^render.Renderer, kind: Shader_Texture, tex: render.Texture) {
	switch kind {
	case .None:
	case .Card_Normals:
		texels := card_normal_map()
		defer delete(texels)
		render.update_texture_data(r, tex, 0, 0, NORMAL_W, NORMAL_H, texels)
	}
}

// A box's `-wren-shader`, painted over its background in the rounded clip of the bottom background layer. `reduced`: the user asked for less
// motion (the shader decides what that changes: the card has no sweep then).
paint_wren_shader :: proc(dc: ^draw.Context, cs: ^style.Computed, area: draw.Rect, radii: [4]f32, scale: f32) {
	sc := cs.wren_shader
	if sc.name == "" || area.max.x <= area.min.x || area.max.y <= area.min.y { return }
	idx := -1
	for &d, i in SHADERS { if d.name == sc.name { idx = i; break } }
	if idx < 0 { return }
	def := &SHADERS[idx]
	st := shader_ready(dc.renderer, idx)
	if st.failed || st.handle == 0 { return }
	// the engine's slots, the pass, then the arguments four to a slot
	slots: [2 + (style.MAX_SHADER_ARGS + 3) / 4]draw.Vec4
	reduced: f32 = the_app != nil && the_app.page_settings.style.reduced_motion ? 1 : 0
	slots[0] = {area.max.x - area.min.x, area.max.y - area.min.y, scale, reduced}
	nargs := max(len(def.args), len(sc.args))
	for k in 0 ..< nargs {
		v: f32 = k < len(def.defaults) ? def.defaults[k] : 0
		if k < len(sc.args) { v = sc.args[k] }
		slots[2 + k / 4][k % 4] = v
	}
	used := 2 + (nargs + 3) / 4
	for p, pass in def.passes {
		slots[1] = {f32(pass), 0, 0, 0}
		draw.app_shader(dc, st.handle, area, slots[:used], st.textures[:], p.blend, radii)
	}
}
