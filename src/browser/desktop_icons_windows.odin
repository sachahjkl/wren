package browser

import desktop "toolkit:desktop"

// The icons of the theme on freedesktop.org desktops: none on Windows, which uses the executable's own.
desktop_icons :: proc() -> []desktop.Icon { return nil }
