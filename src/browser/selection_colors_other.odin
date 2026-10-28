#+build !windows
package browser

// The default text-selection colors off Windows (selection_colors_windows.odin uses the system highlight). The toolkit
// does not yet report the desktop's highlight colour on Linux, so this uses the common blue selection (close to the
// default of GTK and of Chromium on Linux): #3584e4 background, white text. A user can set exact colours through the
// browser.selection.* preferences, which win over these.

import "toolkit:draw"

system_selection_bg :: proc() -> draw.Color { return draw.srgb(0x35 / 255.0, 0x84 / 255.0, 0xe4 / 255.0, 1) }
system_selection_fg :: proc() -> draw.Color { return draw.srgb(1, 1, 1, 1) }
