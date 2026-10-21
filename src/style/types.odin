package style

import "wb:base"
import "wb:css"

// Computed values: the contract between the style engine and layout / painting. Lengths that depend on the box they
// apply to (percentages, calc() with percentages) stay symbolic; everything else is resolved to CSS pixels.

Length_Kind :: enum u8 {
	Auto,
	None,          // max-width: none, max-height: none
	Normal,
	Px,
	Percent,       // v in 0..100 (not 0..1), as written
	Calc,          // calc.tree has only px and percent leaves; evaluate with css.eval_calc and the percentage base
	Min_Content,
	Max_Content,
	Fit_Content,
}

Length :: struct {
	kind: Length_Kind,
	v:    f32,
	calc: ^css.Calc,
}

px :: proc(v: f32) -> Length { return Length{kind = .Px, v = v} }
auto_length :: Length{kind = .Auto}

// Resolves against `base` (the percentage base, in px). Auto, None and the content keywords return `fallback`.
resolve :: proc(l: Length, base: f32, fallback: f32 = 0) -> f32 {
	switch l.kind {
	case .Px: return l.v
	case .Percent: return base * l.v / 100
	case .Calc: return f32(css.eval_calc(l.calc, css.Length_Context{percent_base = f64(base)}))
	case .Auto, .None, .Normal, .Min_Content, .Max_Content, .Fit_Content: return fallback
	}
	return fallback
}

has_percent :: proc(l: Length) -> bool { return l.kind == .Percent || l.kind == .Calc }

Side :: enum u8 { Top, Right, Bottom, Left }
Corner :: enum u8 { Top_Left, Top_Right, Bottom_Right, Bottom_Left }
Corner_Radius :: struct { h, v: Length }

Display :: enum u8 {
	Inline, Block, Inline_Block, Flow_Root, List_Item, Flex, Inline_Flex, Grid, Inline_Grid,
	Table, Inline_Table, Table_Row_Group, Table_Header_Group, Table_Footer_Group, Table_Row, Table_Column_Group, Table_Column,
	Table_Cell, Table_Caption, Contents, None,
}

Position :: enum u8 { Static, Relative, Absolute, Fixed, Sticky }
Float :: enum u8 { None, Left, Right }
Clear :: enum u8 { None, Left, Right, Both }
Box_Sizing :: enum u8 { Content_Box, Border_Box }
Visibility :: enum u8 { Visible, Hidden, Collapse }
Overflow :: enum u8 { Visible, Hidden, Clip, Scroll, Auto }
Border_Style :: enum u8 { None, Hidden, Solid, Dashed, Dotted, Double, Groove, Ridge, Inset, Outset }
Font_Style :: enum u8 { Normal, Italic, Oblique }
// Legacy_*: -webkit-left / -webkit-right / -webkit-center, what HTML's align attributes and <center> map to (HTML §15.3.3
// "align descendants"): text aligned as Left / Right / Center, and block-level children narrower than their parent placed
// the same way (layout, block_width).
Text_Align :: enum u8 { Start, End, Left, Right, Center, Justify, Legacy_Left, Legacy_Right, Legacy_Center }
Text_Transform :: enum u8 { None, Capitalize, Uppercase, Lowercase }
White_Space :: enum u8 { Normal, Nowrap, Pre, Pre_Wrap, Pre_Line, Break_Spaces }
Word_Break :: enum u8 { Normal, Break_All, Keep_All, Break_Word }
Overflow_Wrap :: enum u8 { Normal, Break_Word, Anywhere }
Direction :: enum u8 { Ltr, Rtl }
Decoration :: enum u8 { Underline, Overline, Line_Through }
Decorations :: bit_set[Decoration; u8]
List_Style_Type :: enum u8 { None, Disc, Circle, Square, Decimal, Decimal_Leading_Zero, Lower_Alpha, Upper_Alpha, Lower_Roman, Upper_Roman, Lower_Greek }
List_Style_Position :: enum u8 { Outside, Inside }
Cursor :: enum u8 { Auto, Default, Pointer, Text, Move, Not_Allowed, Wait, Help, Crosshair, Grab, Grabbing, Progress, Zoom_In, Zoom_Out, E_Resize, N_Resize, Ew_Resize, Ns_Resize, None }
User_Select :: enum u8 { Auto, None, Text, All }
Object_Fit :: enum u8 { Fill, Contain, Cover, None, Scale_Down }
Repeat :: enum u8 { Repeat, No_Repeat, Repeat_X, Repeat_Y, Space, Round }
Flex_Direction :: enum u8 { Row, Row_Reverse, Column, Column_Reverse }
Flex_Wrap :: enum u8 { Nowrap, Wrap, Wrap_Reverse }
Content_Align :: enum u8 { Normal, Auto, Start, End, Flex_Start, Flex_End, Center, Stretch, Space_Between, Space_Around, Space_Evenly, Baseline }
Vertical_Align_Kind :: enum u8 { Baseline, Sub, Super, Top, Text_Top, Middle, Bottom, Text_Bottom, Length }

Vertical_Align :: struct { kind: Vertical_Align_Kind, amount: Length }   // Length: px or percent of line-height

Line_Height_Kind :: enum u8 { Normal, Number, Length }
Line_Height :: struct { kind: Line_Height_Kind, v: f32 }   // Number: a multiple of font-size (inherited as a number); Length: px

Image_Kind :: enum u8 { None, Url, Gradient }
Image :: struct {
	kind: Image_Kind,
	url:  string,         // Url: as written (resolved against the sheet by the loader)
	gradient: string,     // Gradient: the function as CSS text (kept for diagnostics and older painters)
	grad: ^Gradient,      // Gradient: the parsed gradient (see types_more.odin); this is what a painter should use
}

Bg_Size_Kind :: enum u8 { Auto, Cover, Contain, Length }
Bg_Size :: struct { kind: Bg_Size_Kind, w, h: Length }

Shadow :: struct {
	x, y, blur, spread: f32,
	color: css.Color,
	inset: bool,
}

Content_Kind :: enum u8 { Normal, None, Items }
Content_Item_Kind :: enum u8 { Text, Attr, Open_Quote, Close_Quote, Url }
Content_Item :: struct { kind: Content_Item_Kind, text: string }
// `items` is the resolved value, ready to display: only Text (attr(), counters and quotes already replaced by their text)
// and Url items. `parts` is the value as specified (see Content_Part), which the style engine resolves in document order.
Content :: struct { kind: Content_Kind, items: []Content_Item, parts: []Content_Part }

// Custom properties (--name) as resolved text. Shared between a parent and every child that declares none of its own;
// a child that declares some is a layer over its parent's (custom_props.odin): `values` holds only what it sets, so a
// page with hundreds of variables on :root does not copy them all into every element that sets one more. Read them with
// custom_get / custom_flatten, not through `values`.
Custom_Props :: struct {
	values:  map[string]string,   // this layer's names (every name when `parent` is nil)
	removed: []string,            // names the parent has that this layer drops (not in `values`)
	parent:  ^Custom_Props,       // the layer below, nil for a flat map
	depth:   int,                 // layers below this one
	total:   int,                 // names present, all layers counted
}

Computed :: struct {
	node:   base.Handle,
	// --- box ---
	display:    Display,
	position:   Position,
	float:      Float,
	clear:      Clear,
	box_sizing: Box_Sizing,
	visibility: Visibility,
	overflow_x, overflow_y: Overflow,
	inset:      [Side]Length,
	z_auto:     bool,
	z_index:    i32,
	width, height, min_width, min_height, max_width, max_height: Length,   // min-*: Auto = the automatic minimum size (0 outside flex and grid items)
	margin:     [Side]Length,
	padding:    [Side]Length,
	border_width: [Side]f32,
	border_style: [Side]Border_Style,
	border_color: [Side]css.Color,
	radius:     [Corner]Corner_Radius,
	opacity:    f32,
	vertical_align: Vertical_Align,
	aspect_ratio: f32,        // width / height, 0 = auto
	aspect_ratio_auto: bool,  // `auto && <ratio>`: a replaced element with a natural ratio uses that one instead
	object_fit: Object_Fit,
	// --- flex ---
	flex_direction: Flex_Direction,
	flex_wrap:      Flex_Wrap,
	flex_grow, flex_shrink: f32,
	flex_basis:     Length,
	justify_content, align_items, align_self, align_content: Content_Align,
	order:          i32,
	row_gap, column_gap: Length,
	// --- color schemes (color_scheme.odin) ---
	color_scheme: Color_Scheme_Value,
	used_scheme:  Scheme,         // light or dark: the system colors and light-dark() branch this element uses
	color_pair:   Scheme_Color,   // `color` resolved in both schemes (children with another scheme pick the other)
	// --- text ---
	color:      css.Color,
	font_family: []string,
	font_size:  f32,
	font_size_src: Font_Size_Src,   // where font_size came from (values.odin generic_family_adjust): part of font-size
	font_weight: u16,
	font_style: Font_Style,
	line_height: Line_Height,
	letter_spacing, word_spacing: f32,
	text_align: Text_Align,
	text_decoration: Decorations,
	text_decoration_color: css.Color,
	text_transform: Text_Transform,
	text_indent: Length,
	text_ellipsis: bool,
	white_space: White_Space,
	word_break: Word_Break,
	overflow_wrap: Overflow_Wrap,
	tab_size:   f32,            // tab_spaces: a number of spaces (initial 8), else px
	tab_spaces: bool,
	direction:  Direction,
	text_shadow: []Shadow,
	// --- background ---
	background_color: css.Color,
	background_image: Image,
	background_repeat: [2]Repeat,
	background_position: [2]Length,
	background_size: Bg_Size,
	box_shadow: []Shadow,
	// --- misc ---
	list_style_type: List_Style_Type,
	list_style_position: List_Style_Position,
	cursor:     Cursor,
	pointer_events: bool,
	user_select: User_Select,
	content:    Content,
	outline_width: f32,
	outline_style: Border_Style,
	outline_color: css.Color,
	outline_offset: f32,
	border_collapse: bool,
	border_spacing: [2]f32,
	// --- text (CSS Text 4, Fonts 4, Text Decoration 4) ---
	font_stretch:      f32,                 // percentage, 100 = normal
	font_variant_caps: Font_Variant_Caps,
	text_decoration_style: Text_Decoration_Style,
	text_decoration_thickness: Length,      // Auto, Normal (= from-font) or Px
	text_underline_offset: Length,          // Auto or Px
	white_space_collapse: White_Space_Collapse,   // `white_space` above is derived from these two
	text_wrap_mode:    Text_Wrap_Mode,
	text_wrap_style:   Text_Wrap_Style,
	hyphens:           Hyphens,
	// --- fonts: OpenType features and variations (font_features.odin), bidi ---
	font_feature_settings:   []Font_Feature_Setting,     // nil = normal
	font_variation_settings: []Font_Variation_Setting,   // nil = normal
	font_kerning:            Font_Kerning,
	font_variant_ligatures:  Font_Variant_Ligatures,
	font_variant_numeric:    Font_Variant_Numeric,
	font_variant_east_asian: Font_Variant_East_Asian,
	font_variant_position:   Font_Variant_Position,
	unicode_bidi:            Unicode_Bidi,
	// --- backgrounds: every layer (the singular fields above are the first layer). See `background_layers`. ---
	background_images:      []Image,
	background_repeats:     [][2]Repeat,
	background_positions:   [][2]Length,
	background_sizes:       []Bg_Size,
	background_origins:     []Box_Area,
	background_clips:       []Box_Area,
	background_attachments: []Bg_Attachment,
	// --- transforms (CSS Transforms 1 and 2; 3D is parsed and flattened) ---
	transform:        []Transform_Op,       // nil = none
	transform_origin: [2]Length,            // percentages of the reference box
	transform_box:    Transform_Box,
	transform_style:  Transform_Style,
	translate:        Translate_Value,
	rotate:           Rotate_Value,
	scale:            Scale_Value,
	perspective:      f32,                  // 0 = none
	perspective_origin: [2]Length,
	backface_visibility: Backface_Visibility,
	// --- transitions and animations: the lists as specified, see `transition_at` / `animation_at` for repetition ---
	transition_property: []Transition_Prop,
	transition_duration: []f32,             // ms
	transition_timing:   []Easing,
	transition_delay:    []f32,             // ms
	transition_behavior: []bool,            // allow-discrete
	animation_name:      []string,          // "" = none
	animation_duration:  []f32,             // ms
	animation_timing:    []Easing,
	animation_delay:     []f32,             // ms
	animation_iterations: []f32,            // math.INF_F32 = infinite
	animation_direction: []Anim_Direction,
	animation_fill_mode: []Fill_Mode,
	animation_play_state: []Play_State,
	animation_composition: []Composition,
	// --- generated content ---
	counter_reset:     []Counter_Op,
	counter_increment: []Counter_Op,
	counter_set:       []Counter_Op,
	quotes:            Quotes,
	list_style:        List_Marker_Style,   // every counter style; `list_style_type` above is the nearest legacy value
	marker_text:       string,              // display: list-item only: the resolved marker, suffix included ("3. ", "• ")
	// --- effects ---
	object_position:   [2]Length,
	filter:            []Filter_Op,
	backdrop_filter:   []Filter_Op,
	clip_path:         ^Clip_Path,         // nil = none
	isolation:         Isolation,
	mix_blend_mode:    Blend_Mode,
	// --- misc ---
	will_change:       []string,
	contain:           Contain,
	content_visibility: Content_Visibility,
	scroll_behavior:   Scroll_Behavior,
	overscroll_x, overscroll_y: Overscroll,
	caret_color:       Auto_Color,
	accent_color:      Auto_Color,
	appearance:        Appearance,
	resize:            Resize,
	column_count:      i32,                 // 0 = auto
	column_width:      Length,              // Auto or Px
	// --- grid (stored for the grid layout) ---
	grid_template_columns, grid_template_rows: Grid_Template,
	grid_template_areas: Grid_Areas,
	grid_auto_columns, grid_auto_rows: []Grid_Track,
	grid_auto_flow:    Grid_Auto_Flow,
	grid_row_start, grid_row_end, grid_column_start, grid_column_end: Grid_Line,
	justify_items, justify_self: Content_Align,
	// --- container queries (container.odin) ---
	container_type:    Container_Type,
	container_name:    []string,
	// --- scroll bars (container.odin; the bars are overlays: scrollbar-gutter is kept but reserves nothing) ---
	scrollbar_width:   Scrollbar_Width,
	scrollbar_color:   Scrollbar_Colors,
	scrollbar_gutter:  Scrollbar_Gutter,
	// --- masks (masks.odin; every layer, see `mask_layers`) and -webkit-text-fill-color ---
	mask_images:       []Image,
	mask_modes:        []Mask_Mode,
	mask_repeats:      [][2]Repeat,
	mask_positions:    [][2]Length,
	mask_sizes:        []Bg_Size,
	mask_origins:      []Mask_Box,
	mask_clips:        []Mask_Box,
	mask_composites:   []Mask_Composite,
	text_fill_color:   Auto_Color,          // auto = currentcolor
	// --- bookkeeping ---
	containers: ^Container_Ctx, // the query containers this element's children see (nearest first)
	anim_vars:  []Pre_Decl,     // an animated element: its declarations that use var(), copied (registered custom properties animate through them)
	inherits:   Prop_Set,       // inherited properties whose value came from the parent (not set by a declaration)
	custom:     ^Custom_Props,
	before, after: ^Computed,   // generated boxes (nil when `content` is none/normal)
	selection:  ^Computed,      // ::selection rules of the element (nil: none; colors only are used)
}

// Longhand properties. Order matters: values that others depend on (color-scheme for every color, font-size for em,
// color for currentcolor) come first.
// How a font size was given, for the size change of an element whose family becomes (or stops being) the generic
// `monospace` (as Chromium does): an absolute-size keyword (its index in xx-small..xxx-large, -1: none) is looked up
// again for the new family; a size from absolute units (`absolute`) stays; others scale by the ratio of the default
// monospace size to the default size.
Font_Size_Src :: struct {
	keyword:  i8,
	absolute: bool,
}

Prop :: enum u8 {
	Color_Scheme, Font_Size, Color,
	Font_Family, Font_Weight, Font_Style, Font_Stretch, Font_Variant_Caps, Line_Height, Letter_Spacing, Word_Spacing, Text_Align,
	Text_Decoration_Line, Text_Decoration_Color, Text_Decoration_Style, Text_Decoration_Thickness, Text_Underline_Offset,
	Text_Transform, Text_Indent, Text_Overflow, White_Space_Collapse, Text_Wrap_Mode, Text_Wrap_Style, Word_Break,
	Overflow_Wrap, Hyphens, Tab_Size, Direction, Text_Shadow,
	Font_Feature_Settings, Font_Variation_Settings, Font_Kerning, Font_Variant_Ligatures, Font_Variant_Numeric,
	Font_Variant_East_Asian, Font_Variant_Position, Unicode_Bidi,
	Display, Position, Float, Clear, Top, Right, Bottom, Left, Z_Index, Box_Sizing,
	Width, Height, Min_Width, Min_Height, Max_Width, Max_Height,
	Margin_Top, Margin_Right, Margin_Bottom, Margin_Left,
	Padding_Top, Padding_Right, Padding_Bottom, Padding_Left,
	Border_Top_Style, Border_Right_Style, Border_Bottom_Style, Border_Left_Style,
	Border_Top_Width, Border_Right_Width, Border_Bottom_Width, Border_Left_Width,
	Border_Top_Color, Border_Right_Color, Border_Bottom_Color, Border_Left_Color,
	Border_Top_Left_Radius, Border_Top_Right_Radius, Border_Bottom_Right_Radius, Border_Bottom_Left_Radius,
	Overflow_X, Overflow_Y, Visibility, Opacity, Vertical_Align, Aspect_Ratio, Object_Fit,
	Flex_Direction, Flex_Wrap, Flex_Grow, Flex_Shrink, Flex_Basis, Justify_Content, Align_Items, Align_Self, Align_Content,
	Order, Row_Gap, Column_Gap,
	Background_Color, Background_Image, Background_Repeat, Background_Position, Background_Size,
	Background_Origin, Background_Clip, Background_Attachment, Box_Shadow,
	List_Style_Type, List_Style_Position, Cursor, Pointer_Events, User_Select, Content,
	Outline_Width, Outline_Style, Outline_Color, Outline_Offset, Border_Collapse, Border_Spacing,
	Transform, Transform_Origin, Transform_Box, Transform_Style, Translate, Rotate, Scale, Perspective, Perspective_Origin,
	Backface_Visibility,
	Transition_Property, Transition_Duration, Transition_Timing_Function, Transition_Delay, Transition_Behavior,
	Animation_Name, Animation_Duration, Animation_Timing_Function, Animation_Delay, Animation_Iteration_Count,
	Animation_Direction, Animation_Fill_Mode, Animation_Play_State, Animation_Composition,
	Counter_Reset, Counter_Increment, Counter_Set, Quotes,
	Object_Position, Filter, Backdrop_Filter, Clip_Path, Isolation, Mix_Blend_Mode,
	Will_Change, Contain, Content_Visibility, Scroll_Behavior, Overscroll_Behavior_X, Overscroll_Behavior_Y,
	Caret_Color, Accent_Color, Appearance, Resize, Column_Count, Column_Width,
	Grid_Template_Columns, Grid_Template_Rows, Grid_Template_Areas, Grid_Auto_Columns, Grid_Auto_Rows, Grid_Auto_Flow,
	Grid_Row_Start, Grid_Row_End, Grid_Column_Start, Grid_Column_End, Justify_Items, Justify_Self,
	Container_Type, Container_Name, Scrollbar_Width, Scrollbar_Color, Scrollbar_Gutter,
	Mask_Image, Mask_Mode, Mask_Repeat, Mask_Position, Mask_Size, Mask_Origin, Mask_Clip, Mask_Composite, Text_Fill_Color,
}

// A set of properties. Wider than a bit_set can be (there are more than 128 longhands), hence the procedures in props.odin:
// `ps_has`, `ps_add`, `ps_remove`, `ps_union`, `ps_empty`.
PROP_COUNT :: len(Prop)
Prop_Set :: struct { bits: [(PROP_COUNT + 63) / 64]u64 }

// Inherited properties (CSS: "Inherited: yes"). See `is_inherited`.
INHERITED_PROPS :: [?]Prop{
	.Color_Scheme, .Font_Size, .Color, .Font_Family, .Font_Weight, .Font_Style, .Font_Stretch, .Font_Variant_Caps, .Line_Height,
	.Letter_Spacing, .Word_Spacing, .Text_Align, .Text_Transform, .Text_Indent, .White_Space_Collapse, .Text_Wrap_Mode,
	.Text_Wrap_Style, .Word_Break, .Overflow_Wrap, .Hyphens, .Tab_Size, .Direction, .Text_Shadow, .Text_Underline_Offset,
	.Visibility, .List_Style_Type, .List_Style_Position, .Cursor, .Pointer_Events, .Border_Collapse, .Border_Spacing,
	.Quotes, .Caret_Color, .Accent_Color, .Scrollbar_Color,
	.Font_Feature_Settings, .Font_Variation_Settings, .Font_Kerning, .Font_Variant_Ligatures, .Font_Variant_Numeric,
	.Font_Variant_East_Asian, .Font_Variant_Position, .Text_Fill_Color,
}

// Shorthands: expanded to longhands when a stylesheet is compiled.
Short :: enum u8 {
	None,
	Margin, Padding, Border, Border_Width, Border_Style, Border_Color, Border_Top, Border_Right, Border_Bottom, Border_Left,
	Border_Radius, Background, Font, Flex, Flex_Flow, Gap, Overflow, Inset, List_Style, Text_Decoration, Outline,
	Place_Content, Place_Items, Place_Self,
	Margin_Block, Margin_Inline, Padding_Block, Padding_Inline, Inset_Block, Inset_Inline,
	White_Space, Text_Wrap, Font_Variant, Transition, Animation, Overscroll_Behavior, Columns,
	Grid_Template, Grid, Grid_Row, Grid_Column, Grid_Area,
	Container, Border_Block, Border_Inline, Border_Block_Width, Border_Block_Style, Border_Block_Color,
	Border_Inline_Width, Border_Inline_Style, Border_Inline_Color,
	Mask,
}
