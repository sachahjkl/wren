# The licence

Wren's licence is the toolkit's `prefs_page.Licence` (`ext/gui_toolkit/src/prefs_page/licence.odin`, its intent
`ext/gui_toolkit/src/md/features/licence-card.md`): the Licence page of the settings, with the store's reads and writes
on tasks, the key field, *Choose a licence file…*, *Remove the licence*, and the card `ui.licence_card`. Wren is a thin
layer over it (`src/browser/license_shell.odin`).

## What Wren gives

- **The store's options**: the product `license.WREN`, the file (`license_path`: the profile's `license.wrenlicense`, or
  `browser.license.path`; memory only when the profile is not kept), `browser.license.public_key`, the development key
  in a development or experimental build, the embedded licence of a pre-registered build (`seed`).
- **Its name, its pricing page** (`browser.license.support_url`, a web page only), **its logo** (`APP_LOGO_PNG`) and
  **its vendor** ("Froment Software", on the back of the card).

`licence_start` runs at the end of `app_ui_init`: the page's tasks answer in the first window's `ui.State`, whichever
window shows the settings. `licence_stop` runs in `app_free` after the windows' States are closed, and only when
`licence_start` ran.

## Where it shows

- **The settings**: `Page_Options.licence` adds the Licence page. `about:settings#licence` (`SETTINGS_LICENCE_URL`)
  opens the settings on it: `show_settings` gives the fragment to `prefs_page.show`. A fragment is the smallest way: the
  address is in the history, a reload or Back shows the same page, and no new address scheme is needed.
- **about:wren**: one line, from the Licence's last status (`read`, `status`): "Registered to <name> · <edition>
  license", "Reading the license…" before the first read, else "Unregistered — free during the beta · Support Wren";
  then the link *Manage the license* to `about:settings#licence`. On one screen each fact is said once: the card,
  the date, the order and the e-mail are the settings' page's, not this page's. The page is HTML made once when shown,
  so `licence_frame` builds the about:wren tabs again when a task of the store has answered (the end of a `busy`, or the
  first `read`).
- **A `.wrenlicense` file** dropped on the window, given on the command line or typed in the address bar:
  `licence_install_file`, then the settings' Licence page in that tab, whose entry becomes `about:settings#licence`.
  `is_license_file_address` and `nav_judge` still decide who may install one.

## Refused

- **Wren's own HTML card in about:wren** (`about_card*.odin`) with its CSS shaders (`card-foil`, `card-seal`,
  `card-back`): a second card to maintain beside the toolkit's, and the toolkit's is the same in every program.
- **The page-engine CSS extension `-wren-shader`** (`src/style/wren_shader.odin`, `src/browser/shaders.odin`) and the
  permission of the browser's own pages to use it (`page.Settings.internal_address`): only that card used them.
- **Wren's own store shell and its wording**: the toolkit's page has the store's jobs and one wording for every
  program.
- **A form in about:wren** (`about:wren?action=register`): a key in an address, and a second place to enter it.
