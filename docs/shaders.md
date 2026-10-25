# Shaders in the browser's own pages (`-wren-shader`)

The licence card of `about:wren` is lit by a real fragment shader reading a real normal map, not by layers of CSS. The toolkit gives Wren
an application shader API (gui_toolkit 0.25.0, its [docs/shaders.md](../ext/gui_toolkit/docs/shaders.md): `render.create_app_shader`,
`draw.app_shader`, `render.create_texture_data`); this page is what Wren builds on it.

## The property

```css
.base { -wren-shader: card-foil var(--sweep) var(--bx) var(--by) var(--live) 1; }
```

`-wren-shader: none | <name> <argument>*`. An argument is a `<number>`, a `<percentage>` (its value divided by 100) or a `calc()` of
numbers, at most 28. Not inherited, paint only (a change of the arguments never asks for a layout). The shader fills the box's background
painting area (the clip of its bottom background layer, rounded by `border-radius`) **over its CSS background and before its border and its
content**: what the CSS draws is also what shows when the shader cannot be had.

The arguments are written with `var()` on purpose. A registered custom property (`@property --sweep { syntax: '<number>'; ... }`) that a CSS
animation moves or a script sets reaches the computed value through the declaration that uses it, and that is what makes the page paint
again. A change of the arguments is part of the box's raster signature, so a kept layer holding the box is drawn again when one of them
changes and not while they hold still (an animation that rests costs no frame).

## Who may use it

Only the browser's own pages: `about:home`, `about:demos`, `about:about`, `about:wren` and `about:licenses` (`is_builtin_href`, handed to the
page by the shell as `page.Settings.internal_address`; `about:blank` and every web document are not). In any other document the declaration
is **invalid** (the style engine drops it at computation: `Settings.internal_document`), so no computed style of a web page ever holds a
shader, whatever the cascade, `style=""` or the CSSOM say. And a name only selects an entry of the registry below: the page supplies
numbers and nothing else, never code, a texture or a blend mode. There is no way to bring a shader (no WebGL by the back door).

## The registry (`src/browser/shaders.odin`)

Each entry declares its WGSL, the Direct3D 11 pixel shader compiled from it (and the SHA-256 of the sources it came from), the names and
defaults of its arguments, the textures it reads (made natively, never taken from the page) and its passes (a blend mode each; the box is
drawn once per pass). What the shader reads, as `vec4` slots (`app_param(k)`): 0 = the engine's (the box in device pixels, pixels per CSS
pixel, 1 when `style.prefers_reduced_motion` is on), 1 = the pass, then the arguments four to a slot from slot 2.

To add a shader: write `src/browser/shaders/<name>.wgsl` (the toolkit's frame: `fn app_shade(a: AppIn) -> vec4<f32>`), run

```
odin run ext/gui_toolkit/tools/shaders -- app <name> src/browser/shaders/<name>.wgsl src/browser/shaders      # writes <name>.dxbc and <name>.sha256
```

(naga is built by `tools\build_naga.ps1` the first time: it needs `cargo`), embed the three files and add the entry. The test
`the_embedded_pixel_shader_matches_its_sources` fails while a blob is stale (the sources, or the toolkit's `rect.wgsl` / `app.wgsl`,
changed): the toolkit refuses such a blob when the shader is created, with a message, and the box keeps its CSS background.

The compositor does not record a box with a shader (its arguments change with every frame of an animation): it is drawn directly, in its
place in the paint order, like an image.

## `card-foil`

Arguments: `sweep` (0 .. 1: where the sweeping light is on its way across the card; outside, off), `pointer-x`, `pointer-y` (0 .. 1: where the
pointer is on the card, 0.5 at rest: the tilt the card is given, and the second light), `live` (0 .. 1: the pointer is on the card: the
sweep dims), `intensity`. Texture 0: the normal map of the card (`about_card_relief.odin`: R G the normal's x y, B the height, A the
cavity). Two passes: *Normal* (the engraving's shade: the cavities are dark) and *Add* (the light).

The light pass: for each of two point lights, a Ward **anisotropic** highlight (brushed foil: long across the brushing, short along it) and an
iridescent wash (a thin film: the hue goes round the spectrum with the angle between the normal and the eye, which comes from the tilt); a grid
of **glitter** flakes with a normal each that flash where the light mirrors into the eye, more on the slopes of the engraving; a **fresnel** rim
on the lip of the frame. The result is toned (`1 - exp(-x)`) so that two lights never burn out the text above.

### The card's turn, and its back (`card-back`)

Three more arguments after `intensity`, `engrave` (1: texture 1 holds the lettering to raise) and the mode `seal` (0 the card, 1 the seal, 2 the
back): `rx` and `ry`, the card's turn in **degrees** (`rotateX(rx) rotateY(ry)` as the page applies it: the CSS passes `var(--rx) var(--ry)`,
registered numbers that transition together with the transform). The eye and the two lights are placed from it in the frame of the face the
shader paints (`to_face`, `face_light` in `card_foil.wgsl`): the lights are points of the page over the card's plane, and the face's frame is the
card's turned back by `rx`, `ry`; the back is the card turned half a turn about the vertical axis (`rotateY(180deg)` in the page), which mirrors x
and z, so that the pointer's light stays where the pointer is on the screen and the back is lit as an object seen from behind. The pointer's own
tilt (which used to be derived from `pointer-x`, `pointer-y`) is `rx = -py * 14`, `ry = px * 18`, written by the page's script.

`card-back` is the same module in mode 2 with its own textures: texture 0 is the **front's relief inside out** (`about_card_back.odin`,
`relief_map` with an `emboss` field: the height field negated, so the lip is a trough and the furrows of the guilloche ridges; the same grain) with
the **logo of Wren raised** in the middle (the bird of `assets/logo_256.png`, taken from the light of the picture and its alpha, blurred for the
bevel: `logo_height_field`); texture 1 is a line of raised lettering along the bottom (`back_engraving`, the brand: `WREN · FROMENT SOFTWARE`,
nothing about the person). Two faces back to back, each `backface-visibility: hidden`; the one turned away is not painted (`open_plane`).

## Measured and tested

* `src/style/wren_shader_test.odin`: parsing (names, numbers, percentages, `calc()`, `var()` and its fallback, the invalid forms), refusal in a
  document that is not built in (stylesheet, `style=""`), the arguments following an animated registered property, the end of that animation
  (a crash before the fix in `timeline.odin`), paint-only tier.
* `src/browser/shaders_test.odin`: the registry, the blob's hash, the normal map (unit normals, deterministic, engraving present, micro-lettering
  cut), the card's style (no picture in the page), a page painted on WARP (the shader lights its box and only its box, rounded corner, a web
  page ignores the property, the fallback where the shader is unavailable or unknown, compositor on and off, the arguments move the light).
* `shader_cost` (off unless `WREN_SHADER_BENCH` is set; see the comment above it): the first-use cost and the per-frame cost of the card's two
  passes on the machine's GPU.
