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
Text_Align :: enum u8 { Start, End, Left, Right, Center, Justify }
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
	gradient: string,     // Gradient: the function as CSS text; painted by the renderer
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
Content :: struct { kind: Content_Kind, items: []Content_Item }

// Custom properties (--name) as resolved text. Shared between a parent and every child that declares none of its own.
Custom_Props :: struct {
	values: map[string]string,
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
	width, height, min_width, min_height, max_width, max_height: Length,
	margin:     [Side]Length,
	padding:    [Side]Length,
	border_width: [Side]f32,
	border_style: [Side]Border_Style,
	border_color: [Side]css.Color,
	radius:     [Corner]Corner_Radius,
	opacity:    f32,
	vertical_align: Vertical_Align,
	aspect_ratio: f32,        // width / height, 0 = auto
	object_fit: Object_Fit,
	// --- flex ---
	flex_direction: Flex_Direction,
	flex_wrap:      Flex_Wrap,
	flex_grow, flex_shrink: f32,
	flex_basis:     Length,
	justify_content, align_items, align_self, align_content: Content_Align,
	order:          i32,
	row_gap, column_gap: Length,
	// --- text ---
	color:      css.Color,
	font_family: []string,
	font_size:  f32,
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
	tab_size:   f32,
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
	// --- bookkeeping ---
	custom:     ^Custom_Props,
	before, after: ^Computed,   // generated boxes (nil when `content` is none/normal)
}

// Longhand properties. Order matters: values that others depend on (font-size for em, color for currentcolor) come first.
Prop :: enum u8 {
	Font_Size, Color,
	Font_Family, Font_Weight, Font_Style, Line_Height, Letter_Spacing, Word_Spacing, Text_Align,
	Text_Decoration_Line, Text_Decoration_Color, Text_Transform, Text_Indent, Text_Overflow, White_Space, Word_Break,
	Overflow_Wrap, Tab_Size, Direction, Text_Shadow,
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
	Background_Color, Background_Image, Background_Repeat, Background_Position, Background_Size, Box_Shadow,
	List_Style_Type, List_Style_Position, Cursor, Pointer_Events, User_Select, Content,
	Outline_Width, Outline_Style, Outline_Color, Outline_Offset, Border_Collapse, Border_Spacing,
}

Prop_Set :: bit_set[Prop; u128]

INHERITED :: Prop_Set{
	.Font_Size, .Color, .Font_Family, .Font_Weight, .Font_Style, .Line_Height, .Letter_Spacing, .Word_Spacing, .Text_Align,
	.Text_Transform, .Text_Indent, .White_Space, .Word_Break, .Overflow_Wrap, .Tab_Size, .Direction, .Text_Shadow,
	.Visibility, .List_Style_Type, .List_Style_Position, .Cursor, .Pointer_Events, .Border_Collapse, .Border_Spacing,
}

// Shorthands: expanded to longhands when a stylesheet is compiled.
Short :: enum u8 {
	None,
	Margin, Padding, Border, Border_Width, Border_Style, Border_Color, Border_Top, Border_Right, Border_Bottom, Border_Left,
	Border_Radius, Background, Font, Flex, Flex_Flow, Gap, Overflow, Inset, List_Style, Text_Decoration, Outline,
	Place_Content, Place_Items, Place_Self,
	Margin_Block, Margin_Inline, Padding_Block, Padding_Inline, Inset_Block, Inset_Inline,
}
