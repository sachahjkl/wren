package browser

import "core:fmt"
import "core:math"
import "core:strings"
import "wb:license"

////////////////////////////////
// The licence card of about:wren, shown when a licence is registered: a dark card with the supporter's name, edition,
// date and order number as raised silver lettering, an engraved iridescent foil that a sweeping light and the pointer play over,
// and a certification seal. Made with the page engine's own CSS and a little JavaScript, and a shader: the foil is
// `-wren-shader: card-foil` (shaders.odin, shaders/card_foil.wgsl, a normal map from about_card_relief.odin, the lettering from
// about_card_engrave.odin), lit over the CSS background of `.base`, which is also what shows where the shader cannot be had; the face of
// the seal is `card-seal` of the same module (`.relief`, a domed medal with a reeded edge, rings and raised lettering: about_card_seal.odin);
//
//  - the card tilts with the pointer (rotateX / rotateY, eased back to rest by a CSS transition) in the perspective of its box
//    (CSS Transforms 2: .cardbox has perspective, .lic preserve-3d): the base with its foil and glare lies at z = 0 and the
//    text 18px above it. The seal is a medal stuck ON the card: a stack of layers 1 to 9px above the base (its cast shadow,
//    which slides away from the light, the ridged gold edge, the domed green face, a highlight that follows the pointer, the
//    word and the tick embossed on top), so the tilt shows its relief and it never floats; the text slides a little on the
//    pointer. At rest the scales (900 / (900 - z)) cancel the enlargement the perspective gives the lifted layers;
//  - the script runs on pointer events only, applies at most one update per frame (requestAnimationFrame) and never
//    loops: a card at rest, or the pointer still, costs no frame. The sweep is a CSS animation of the registered property
//    --sweep that rests for 60 % of its 7 s: a resting animation asks for no frame either;
//  - without JavaScript (javascript.enabled off) or with prefers-reduced-motion the card is the same, still, foil at
//    a fixed angle.

@(private = "file")
CARD_STYLE :: `
  @property --sweep { syntax: '<number>'; inherits: true; initial-value: 0.42; }
  @property --live { syntax: '<number>'; inherits: true; initial-value: 0; }
  @property --bx { syntax: '<percentage>'; inherits: true; initial-value: 50%; }
  @property --by { syntax: '<percentage>'; inherits: true; initial-value: 50%; }
  @property --engrave { syntax: '<number>'; inherits: true; initial-value: 1; }
  .cardbox { width: 100%; max-width: 440px; margin: 16px 0 6px; padding: 12px 0; perspective: 900px; }
  .lic { position: relative; width: 100%; aspect-ratio: 1.586; box-sizing: border-box; color: #eceff7; transform-style: preserve-3d;
    transition: transform 0.55s cubic-bezier(0.2, 0.7, 0.2, 1), --bx 0.55s cubic-bezier(0.2, 0.7, 0.2, 1), --by 0.55s cubic-bezier(0.2, 0.7, 0.2, 1); }
  .lic.live { transition: none; }
  .lic > div { position: absolute; }
  .lic .wall { box-sizing: border-box; }
  .lic .base { left: 0; top: 0; right: 0; bottom: 0; box-sizing: border-box; border-radius: 14px; overflow: hidden; background-color: #161a26;
    background-image: linear-gradient(150deg, #232a40 0%, #151926 58%, #1c2132 100%); border: 1px solid rgba(255, 255, 255, 0.16);
    -wren-shader: card-foil var(--sweep) var(--bx) var(--by) var(--live) 1 var(--engrave); animation: sweep 7s cubic-bezier(0.45, 0, 0.35, 1) infinite; }
  .lic.live .base { --live: 1; animation-play-state: paused; }
  @keyframes sweep { 0% { --sweep: -0.3; } 40% { --sweep: 1.25; } 100% { --sweep: 1.25; } }
  /* the text is engraved by the shader (data-engrave): the page's own text stays in the document (reading, selecting, copying) but is not drawn;
     it is drawn where the shader is not used: a narrow card, reduced motion, a shader that cannot be had */
  .lic .face { -webkit-text-fill-color: transparent; }
  .lic[data-shader=off] .face { -webkit-text-fill-color: currentcolor; }
  @media (prefers-reduced-motion: reduce) { .lic .base { animation: none; --sweep: 0.42; } .lic { --engrave: 0; } .lic .face { -webkit-text-fill-color: currentcolor; } }
  .lic .face { left: 0; top: 0; right: 0; bottom: 0; transform: translate3d(0, 0, 18px) scale(0.98); padding: 18px 22px; box-sizing: border-box; display: flex; flex-direction: column; justify-content: space-between; }
  .lic .top { display: flex; align-items: center; }
  .lic .top img { width: 26px; height: 26px; flex: none; margin-right: 9px; }
  .lic .top b { font-size: 17px; font-weight: 600; letter-spacing: 0.02em; }
  .lic .top span { margin-left: auto; font-size: 11px; letter-spacing: 0.16em; text-transform: uppercase; color: rgba(236, 239, 247, 0.66); }
  .lic .who { font-size: 24px; line-height: 1.2; font-weight: 600; overflow-wrap: anywhere; }
  .lic .mail { font-size: 12px; color: rgba(236, 239, 247, 0.6); overflow-wrap: anywhere; }
  .lic .meta { display: flex; }
  .lic .meta div { margin-right: 26px; }
  .lic .meta small { display: block; font-size: 10px; letter-spacing: 0.14em; text-transform: uppercase; color: rgba(236, 239, 247, 0.5); }
  .lic .meta em { font-style: normal; font-size: 13px; font-variant-numeric: tabular-nums; }
  @media (max-width: 520px) {
    .lic { aspect-ratio: 1.2; --engrave: 0; }
    .lic .face { -webkit-text-fill-color: currentcolor; }
    .lic .meta { flex-direction: column; }
    .lic .meta div { margin: 0 0 5px 0; }
  }
  .lic .seal { right: 16px; bottom: 14px; width: 88px; height: 88px; transform-style: preserve-3d; }
  .lic .seal > div { position: absolute; box-sizing: border-box; }
  .lic .seal .shadow { left: 0; top: 0; width: 88px; height: 88px; border-radius: 50%; transform: translate3d(3px, 5px, 1px) scale(0.99889); filter: blur(3px);
    background-image: radial-gradient(circle at 50% 50%, rgba(0, 0, 0, 0.6) 60%, rgba(0, 0, 0, 0) 74%); }
  .lic .seal .sw { box-sizing: border-box; }
  .lic .seal .edge { left: 0; top: 0; width: 88px; height: 88px; border-radius: 50%; transform: translate3d(0, 0, 5px) scale(0.99444);
    box-shadow: inset 0 2px 1px rgba(255, 255, 255, 0.55), inset 0 -2px 2px rgba(0, 0, 0, 0.5), 0 1px 0 rgba(0, 0, 0, 0.4);
    background-image: repeating-conic-gradient(from 0deg, #f6e29a 0deg, #f6e29a 1.5deg, #d3a93d 1.5deg, #d3a93d 5deg, #8f6a1c 5deg, #8f6a1c 8deg); }
  .lic .seal .ring { left: 6px; top: 6px; width: 76px; height: 76px; border-radius: 50%; transform: translate3d(0, 0, 6px) scale(0.99333); border: 2px solid #f4df9a;
    box-shadow: inset 0 3px 4px rgba(255, 255, 255, 0.28), inset 0 -5px 7px rgba(0, 0, 0, 0.45), 0 1px 2px rgba(0, 0, 0, 0.55);
    background-image: repeating-radial-gradient(circle at 50% 50%, rgba(255, 255, 255, 0.09) 0px, rgba(255, 255, 255, 0.09) 1px, rgba(255, 255, 255, 0) 1px, rgba(255, 255, 255, 0) 3px), radial-gradient(circle at 34% 28%, #5ad98e, #1f8a52 55%, #0f5a36 100%); }
  .lic .seal .rim { position: absolute; left: 4px; top: 4px; right: 4px; bottom: 4px; border-radius: 50%; border: 1px solid rgba(244, 223, 154, 0.6); }
  .lic .seal .gloss { left: 6px; top: 6px; width: 76px; height: 76px; border-radius: 50%; transform: translate3d(0, 0, 7px) scale(0.99222);
    background-image: radial-gradient(circle at var(--sgx, 32%) var(--sgy, 26%), rgba(255, 255, 255, 0.55), rgba(255, 255, 255, 0) 45%), linear-gradient(140deg, rgba(255, 255, 255, 0.22), rgba(255, 255, 255, 0) 46%); }
  .lic .seal .word { left: 0; top: 48px; width: 88px; height: 10px; transform: translate3d(0, 0, 8px) scale(0.99111); text-align: center; font-size: 8px; line-height: 10px; font-weight: 700; letter-spacing: 0.08em; color: #f7e9b0;
    text-shadow: 0px 1px 0px rgba(0, 0, 0, 0.5), 0px -1px 0px rgba(255, 255, 255, 0.3); }
  .lic .seal .tickwrap { left: 0; top: 0; width: 88px; height: 88px; transform: translate3d(0, 0, 10px) scale(0.98889);
    filter: drop-shadow(0px 2px 1px rgba(0, 0, 0, 0.5)) drop-shadow(0px -1px 0px rgba(255, 255, 255, 0.35)); }
  .lic .seal .tickwrap svg { display: block; }
  /* the face of the seal is drawn by the shader (.relief: a domed green face with fine rings, a reeded gold edge, the word and the tick
     raised); the layers above are its fallback and show where it cannot be had (data-shader=off on the seal), with reduced motion and on a
     narrow card. The cast shadow and the edge's walls stay: they are the seal's thickness. */
  .lic .seal .relief { left: 0; top: 0; width: 88px; height: 88px; border-radius: 50%; transform: translate3d(0, 0, 5px) scale(0.99444);
    -wren-shader: card-seal var(--sweep) var(--bx) var(--by) var(--live) 1 var(--engrave); animation: sweep 7s cubic-bezier(0.45, 0, 0.35, 1) infinite; }
  .lic.live .seal .relief { --live: 1; animation-play-state: paused; }
  .lic .seal .edge, .lic .seal .ring, .lic .seal .gloss, .lic .seal .word, .lic .seal .tickwrap { visibility: hidden; }
  .lic .seal[data-shader=off] .edge, .lic .seal[data-shader=off] .ring, .lic .seal[data-shader=off] .gloss, .lic .seal[data-shader=off] .word, .lic .seal[data-shader=off] .tickwrap { visibility: visible; }
  @media (prefers-reduced-motion: reduce) { .lic .seal .relief { animation: none; --sweep: 0.42; } .lic .seal .edge, .lic .seal .ring, .lic .seal .gloss, .lic .seal .word, .lic .seal .tickwrap { visibility: visible; } }
  @media (max-width: 520px) { .lic .seal .edge, .lic .seal .ring, .lic .seal .gloss, .lic .seal .word, .lic .seal .tickwrap { visibility: visible; } }
`

@(private = "file")
CARD_SCRIPT :: `
(function () {
  var card = document.getElementById("lic");
  if (!card || !card.addEventListener) return;
  if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  var box = card.parentNode, face = card.querySelector(".face"), shadow = card.querySelector(".seal .shadow");
  var px = 0, py = 0, queued = false, live = false;
  function apply() {
    queued = false;
    card.style.transform = "rotateX(" + (-py * 14).toFixed(2) + "deg) rotateY(" + (px * 18).toFixed(2) + "deg)";
    card.style.setProperty("--bx", (50 + px * 50).toFixed(1) + "%");
    card.style.setProperty("--by", (50 + py * 50).toFixed(1) + "%");
    face.style.transform = "translate3d(" + (-px * 5).toFixed(2) + "px," + (-py * 4).toFixed(2) + "px,18px) scale(0.98)";
    shadow.style.transform = "translate3d(" + (3 - px * 5).toFixed(2) + "px," + (5 - py * 4).toFixed(2) + "px,1px) scale(0.99889)";
    card.style.setProperty("--sgx", (50 + px * 28).toFixed(1) + "%");
    card.style.setProperty("--sgy", (50 + py * 28).toFixed(1) + "%");
  }
  function move(e) {
    var r = box.getBoundingClientRect();
    px = Math.max(-1, Math.min(1, (e.clientX - r.left) / r.width * 2 - 1));
    py = Math.max(-1, Math.min(1, (e.clientY - r.top) / r.height * 2 - 1));
    if (!live) { live = true; card.className = "lic live"; }
    if (!queued) { queued = true; requestAnimationFrame(apply); }
  }
  function leave() {
    live = false; px = 0; py = 0; queued = false;
    card.className = "lic";
    card.style.transform = "rotateX(0deg) rotateY(0deg)";
    card.style.setProperty("--bx", "50%");
    card.style.setProperty("--by", "50%");
    face.style.transform = "translate3d(0px,0px,18px) scale(0.98)";
    shadow.style.transform = "translate3d(3px,5px,1px) scale(0.99889)";
    card.style.setProperty("--sgx", "32%");
    card.style.setProperty("--sgy", "26%");
  }
  box.addEventListener(window.PointerEvent ? "pointermove" : "mousemove", move);
  box.addEventListener(window.PointerEvent ? "pointerleave" : "mouseleave", leave);
})();
`

// The style of the card. Its foil is a shader of the browser (`-wren-shader: card-foil`, shaders.odin, shaders/card_foil.wgsl) lit over the dark
// background below, which is also what shows where the shader cannot be had; the relief it lights is made natively (about_card_relief.odin)
// when the card is first painted, so the page carries no picture of it.
card_css :: proc() -> string { return CARD_STYLE }

// The thickness of the card: a real rim, like a bank card's (0.76mm is about 4px at this size; 8 shows from a tilt of 18 degrees), built from flat faces standing
// edge-on behind the base: the four straight sides, and the rounded corners cut into facets (a quarter circle of CARD_RADIUS in
// CARD_FACETS flat strips). Each face is shaded by its orientation against a light from the top left, so the rim reads as a solid
// when the card tilts. At rest every face is seen edge-on and lies behind the base, so the card is unchanged.
CARD_RADIUS    :: 14.0
CARD_THICKNESS :: 8.0
CARD_FACETS    :: 4
// The faces of the rim stand a hair clear of the planes they meet (the base, the seal's face), by GAP px: planes that touch exactly are
// taken to cross by the compositor (a plane's corners lie on the other's within the rounding of the projection), which splits all of
// them into pieces and loses the seal.
GAP :: 0.2

// A colour between `dark` and `light` for a face whose outward normal points at `angle` (radians, y down).
@(private = "file")
shade :: proc(angle: f64, dark, light: [3]f64) -> [3]int {
	b := 0.5 + 0.5 * (math.cos(angle) * -0.6 + math.sin(angle) * -0.8)
	return {int(dark.r + (light.r - dark.r) * b), int(dark.g + (light.g - dark.g) * b), int(dark.b + (light.b - dark.b) * b)}
}

@(private = "file")
card_walls_html :: proc(sb: ^strings.Builder) {
	r, T :: CARD_RADIUS, CARD_THICKNESS
	dark, light := [3]f64{22, 26, 42}, [3]f64{176, 186, 222}
	wall :: proc(sb: ^strings.Builder, style: string, angle: f64, dark, light: [3]f64) {
		c := shade(angle, dark, light)
		fmt.sbprintf(sb, "<div class=\"wall\" style=\"%s background-color: #%02x%02x%02x;\"></div>", style, c.r, c.g, c.b)
	}
	// the straight sides (outward normal: left 180deg, top 270deg, right 0, bottom 90deg)
	wall(sb, fmt.tprintf("left: %.2fpx; top: %.2fpx; width: %.2fpx; height: calc(100%% - %.2fpx); transform: translateZ(%.2fpx) rotateY(90deg);", -T / 2, r, T, 2 * r, -T / 2 - GAP), math.PI, dark, light)
	wall(sb, fmt.tprintf("left: calc(100%% - %.2fpx); top: %.2fpx; width: %.2fpx; height: calc(100%% - %.2fpx); transform: translateZ(%.2fpx) rotateY(90deg);", T / 2, r, T, 2 * r, -T / 2 - GAP), 0, dark, light)
	wall(sb, fmt.tprintf("left: %.2fpx; top: %.2fpx; width: calc(100%% - %.2fpx); height: %.2fpx; transform: translateZ(%.2fpx) rotateX(90deg);", r, -T / 2, 2 * r, T, -T / 2 - GAP), 1.5 * math.PI, dark, light)
	wall(sb, fmt.tprintf("left: %.2fpx; top: calc(100%% - %.2fpx); width: calc(100%% - %.2fpx); height: %.2fpx; transform: translateZ(%.2fpx) rotateX(90deg);", r, T / 2, 2 * r, T, -T / 2 - GAP), 0.5 * math.PI, dark, light)
	// the corners: 0 top left, 1 top right, 2 bottom right, 3 bottom left; a quarter circle from the angle `a0`
	chord := 2 * r * math.sin(math.PI / (4 * CARD_FACETS))
	for corner in 0 ..< 4 {
		right, bottom := corner == 1 || corner == 2, corner >= 2
		a0 := math.PI * (1 + 0.5 * f64(corner))
		for k in 0 ..< CARD_FACETS {
			a := a0 + (f64(k) + 0.5) * (0.5 * math.PI / CARD_FACETS)
			// the centre of the strip, from the corner's own centre (r from the edges)
			dx, dy := r * math.cos(a), r * math.sin(a)
			x := right ? fmt.tprintf("calc(100%% - %.2fpx)", r - dx + chord / 2) : fmt.tprintf("%.2fpx", r + dx - chord / 2)
			y := bottom ? fmt.tprintf("calc(100%% - %.2fpx)", r - dy + T / 2) : fmt.tprintf("%.2fpx", r + dy - T / 2)
			wall(sb, fmt.tprintf("left: %s; top: %s; width: %.2fpx; height: %.2fpx; transform: translateZ(%.2fpx) rotateZ(%.2fdeg) rotateX(90deg);", x, y, chord, T, -T / 2 - GAP, (a + 0.5 * math.PI) * 180 / math.PI), a, dark, light)
		}
	}
}

// The edge of the seal: a coin's milled rim, SEAL_SIDES flat strips round the circle, from the card (z = 1px) to the face (z = 5px).
// The radius is a hair under the face's, which perspective enlarges, so the rim never shows past it at rest.
SEAL_SIDES :: 32

@(private = "file")
seal_walls_html :: proc(sb: ^strings.Builder) {
	R :: 43.75
	T :: 4.0 - 2 * GAP
	chord := 2 * R * math.sin(math.PI / SEAL_SIDES)
	for i in 0 ..< SEAL_SIDES {
		a := (f64(i) + 0.5) * (2 * math.PI / SEAL_SIDES)
		x, y := 44 + R * math.cos(a) - chord / 2, 44 + R * math.sin(a) - T / 2
		c := shade(a, {96, 66, 14}, {222, 182, 78})
		fmt.sbprintf(sb, "<div class=\"sw\" style=\"left: %.2fpx; top: %.2fpx; width: %.2fpx; height: %.2fpx; transform: translateZ(3px) rotateZ(%.2fdeg) rotateX(90deg); background-color: #%02x%02x%02x;\"></div>", x, y, chord, T, (a + 0.5 * math.PI) * 180 / math.PI, c.r, c.g, c.b)
	}
}

// The card of `lic` and the script that moves it. Every field is escaped.
license_card_html :: proc(sb: ^strings.Builder, lic: license.License) {
	e :: proc(s: string) -> string { return escape_html(s) }
	strings.write_string(sb, "<div class=\"cardbox\"><div class=\"lic\" id=\"lic\">")
	card_walls_html(sb)
	fmt.sbprintf(sb, "<div class=\"base\" data-engrave=\"%s\"></div>", e(card_engrave_fields(APP_NAME, license.edition_title(lic.edition), lic.name, lic.email, lic.date, lic.order)))
	fmt.sbprintf(sb, "<div class=\"face\"><div class=\"top\"><img src=\"%s\" alt=\"\"><b>%s</b><span>%s</span></div>", app_logo_url(), APP_NAME, e(license.edition_title(lic.edition)))
	fmt.sbprintf(sb, "<div><div class=\"who\">%s</div>", e(lic.name))
	if lic.email != "" { fmt.sbprintf(sb, "<div class=\"mail\">%s</div>", e(lic.email)) }
	strings.write_string(sb, "</div><div class=\"meta\">")
	if lic.date != "" { fmt.sbprintf(sb, "<div><small>Issued</small><em>%s</em></div>", e(lic.date)) }
	if lic.order != "" { fmt.sbprintf(sb, "<div><small>Order</small><em>%s</em></div>", e(lic.order)) }
	strings.write_string(sb, "</div></div>")
	strings.write_string(sb, "<div class=\"seal\"><div class=\"shadow\"></div>")
	seal_walls_html(sb)
	strings.write_string(sb, "<div class=\"relief\" data-engrave=\"CERTIFIED\"></div><div class=\"edge\"></div><div class=\"ring\"><div class=\"rim\"></div></div><div class=\"gloss\"></div><div class=\"word\">CERTIFIED</div><div class=\"tickwrap\"><svg width=\"88\" height=\"88\" viewBox=\"0 0 88 88\"><path d=\"M31.75 27.5L40.25 36L56.25 17\" fill=\"none\" stroke=\"#fbf0c4\" stroke-width=\"4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg></div></div>")
	strings.write_string(sb, "</div></div>\n<script>")
	strings.write_string(sb, CARD_SCRIPT)
	strings.write_string(sb, "</script>\n")
}
