package style

import "core:strings"
import "wb:css"

// -wren-shader (non-standard): `none` | <name> <number>*. Built-in pages of the browser (about:wren...) fill a box with one of the
// shaders the browser itself ships (src/browser/shaders.odin: the registry names them, declares their arguments and textures); the
// numbers are the shader's arguments, in the order its entry lists them. A page that is not one of the browser's own pages cannot
// use the property at all: for such a document the declaration is invalid and has no effect (Settings.internal_document), and
// the name only ever selects among the built-in shaders, so there is no way to bring a shader of one's own (no WebGL by the back
// door). The arguments are written with var(): `-wren-shader: card-foil var(--sweep) var(--gx) var(--gy)`, so a registered custom
// property that an animation or a script changes reaches the computed value (which is how a repaint is asked for) like any other
// property that uses var().
//
// An argument is a <number>, a <percentage> (its value divided by 100: `50%` is 0.5) or a calc() of numbers; at most
// MAX_SHADER_ARGS of them.

MAX_SHADER_ARGS :: 28

Shader_Call :: struct {
	name: string,   // "" = none
	args: []f32,
}

@(private)
shader_names :: proc() {
	delete_key(&prop_by_name, prop_names[.Wren_Shader])
	prop_names[.Wren_Shader] = "-wren-shader"
	prop_by_name["-wren-shader"] = .Wren_Shader
}

@(private)
apply_shader_prop :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	#partial switch p {
	case .Wren_Shader:
		if !cx.settings.internal_document { return false }
		items := split_items(vs)
		if len(items) == 0 { return false }
		first := items[0]
		if first.kind != .Token || first.tok.kind != .Ident { return false }
		name := first.tok.text
		if strings.equal_fold(name, "none") {
			if len(items) != 1 { return false }
			cx.c.wren_shader = {}
			return true
		}
		if len(items) - 1 > MAX_SHADER_ARGS { return false }
		for ch in name {
			// a shader is named like a CSS identifier in the registry: letters, digits and dashes
			if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '_') { return false }
		}
		args := make([]f32, len(items) - 1, cx.alloc)
		for it, i in items[1:] {
			one := [1]css.Value{it}
			if it.kind == .Token && it.tok.kind == .Percentage {
				args[i] = f32(it.tok.num / 100)
			} else {
				n, ok := css.parse_number(one[:])
				if !ok { return false }
				args[i] = f32(n)
			}
		}
		cx.c.wren_shader = Shader_Call{name = strings.clone(strings.to_lower(name, context.temp_allocator), cx.alloc), args = args}
	case: return false
	}
	return true
}

// Whether a box paints with a shader of the browser.
has_shader :: proc(c: ^Computed) -> bool { return c != nil && c.wren_shader.name != "" }
