package browser

import "toolkit:draw"
import "toolkit:render"
import "wb:base"
import "wb:dom"
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

Shader_Texture :: enum u8 { None, Card_Normals, Card_Engraving, Seal_Normals, Seal_Engraving }

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
		args = {"sweep", "pointer-x", "pointer-y", "live", "intensity", "engrave", "seal"},
		defaults = {0.5, 0.5, 0.5, 0, 1, 0, 0},
		textures = {0 = .Card_Normals, 1 = .Card_Engraving},
		passes = CARD_FOIL_PASSES[:],
	},
	// the certification seal stuck on the card: the same module in its seal mode, with the seal's own relief and lettering
	{
		name = "card-seal", wgsl = CARD_FOIL_WGSL, dxbc = CARD_FOIL_DXBC, hash = CARD_FOIL_HASH,
		args = {"sweep", "pointer-x", "pointer-y", "live", "intensity", "engrave", "seal"},
		defaults = {0.5, 0.5, 0.5, 0, 1, 0, 1},
		textures = {0 = .Seal_Normals, 1 = .Seal_Engraving},
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
	engraved: u64,                  // hash of the text the engraving texture holds (0: none yet)
	failed:   bool,                 // the renderer refused it: not tried again until the renderer changes
	live:     bool,
}

@(private) @(thread_local) shader_states: [len(SHADERS)]Shader_State

// The state of entry `i` ready for `r`: made on first use, made again when the renderer was replaced, its textures filled again when
// the device was lost. The GPU objects belong to the renderer, which frees them when it is destroyed (nothing here owns memory).
@(private)
shader_ready :: proc(r: ^render.Renderer, i: int) -> ^Shader_State {
	st := &shader_states[i]
	id := render.renderer_id(r)
	d := &SHADERS[i]
	if st.live && st.renderer == id {
		if st.device == r.device_generation || st.failed { return st }
		// a lost device: the renderer made the shader and the textures again under the same handles; their contents are gone
		st.device = r.device_generation
		for tk, k in d.textures { if tk != .None { shader_texture_fill(r, tk, st.textures[k]) } }
		st.engraved = 0   // the engraving is made again by the next paint
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
	case .Card_Engraving: tex = render.create_texture_data(r, ENGRAVE_W, ENGRAVE_H, .RGBA8, mips = true)
	case .Seal_Normals, .Seal_Engraving: tex = render.create_texture_data(r, SEAL_TEX, SEAL_TEX, .RGBA8, mips = true)
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
	case .Card_Engraving, .Seal_Engraving:   // its text is the box's: made by paint_wren_shader
	case .Seal_Normals:
		texels := seal_normal_map()
		defer delete(texels)
		render.update_texture_data(r, tex, 0, 0, SEAL_TEX, SEAL_TEX, texels)
	}
}

// A box's `-wren-shader`, painted over its background in the rounded clip of the bottom background layer. `doc`: its document, for the
// text a shader engraves (the box's data-engrave attribute) and to tell the page when the shader cannot be had.
paint_wren_shader :: proc(dc: ^draw.Context, cs: ^style.Computed, area: draw.Rect, radii: [4]f32, scale: f32, doc: ^dom.Document = nil) {
	sc := cs.wren_shader
	if sc.name == "" || area.max.x <= area.min.x || area.max.y <= area.min.y { return }
	idx := -1
	for &d, i in SHADERS { if d.name == sc.name { idx = i; break } }
	if idx < 0 { return }
	def := &SHADERS[idx]
	st := shader_ready(dc.renderer, idx)
	if st.failed || st.handle == 0 { shader_unavailable(doc, cs); return }
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
	// the text the shader engraves: made when it changes, for a box that asks for it (the argument "engrave" is not 0)
	for a, k in def.args {
		if a != "engrave" || slots[2 + k / 4][k % 4] == 0 { continue }
		if !engraving_ready(dc, st, def, doc, cs) {
			slots[2 + k / 4][k % 4] = 0
			shader_unavailable(doc, cs)   // the page shows its own text
		}
	}
	used := 2 + (nargs + 3) / 4
	for p, pass in def.passes {
		slots[1] = {f32(pass), 0, 0, 0}
		draw.app_shader(dc, st.handle, area, slots[:used], st.textures[:], p.blend, radii)
	}
}

// The engraving texture holds the text of the box's data-engrave attribute (made again when it changed). False: it cannot be had (no
// text on the box, no document, no font): the caller leaves the text to the page.
@(private = "file")
engraving_ready :: proc(dc: ^draw.Context, st: ^Shader_State, def: ^Shader_Def, doc: ^dom.Document, cs: ^style.Computed) -> bool {
	if doc == nil || cs.node == base.NIL_HANDLE || dc.fonts == nil { return false }
	text, found := dom.get_attribute(doc, cs.node, ENGRAVE_ATTR)
	if !found || text == "" { return false }
	h: u64 = 0xcbf29ce484222325
	for b in transmute([]u8)text { h = (h ~ u64(b)) * 0x100000001b3 }
	h |= 1
	if st.engraved == h { return true }
	for tk, k in def.textures {
		if (tk != .Card_Engraving && tk != .Seal_Engraving) || st.textures[k] == 0 { continue }
		w, h := tk == .Card_Engraving ? ENGRAVE_W : SEAL_TEX, tk == .Card_Engraving ? ENGRAVE_H : SEAL_TEX
		texels: []u8
		ok: bool
		if tk == .Card_Engraving { texels, ok = card_engraving(dc.fonts, st.renderer, text) } else { texels, ok = seal_engraving(dc.fonts, st.renderer, text) }
		if !ok { return false }
		defer delete(texels)
		render.update_texture_data(dc.renderer, st.textures[k], 0, 0, w, h, texels)
	}
	st.engraved = h
	return true
}

// A page that gives its text to a shader (the licence card) shows it itself when the shader cannot: it asks by an attribute its style reads
// (.lic[data-shader=off] .face): on the parent of the box. Set once.
@(private = "file")
shader_unavailable :: proc(doc: ^dom.Document, cs: ^style.Computed) {
	if doc == nil || cs.node == base.NIL_HANDLE { return }
	n := dom.get(doc, cs.node)
	if n == nil || n.parent == base.NIL_HANDLE { return }
	if v, ok := dom.get_attribute(doc, n.parent, "data-shader"); ok && v == "off" { return }
	dom.set_attribute(doc, n.parent, "data-shader", "off")
}