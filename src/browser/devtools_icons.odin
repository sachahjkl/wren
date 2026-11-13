package browser

// The developer tools' icons: each a Lucide glyph (Wren's one icon set), its ink centred in the square it is drawn in and no
// larger than it, in the colour it is given. The record button's dot stays a filled disc: Lucide's circles are rings.

import "core:math"
import "toolkit:draw"
import "toolkit:font"
import lucide "toolkit:lucide"

Dt_Icon :: enum u8 {
	None,
	Close, Clear, Trash, Pause, Play, Record, Plus, Minus, Check,
	Chevron_Down, Chevron_Up, Chevron_Right, Chevron_Left, Caret_Down, Caret_Right,
	Search, Kebab, Gear, Filter, Inspect, Copy, Refresh, Download, Upload, Eye, Block,
	Dock_Bottom, Dock_Right, Dock_Left, Float, Detach,
	Info, Warn, Error, Verbose, Prompt, Result, Bracket,
	Sort_Up, Sort_Down,
	File_Doc, File_Script, File_Css, File_Image, File_Font, File_Json, File_Media, File_Socket, File_Fetch, File_Wasm, File_Other,
	Tab_Console, Tab_Elements, Tab_Network, Tab_Application, Tab_Performance, Tab_Memory,
	Cookie, Database, Folder, Lock, Throttle, Pin, Edit, Clock, Style, Layout, Event, Access, Computed,
}

DT_ICON_GLYPHS :: [Dt_Icon]string{
	.None = "",
	.Close = lucide.X, .Clear = lucide.BAN, .Trash = lucide.TRASH_2, .Pause = lucide.PAUSE, .Play = lucide.PLAY, .Record = "",
	.Plus = lucide.PLUS, .Minus = lucide.MINUS, .Check = lucide.CHECK,
	.Chevron_Down = lucide.CHEVRON_DOWN, .Chevron_Up = lucide.CHEVRON_UP, .Chevron_Right = lucide.CHEVRON_RIGHT, .Chevron_Left = lucide.CHEVRON_LEFT,
	.Caret_Down = lucide.CHEVRON_DOWN, .Caret_Right = lucide.CHEVRON_RIGHT,
	.Search = lucide.SEARCH, .Kebab = lucide.ELLIPSIS_VERTICAL, .Gear = lucide.SETTINGS, .Filter = lucide.FILTER, .Inspect = lucide.MOUSE_POINTER_2,
	.Copy = lucide.COPY, .Refresh = lucide.REFRESH_CW, .Download = lucide.DOWNLOAD, .Upload = lucide.UPLOAD, .Eye = lucide.EYE, .Block = lucide.BAN,
	.Dock_Bottom = lucide.PANEL_BOTTOM, .Dock_Right = lucide.PANEL_RIGHT, .Dock_Left = lucide.PANEL_LEFT, .Float = lucide.PICTURE_IN_PICTURE_2,
	.Detach = lucide.EXTERNAL_LINK,
	.Info = lucide.INFO, .Warn = lucide.ALERT_TRIANGLE, .Error = lucide.CIRCLE_X, .Verbose = lucide.BUG, .Prompt = lucide.CHEVRON_RIGHT,
	.Result = lucide.CORNER_DOWN_LEFT, .Bracket = lucide.BRACES,
	.Sort_Up = lucide.ARROW_UP, .Sort_Down = lucide.ARROW_DOWN,
	.File_Doc = lucide.FILE_TEXT, .File_Script = lucide.FILE_CODE, .File_Css = lucide.PAINTBRUSH, .File_Image = lucide.IMAGE, .File_Font = lucide.TYPE,
	.File_Json = lucide.FILE_BRACES, .File_Media = lucide.FILM, .File_Socket = lucide.PLUG, .File_Fetch = lucide.ARROW_DOWN_UP, .File_Wasm = lucide.BINARY,
	.File_Other = lucide.FILE,
	.Tab_Console = lucide.SQUARE_TERMINAL, .Tab_Elements = lucide.CODE, .Tab_Network = lucide.NETWORK, .Tab_Application = lucide.DATABASE,
	.Tab_Performance = lucide.GAUGE, .Tab_Memory = lucide.MEMORY_STICK,
	.Cookie = lucide.COOKIE, .Database = lucide.DATABASE, .Folder = lucide.FOLDER, .Lock = lucide.LOCK, .Throttle = lucide.GAUGE, .Pin = lucide.PIN,
	.Edit = lucide.PENCIL, .Clock = lucide.CLOCK_3, .Style = lucide.PAINTBRUSH, .Layout = lucide.LAYOUT_GRID, .Event = lucide.ZAP,
	.Access = lucide.ACCESSIBILITY, .Computed = lucide.CALCULATOR,
}

// `size`: the side of the square the icon is drawn in, centred on `center`. `sc` stays for the callers' scale (unused by glyphs).
dt_icon :: proc(dc: ^draw.Context, icon: Dt_Icon, center: draw.Vec2, size: f32, col: draw.Color, sc: f32) {
	if icon == .Record {
		r := math.round(size * 0.28)
		c := draw.Vec2{math.round(center.x), math.round(center.y)}
		draw.rect(dc, {c - r, c + r}, col, r)
		return
	}
	glyphs := DT_ICON_GLYPHS   // (the constant table as a value, indexed by the icon)
	glyph := glyphs[icon]
	if glyph == "" { return }
	app := the_app
	fit := icon_glyph_fit(size, font.glyph(&app.fonts, app.lucide, size, icon_rune(glyph)).size)
	g := font.glyph(&app.fonts, app.lucide, fit, icon_rune(glyph))
	w := g.size.x > 0 ? g.size.x : g.advance
	pen := draw.Vec2{math.round(center.x - w * 0.5 - g.offset.x), math.round(center.y - (g.offset.y + g.size.y * 0.5))}
	draw.text(dc, app.lucide, fit, pen, col, glyph)
}
