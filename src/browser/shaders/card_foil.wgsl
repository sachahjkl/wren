// card-foil: the licence card of about:wren (src/browser/shaders.odin lists it; the toolkit's docs/shaders.md describes the frame this is
// written in: rect.wgsl + app.wgsl + this file, app_shade returns linear light with straight alpha).
//
// The card is a banknote's foil under two lights. Its relief is a normal map (about_card_relief.odin: a guilloche of two rosettes, a lipped
// frame with a groove, micro-lettering, a grain) in texture 0: R G the normal's x y, B the height, A the cavity. Texture 1 is the card's TEXT,
// engraved (about_card_engrave.odin: R G the normal of the bevel of the letters, B their coverage, A the blurred coverage): the letters are cut
// into the metal, lit by the same lights and made of GOLD: a flat floor that shines with a brushed, anisotropic highlight, walls that catch the
// light on one side and fall into shade on the other, a dark engraving around them. The guilloche, the glitter and the film are calmed around
// the letters so that they read. The shader is drawn in two passes over the card's dark background:
//   pass 0, blend Normal   the engraving's shade: black where the relief hollows (and where the letters' walls are), so the lines read as cut;
//   pass 1, blend Add      the light: for each of two point lights (one that sweeps across the card, one that follows the pointer)
//                          an ANISOTROPIC highlight (brushed metal: Ward's model, long across the brushing, short along it), an
//                          iridescent wash (a thin film: the hue goes round the spectrum with the angle the normal makes with the eye),
//                          glitter (a grid of tiny flakes, each with a normal of its own, that flash where the light mirrors into the
//                          eye) and a fresnel rim on the lip; in the letters, the same light on gold. The eye's direction comes from the tilt.
// Arguments (CSS: -wren-shader: card-foil <sweep> <x> <y> <live> <intensity> <engrave>, after the engine's two vec4):
//   sweep      0 .. 1 the sweeping light's way across the card (it enters at the bottom left, leaves at the top right; outside: off)
//   x, y       0 .. 1 where the pointer is on the card (0.5, 0.5 at rest); the tilt of the card, and the second light
//   live       0 .. 1 the pointer is on the card: the sweep dims, the pointer's light shines
//   intensity  the overall strength of the light pass
//   engrave    1: texture 1 holds the text to engrave; 0: none (the page draws its own text)

const PI: f32 = 3.14159265;

fn foil_pcg(v: u32) -> u32 {
	let s = v * 747796405u + 2891336453u;
	let w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}

// Two numbers in 0 .. 1 for a cell of the flake grid (the same on every GPU).
fn foil_cell(c: vec2<i32>) -> float2 {
	let a = foil_pcg(u32(c.x) + foil_pcg(u32(c.y)));
	let b = foil_pcg(a + 0x9e3779b9u);
	return float2(f32(a & 0xffffu), f32(b & 0xffffu)) / 65535.0;
}

// One turn of the spectrum for t going from 0 to 1: the colors of a thin film as its thickness or the viewing angle changes.
fn foil_film(t: f32) -> float3 {
	return 0.5 + 0.5 * cos(6.2831853 * (float3(t) + float3(0.0, 0.33, 0.67)));
}

// One point light's light on the foil at P: the iridescent wash and the anisotropic highlight. `base` is the highlight's color, `film_mix`
// how much of the thin film's hue it takes (0.5 for the steel, little for gold), `wash_k` the strength of the wash.
fn foil_shine(P: float3, lp: float3, N: float3, V: float3, T: float3, B: float3, phase: f32, base: float3, film_mix: f32, wash_k: f32) -> float3 {
	let d = lp - P;
	let dist2 = dot(d, d);
	let L = d * inverseSqrt(max(dist2, 1e-4));
	let att = 1.0 / (1.0 + dist2 * 5.0);
	let NL = max(dot(N, L), 0.0);
	let H = normalize(L + V);
	let NH = max(dot(N, H), 0.0);
	let ht = dot(H, T) / 0.16;    // along the brushing: a narrow highlight
	let hb = dot(H, B) / 0.55;    // across it: a long one
	let spec = exp(-2.0 * (ht * ht + hb * hb) / (1.0 + NH)) * NL;
	let tint = mix(base, foil_film(phase + 0.6 * dot(H, T)), film_mix);
	let wash = foil_film(phase + 0.25 * NL) * pow(NL, 5.0);
	return att * (wash * wash_k + tint * spec * 0.85);
}

// The glitter one light draws: the flakes whose own normal mirrors the light into the eye.
fn foil_glitter(g: float2, P: float3, lp: float3, V: float3, weight: f32) -> float3 {
	let cell = floor(g);
	let f = fract(g) - 0.5;
	let h = foil_cell(vec2<i32>(cell));
	let present = step(0.55, h.x);                                // not every cell holds a flake
	let fn_ = normalize(float3((foil_cell(vec2<i32>(cell) + vec2<i32>(31, 17)) - 0.5) * 1.3, 1.0));   // the flake's normal
	let d = lp - float3(P.xy, 0.0);
	let L = d * inverseSqrt(max(dot(d, d), 1e-4));
	let R = reflect(-L, fn_);
	let s = pow(max(dot(R, V), 0.0), 140.0);
	let disc = smoothstep(0.46, 0.2, length(f));
	let att = 1.0 / (1.0 + dot(d, d) * 3.0);
	return foil_film(h.y * 2.0 + 0.1) * (present * s * disc * att * weight * 5.0);
}

fn app_shade(a: AppIn) -> vec4<f32> {
	let ctl = app_param(1u);       // x: the pass
	let arg = app_param(2u);       // sweep, pointer x, pointer y, live
	let arg2 = app_param(3u);      // intensity, engrave
	let aspect = a.size.x / max(a.size.y, 1.0);
	let uv = clamp(a.uv, float2(0.0), float2(1.0));
	let t = textureSample(app_tex0, samp_img, uv);
	let tx = textureSample(app_tex1, samp_img, uv);
	// how far the letters reach around themselves: the coarse level of their coverage (about 4 css px)
	let halo = textureSampleLevel(app_tex1, samp_img, uv, 4.0).b * arg2.y;
	let cov = tx.b * arg2.y;

	// the surface: the guilloche calmed around the letters, then the letters' bevel where they are (their floor is flat)
	var xy = (t.xy * 2.0 - 1.0) * (1.0 - 0.85 * halo);
	xy = mix(xy, tx.xy * 2.0 - 1.0, cov);
	var N = float3(xy, 0.0);
	N.z = sqrt(max(1.0 - dot(N.xy, N.xy), 0.0));
	N = normalize(N);
	let height = t.b;
	let cavity = t.a * (1.0 - 0.9 * halo);

	if (ctl.x < 0.5) {
		var k = clamp(cavity * 0.9 + (1.0 - N.z) * 0.35, 0.0, 0.6) * (1.0 - 0.5 * halo);
		// a letter: a dark floor under the gold and darker walls (the blurred coverage is lower towards an edge)
		k = mix(k, 0.25 + 0.65 * (1.0 - tx.a), cov);
		return float4(0.0, 0.0, 0.0, k);
	}

	// the eye: the card is turned by rotateX(-ty * 14deg) rotateY(tx * 18deg) (about_card.odin), the eye looks straight at the screen
	let tilt = (arg.yz - 0.5) * 2.0;
	let ry = tilt.x * 0.3142;
	let rx = -tilt.y * 0.2443;
	let V = normalize(float3(-sin(ry) * cos(rx), sin(rx), cos(ry) * cos(rx)));
	let P = float3(uv.x * aspect, uv.y, 0.0);
	let NV = max(dot(N, V), 0.0);

	// the brushing runs a little below the horizontal and is bent by the relief
	var T = normalize(float3(0.94, 0.34, 0.0));
	T = normalize(T - N * dot(T, N));
	let B = cross(N, T);

	// the phase of the thin film: the angle the eye makes with the normal, the height of the engraving, the tilt
	let phase = 0.10 + 0.95 * (1.0 - NV) + 0.55 * height + 0.45 * tilt.x + 0.25 * tilt.y + 0.30 * uv.x - 0.22 * uv.y;

	let live = arg.w;
	let sw = arg.x;
	let sweep_pos = float3(mix(-0.5, 1.5, sw) * aspect, mix(1.15, -0.15, sw), 0.30);
	let sweep_k = (1.0 - 0.9 * live) * smoothstep(-0.25, 0.05, sw) * (1.0 - smoothstep(0.95, 1.25, sw));
	let ptr_pos = float3(arg.y * aspect, arg.z, 0.32);
	let ptr_k = 0.30 + 0.95 * live;

	let steel = float3(0.92, 0.95, 1.0);
	var col = float3(0.0);
	col += foil_shine(P, sweep_pos, N, V, T, B, phase, steel, 0.5, 0.07) * sweep_k * 1.25;
	col += foil_shine(P, ptr_pos, N, V, T, B, phase, steel, 0.5, 0.07) * ptr_k;

	// the engraving is tinted by the film even where no light falls: the pattern shows in color at rest
	col += foil_film(phase) * (0.008 + 0.07 * (1.0 - N.z)) * (0.5 + 0.5 * (1.0 - cavity));

	// glitter: flakes of about 2 css px on a grid of the card's own units, more on the slopes of the relief; none on the letters
	let g = uv * float2(aspect, 1.0) * 135.0;
	let gw = (0.30 + 0.70 * smoothstep(0.02, 0.28, 1.0 - N.z)) * (1.0 - 0.7 * cavity) * (1.0 - 0.85 * halo);
	col += foil_glitter(g, P, sweep_pos, V, gw) * sweep_k;
	col += foil_glitter(g, P, ptr_pos, V, gw) * ptr_k;

	// the lip catches the light at grazing angles
	let lip = smoothstep(0.62, 0.92, height);
	col += float3(0.6, 0.75, 1.0) * foil_film(phase * 1.3) * (pow(1.0 - NV, 3.0) * lip * 0.45);

	// GOLD, in the letters: a color that goes from deep amber to pale gold with the angle, a floor that is never dark (the contrast with the
	// dark engraving around is what makes the text read), the two lights as brushed highlights, and the walls shaded by the same lights
	let gt = 0.5 + 0.5 * sin(6.2831853 * (phase * 0.8 + 0.15));
	let gold = mix(float3(1.0, 0.52, 0.10), float3(1.0, 0.80, 0.34), gt);
	var lit = gold * (0.62 + 0.20 * N.z);
	lit += gold * foil_shine(P, sweep_pos, N, V, T, B, phase, gold, 0.10, 0.0) * sweep_k * 2.6;
	lit += gold * foil_shine(P, ptr_pos, N, V, T, B, phase, gold, 0.10, 0.0) * ptr_k * 2.2;
	// the walls: bright where they face the light of the card's top left (a fixed key light, so that a letter always has a rim), dark opposite
	let key = normalize(float3(-0.45, -0.6, 0.65));
	lit *= 0.30 + 1.25 * clamp(dot(N, key), 0.0, 1.0) / max(key.z, 0.3);
	lit += float3(1.0, 0.92, 0.7) * pow(1.0 - NV, 2.0) * 0.12;

	col = mix(col, lit, cov);
	col = 1.0 - exp(-col * 1.35);
	return float4(col * arg2.x, 1.0);
}
