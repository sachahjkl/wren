# The toolkit's standard pages in about:settings

about:settings is the toolkit's `prefs_page` (`src/browser/settings_page.odin`). After Wren's own pages it shows the
toolkit's standard pages, the same as in every program of the family. Wren had its own copy of four of them; each copy
is gone.

| Page | What Wren gives it | What it replaced in Wren |
|---|---|---|
| What's new (`Page_Options.changelog`) | `CHANGELOG.md` by `#load`; `changelog_register`; `changelog_after_update` once at start, whose click opens `about:settings#whats_new` | nothing in the browser: only the docs site had a changelog page, and it keeps its own (`src/tools/docsite`) |
| Licence (`Page_Options.licence`) | its store (`license_shell.odin`, [licence.md](licence.md)) | the HTML card (earlier work) |
| Installation (`Page_Options.install`) | `prefs_page.Install` with `setup_config`: Wren's identity, icons, choices and `setup_prepare` (`setup.odin`) | Wren's own state machine around `setup.Dialog`: the start's reading on the blocking pool, `setup.txt` in the profile, the cleanup of `.old` files |
| Updates (`Page_Options.updater`, under `update.auto` on the System page) | `prefs_page.Updates` with `wren_update.PRODUCT` and the repository `sachahjkl/wren` (`updates.odin`) | `update_check.odin` (GitHub's API, `update.txt`), `update_install.odin` (manifest, signature, download, placement), the Updates section and forms of about:wren, the `browser.update.*` preferences |
| Diagnostics (`Page_Options.diagnostics`) | a `prefs_page.Diagnostics_Source`: `App.r`, the window being built, its `Frame_Ring` | nothing: Wren had no such page |

## Decisions

- **The answer of the offer is a preference** (`install.choice`), in `prefs.txt` with the others. `setup.txt` is gone,
  and nothing reads it: a profile that answered before is asked once more.
- **The reading of the install always runs at start**, offer or not (`install_offer(…, offer = false)`): the installed
  copy deletes what a replacement left, and the updater learns which copy runs. Only the installed copy with
  `update.auto` on updates by itself; any other waits for Check now.
- **The modal opens in a build of the front window** (`Setup_State.asked`): `setup.open` needs the `ui.Views` of the
  window being built, and a command or a second start's `--setup` runs outside any build.
- **One restart path, `App.relaunch`.** The installed copy that Setup asks to open and the program an update put in
  place both start after `instance_release`: started earlier, they would find this Wren on the profile and hand over to
  it. Wren's old Setup never started the installed copy.
- **Wren's own choices stay Wren's**: Add to PATH, Register as a browser, and Update by itself (where Wren updates
  itself). An install writes what was ticked into the preferences, as before.
- **Updates only on Windows, only in a release build.** The Linux release is a `tar.gz` and Nix updates its package: no
  release publishes `update-linux-x64.json`, and the updater would read the 404 as "up to date". There the Updates set
  is not registered, and the command "Check for updates" opens the release page. A development or labelled build is
  updated by hand: no updater runs.
- **The manifest is the one the release already signs** (`wrentool package`: `update.manifest_of`, `update.sign` with
  `PRODUCT`). The updater reads `releases/latest/download/update-windows-x64.json`, where the old check read
  `releases/download/v<version>/`: GitHub serves the latest release's assets there.
- **Diagnostics without the toolkit's host.** Wren's loop is its own (`wb:host`). The page reads plain data; each window
  records its frames with `host.frame_add` after its present (`main.odin` `frame`).

## Refused

- **Keeping about:wren's update forms.** The settings say the state once; about:wren links to the pages.
- **A `host.Host` filled by Wren for the Diagnostics page.** The host holds the renderer by value; see the toolkit's
  `src/md/features/diagnostics.md`.
