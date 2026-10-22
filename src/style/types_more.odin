package style

import "wb:css"

// Value types of the properties added for transitions, animations, transforms, generated content, backgrounds, effects
// and grid. Everything here is a computed value: lengths that depend on a box stay symbolic (percentages, calc()), the rest
// is resolved. All of it lives in the arena of the `Styled` that holds the computed style.

////////////////////////////////
// Text

Font_Variant_Caps :: enum u8 { Normal, Small_Caps, All_Small_Caps, Petite_Caps, All_Petite_Caps, Unicase, Titling_Caps }
Text_Decoration_Style :: enum u8 { Solid, Double, Dotted, Dashed, Wavy }
White_Space_Collapse :: enum u8 { Collapse, Preserve, Preserve_Breaks, Preserve_Spaces, Break_Spaces, Discard }
Text_Wrap_Mode :: enum u8 { Wrap, Nowrap }
Text_Wrap_Style :: enum u8 { Auto, Balance, Stable, Pretty }
Hyphens :: enum u8 { Manual, None, Auto }

////////////////////////////////
// Backgrounds and gradients

Box_Area :: enum u8 { Border_Box, Padding_Box, Content_Box, Text }
Bg_Attachment :: enum u8 { Scroll, Fixed, Local }

// One background layer, with the list repetition rules of CSS Backgrounds already applied. Layer 0 is painted on top.
Bg_Layer :: struct {
	image:      Image,
	repeat:     [2]Repeat,
	position:   [2]Length,
	size:       Bg_Size,
	origin:     Box_Area,
	clip:       Box_Area,
	attachment: Bg_Attachment,
}

Gradient_Kind :: enum u8 { Linear, Radial, Conic }
Radial_Shape :: enum u8 { Ellipse, Circle }
Radial_Extent :: enum u8 { Farthest_Corner, Farthest_Side, Closest_Corner, Closest_Side, Explicit }
Color_Space :: enum u8 { Default, Srgb, Srgb_Linear, Oklab, Oklch, Lab, Lch, Hsl, Hwb, Xyz }
// How hues of polar color spaces are interpolated (CSS Color 4 §12.4: `in oklch longer hue`).
Hue_Method :: enum u8 { Shorter, Longer, Increasing, Decreasing }

// `pos` is Auto when the stop has no position (CSS Images 3 fixes them up, see `gradient_stops`); a hint is a position
// without a color (the color field is unused).
Color_Stop :: struct {
	color: css.Color,
	pos:   Length,
	hint:  bool,
}

Gradient :: struct {
	kind:      Gradient_Kind,
	repeating: bool,
	angle:     f32,            // radians. Linear: direction of the gradient line (0 = to top, clockwise); Conic: `from`
	to_corner: bool,           // Linear `to top right`...: the angle depends on the box, see `gradient_angle`
	corner:    [2]i8,          // to_corner: x -1 left / +1 right, y -1 top / +1 bottom
	shape:     Radial_Shape,
	extent:    Radial_Extent,
	radius:    [2]Length,      // Radial with an explicit size (circle: radius[0] only)
	position:  [2]Length,      // Radial and conic center
	space:     Color_Space,    // `in <colorspace>`; Default = premultiplied sRGB for legacy colors
	hue:       Hue_Method,     // `in <polar space> <method> hue`
	stops:     []Color_Stop,
}

////////////////////////////////
// Transforms

Transform_Kind :: enum u8 { Translate, Scale, Rotate, Skew, Matrix, Perspective, Mix, Matrix3D }

// One transform function reduced to its primitive (CSS Transforms 2 §12): translateX/Y/Z/3d -> Translate, scaleX/Y/Z/3d ->
// Scale, rotate/rotateZ/rotateX/rotateY/rotate3d -> Rotate (about `axis`), skewX/Y -> Skew, matrix -> Matrix (2D),
// matrix3d -> Matrix3D (a matrix3d that is plain 2D becomes Matrix), perspective(). Mix is the result of interpolating two
// lists that cannot be interpolated function by function and contain box-relative lengths: it is resolved, with the box, by
// `transform_matrix4`. `transform_matrix` (2D) is the orthographic projection of all this: what is drawn without 3D support.
Transform_Op :: struct {
	kind: Transform_Kind,
	l:    [2]Length,       // Translate: x, y (percentages refer to the reference box)
	v:    [6]f32,          // Scale: sx, sy, sz. Rotate: angle (radians, clockwise). Skew: ax, ay (radians). Matrix: a b c d e f.
	                       // Perspective: the distance (0: none)
	z:    f32,             // Translate: z (px)
	axis: [3]f32,          // Rotate: the axis (not normalized; a zero axis rotates nothing)
	m3:   [16]f32,         // Matrix3D: the 16 values of matrix3d()
	mix:  ^Transform_Mix,
}

Transform_Mix :: struct {
	from, to: []Transform_Op,
	t:        f32,
}

Transform_Box :: enum u8 { View_Box, Content_Box, Border_Box, Fill_Box, Stroke_Box }
Transform_Style :: enum u8 { Flat, Preserve_3d }
Backface_Visibility :: enum u8 { Visible, Hidden }

// The individual transform properties (CSS Transforms 2). `set` is false for `none`.
Translate_Value :: struct { set: bool, x, y: Length, z: f32 }
Rotate_Value :: struct { set: bool, angle: f32, axis: [3]f32 }   // radians; a non-z axis is flattened like rotateX/Y
Scale_Value :: struct { set: bool, s: [3]f32 }

////////////////////////////////
// Transitions and animations

Easing_Kind :: enum u8 { Linear, Cubic_Bezier, Steps, Points }
Step_Position :: enum u8 { Jump_End, Jump_Start, Jump_None, Jump_Both }
Linear_Stop :: struct { input, output: f32 }

// An easing function (CSS Easing 2). Points: linear() with its inputs already filled in and made monotonic.
Easing :: struct {
	kind:   Easing_Kind,
	steps:  i32,
	pos:    Step_Position,
	p:      [4]f32,             // cubic-bezier(x1, y1, x2, y2)
	points: []Linear_Stop,
}

EASE :: Easing{kind = .Cubic_Bezier, p = {0.25, 0.1, 0.25, 1}}

Transition_Prop_Kind :: enum u8 { All, None, Prop, Short, Unknown }
Transition_Prop :: struct {
	kind:  Transition_Prop_Kind,
	prop:  Prop,
	short: Short,
	name:  string,    // Unknown: the name as written (it still takes a place in the list)
}

Anim_Direction :: enum u8 { Normal, Reverse, Alternate, Alternate_Reverse }
Fill_Mode :: enum u8 { None, Forwards, Backwards, Both }
Play_State :: enum u8 { Running, Paused }
Composition :: enum u8 { Replace, Add, Accumulate }

////////////////////////////////
// Generated content and lists

// Predefined counter styles (CSS Counter Styles 3, §6-7). String: `list-style-type: "<string>"` (the text is in
// List_Marker_Style.text).
Counter_Style :: enum u8 {
	None, Disc, Circle, Square, Disclosure_Open, Disclosure_Closed,
	Decimal, Decimal_Leading_Zero, Lower_Roman, Upper_Roman, Lower_Greek, Lower_Alpha, Upper_Alpha,
	Lower_Armenian, Upper_Armenian, Georgian, Hebrew,
	Arabic_Indic, Persian, Devanagari, Bengali, Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada, Malayalam, Thai, Lao,
	Myanmar, Khmer, Tibetan, Mongolian, Cjk_Decimal,
	Hiragana, Katakana, Hiragana_Iroha, Katakana_Iroha, Cjk_Earthly_Branch, Cjk_Heavenly_Stem,
	Japanese_Informal, Simp_Chinese_Informal, Trad_Chinese_Informal,
	String,
}

List_Marker_Style :: struct {
	style: Counter_Style,
	text:  string,      // String: the marker as written
}

Counter_Op :: struct {
	name:      string,
	value:     i32,
	has_value: bool,
	reversed:  bool,    // counter-reset: reversed(name)
}

Quotes_Kind :: enum u8 { Auto, None, List }
Quotes :: struct {
	kind:  Quotes_Kind,
	pairs: [][2]string,   // List: open and close quote per nesting level
}

Content_Part_Kind :: enum u8 { Text, Attr, Open_Quote, Close_Quote, No_Open_Quote, No_Close_Quote, Url, Counter, Counters }
Content_Part :: struct {
	kind:  Content_Part_Kind,
	text:  string,              // Text: the string; Attr: the attribute; Url: the URL; Counter(s): the counter name
	sep:   string,              // Counters: the separator
	style: List_Marker_Style,   // Counter(s): the counter style (decimal by default)
}

////////////////////////////////
// Effects

Filter_Kind :: enum u8 { Blur, Brightness, Contrast, Drop_Shadow, Grayscale, Hue_Rotate, Invert, Opacity, Saturate, Sepia, Url }
// v: Blur radius in px, Hue_Rotate in radians, the others as a factor (50% = 0.5).
Filter_Op :: struct {
	kind:   Filter_Kind,
	v:      f32,
	shadow: Shadow,     // Drop_Shadow
	url:    string,     // Url
}

Geometry_Box :: enum u8 { Border_Box, Padding_Box, Content_Box, Margin_Box, Fill_Box, Stroke_Box, View_Box }
Clip_Path_Kind :: enum u8 { None, Url, Box, Inset, Circle, Ellipse, Polygon }
Clip_Path :: struct {
	kind:    Clip_Path_Kind,
	box:     Geometry_Box,
	inset:   [Side]Length,           // Inset
	round:   [Corner]Corner_Radius,  // Inset `round`
	radius:  [2]Length,              // Circle (radius[0]) and Ellipse, when explicit
	extent:  [2]Radial_Extent,       // Closest_Side / Farthest_Side, or Explicit
	center:  [2]Length,              // Circle / Ellipse `at`
	points:  [][2]Length,            // Polygon
	evenodd: bool,                   // Polygon fill rule
	url:     string,
}

Isolation :: enum u8 { Auto, Isolate }
Blend_Mode :: enum u8 {
	Normal, Multiply, Screen, Overlay, Darken, Lighten, Color_Dodge, Color_Burn, Hard_Light, Soft_Light, Difference,
	Exclusion, Hue, Saturation, Color, Luminosity, Plus_Darker, Plus_Lighter,
}

////////////////////////////////
// Misc

Containment :: enum u8 { Size, Inline_Size, Layout, Style, Paint }
Contain :: bit_set[Containment; u8]
Content_Visibility :: enum u8 { Visible, Auto, Hidden }
Scroll_Behavior :: enum u8 { Auto, Smooth }
Overscroll :: enum u8 { Auto, Contain, None }
Auto_Color :: struct { auto: bool, color: css.Color }

// SVG paint (CSS Fill and Stroke 3 §7): none, currentColor (resolved against the element's `color` when used), or a colour.
Svg_Paint_Kind :: enum u8 { None, Current_Color, Color }
Svg_Paint :: struct { kind: Svg_Paint_Kind, color: css.Color }
Stroke_Linecap :: enum u8 { Butt, Round, Square }
Stroke_Linejoin :: enum u8 { Miter, Round, Bevel }
Appearance :: enum u8 { None, Auto, Menulist_Button, Textfield, Base }
Resize :: enum u8 { None, Both, Horizontal, Vertical, Block, Inline }

////////////////////////////////
// Grid (CSS Grid 2): stored for the grid layout

Track_Breadth_Kind :: enum u8 { Auto, Length, Fr, Min_Content, Max_Content }
Track_Breadth :: struct {
	kind: Track_Breadth_Kind,
	len:  Length,     // Length: px, percent or calc
	fr:   f32,
}

Grid_Track_Kind :: enum u8 { Breadth, Minmax, Fit_Content, Repeat }
Grid_Repeat_Kind :: enum u8 { Count, Auto_Fill, Auto_Fit }

// One track (or a repeat() of tracks) with the line names written before it.
Grid_Track :: struct {
	kind:         Grid_Track_Kind,
	min, max:     Track_Breadth,     // Breadth: both the same; Fit_Content: max.len is the limit
	names_before: []string,
	repeat:       Grid_Repeat_Kind,  // Repeat
	count:        i32,               // Repeat with Count
	tracks:       []Grid_Track,      // Repeat: the repeated tracks
	end_names:    []string,          // Repeat: names after the last repeated track
}

Grid_Template_Kind :: enum u8 { None, Tracks, Subgrid, Masonry }
Grid_Template :: struct {
	kind:      Grid_Template_Kind,
	tracks:    []Grid_Track,
	end_names: []string,   // line names after the last track
}

Grid_Area :: struct {
	name: string,
	row_start, row_end, col_start, col_end: i32,   // line numbers, 1-based, end exclusive
}

Grid_Areas :: struct {
	rows, cols: i32,
	cells:      []string,     // rows * cols names, "" for a null cell (.)
	areas:      []Grid_Area,
}

Grid_Auto_Flow :: struct { column, dense: bool }

Grid_Line_Kind :: enum u8 { Auto, Line, Span, Name }
// Line: n (may be negative) with an optional name; Span: n (>= 1) with an optional name; Name: an area or line name alone.
Grid_Line :: struct {
	kind: Grid_Line_Kind,
	n:    i32,
	name: string,
}
