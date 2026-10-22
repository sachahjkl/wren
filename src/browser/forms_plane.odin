package browser

import "toolkit:draw"
import lay "wb:layout"
import "wb:style"

////////////////////////////////
// Form controls in 3D planes: where a pointer is on a control painted in a plane.
//
// A control is painted in the layer of its plane, in the box's own coordinates, under the transform stack the painter pushed
// (draw.current_transform: the 2D transforms inside the plane, then the layer's texel map). The plane is later composited as a
// projected quad: screen = H(frame), with a perspective divide, so a pointer position goes back through the inverse of H (exact:
// a homography is invertible, no affine fit), then out of the layer's texels and the stack's transform, to the coordinates the
// control's content rect is in.

// The plane a control is being painted in, set by the painter for each control item (effects_for): plane layer frame -> screen
// (the draw space of the page), through the planes that receive it.
Ctl_Plane :: struct {
	ok: bool,
	h:  [9]f32,
}

@(private) ctl_plane: Ctl_Plane

@(private)
ctl_plane_for :: proc(e: ^Effects, it: ^lay.Display_Item) {
	ctl_plane = {}
	if it.kind != .Control { return }
	pl := e.l.spaces[it.space].plane
	if pl == lay.NONE { return }
	m := plane_matrix(e, pl)
	for d := e.l.spaces[pl].dest; d != lay.NONE; d = e.l.spaces[d].dest { m = style.m4_mul(plane_matrix(e, d), m) }
	ctl_plane = Ctl_Plane{ok = true, h = lay.plane_h3(m)}
}

// For the control being painted into `dc` under transform `xf`: the maps between its content coordinates and the screen.
@(private)
painted_projection :: proc(dc: ^draw.Context, xf: draw.Affine) -> (fwd, inv: [9]f32, ok: bool) {
	if !ctl_plane.ok { return }
	o, s, open := draw.open_plane_frame(dc)
	if !open || s <= 0 { return }
	// content coordinates u -> layer texels t = xf(u) -> plane frame w = o + t / s -> screen H(w)
	to_texels := lay.h3_from_matrix(lay.Matrix{xf.a, xf.b, xf.c, xf.d, xf.e, xf.f})
	texels_to_frame := [9]f32{1 / s, 0, o.x, 0, 1 / s, o.y, 0, 0, 1}
	fwd = lay.h3_mul(ctl_plane.h, lay.h3_mul(texels_to_frame, to_texels))
	hinv, iok := lay.h3_inverse(fwd)
	if !iok { return }
	return fwd, hinv, true
}
