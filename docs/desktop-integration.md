# Desktop integration

Wren is one portable executable with no installer. The *desktop integration* is what makes it part of the user's
desktop anyway: a launcher in the application menu, its icon, and the registration as a program that can open web
addresses. It is added and removed by one switch, in the user's own profile, never system-wide and never with
administrator rights.

The code that writes, reads and removes all of it is the toolkit's desktop package (`ext/gui_toolkit/src/desktop`,
[its documentation](../ext/gui_toolkit/docs/desktop.md)). Wren gives it its names and marks (`src/desktop/identity.odin`:
the same ones an installed Wren already carries, so it is still recognised and removed), its preferences
(`src/desktop/settings.odin`) and the links that open in it (`src/desktop/links.odin`); `src/browser/desktop_shell.odin` and
`setup.odin` decide when.

Where: the box **Integrate Wren with the desktop** at the top of `about:config` (and the command of the same name in the
palette). Its state is read from the disk every time it is shown, never from a preference, so it is always true.

| State | The box | Meaning |
|---|---|---|
| absent | unticked | none of the files exists |
| installed | ticked | every file exists and runs this executable |
| to repair | ticked, with a note | *points to `<path>` - Update*: the files run another executable (Wren was moved, or updated into another folder); *incomplete - Repair*: some files are missing |

## Windows

Everything is in `HKEY_CURRENT_USER` and the user's Start menu folder.

- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Wren.lnk`, made with `IShellLinkW` and `IPersistFile`: the executable,
  its own icon, its folder as working directory, and the **AppUserModelID**
  `FromentSoftware.Wren` (`IPropertyStore`, `PKEY_AppUserModel_ID`). The program sets the same ID for its windows
  (`SetCurrentProcessExplicitAppUserModelID`, before the first window), so pinning the shortcut to the taskbar and
  grouping the windows under it work.
- Registration as a *candidate* browser. Windows does not let a program make itself the default browser: the user picks
  one in Settings > Apps > Default apps (the box has a button that opens that page).
  - `Software\Clients\StartMenuInternet\Wren` (name, icon, command, `Capabilities` with the URL associations `http` and
    `https` and the file associations of `browser.desktop_integration.file_types`)
  - `Software\RegisteredApplications`, value `Wren`
  - `Software\Classes\WrenHTML`, the ProgID, whose `shell\open\command` is `"<exe>" "%1"`
  - `Software\Classes\wren-http`, `wren-https`, `wren-about`, the schemes of [links that open in Wren](#links-that-open-in-wren):
    default value `URL:Wren`, an empty `URL Protocol`, the `WrenIntegration` mark, and `shell\open\command`
    `"<exe>" --open-url "%1"`
  - then `SHChangeNotify(SHCNE_ASSOCCHANGED)`.
- Development builds use `Wren Dev`, `WrenDev`, `FromentSoftware.Wren.Dev` and the link schemes `wren-dev-http`,
  `wren-dev-https`, `wren-dev-about`: they never touch the release's entries.

Removal deletes the shortcut when it carries the AppUserModelID or runs the executable, the keys that hold the
`WrenIntegration` mark or run the executable, and the `RegisteredApplications` value that names Wren's Capabilities key.
Nothing else: the user's choices (`UserChoice`), other programs' keys, a `Wren.lnk` that is not Wren's all stay.

## Linux

- `$XDG_DATA_HOME/applications/wren.desktop` (`~/.local/share/applications` by default): `Type`, `Name`, `Exec` (quoted as
  the Desktop Entry Specification says, `%U`), `TryExec`, `Icon`, `Categories=Network;WebBrowser;`, `MimeType=` for
  `x-scheme-handler/http`, `x-scheme-handler/https`, the link schemes (`x-scheme-handler/wren-http`, `wren-https`,
  `wren-about`) and the file types, and the marker `X-Wren-Integration=wren`. An entry without the link schemes is "to
  repair".
  `update-desktop-database` runs afterwards when installed. The entry passes `desktop-file-validate`.
- `$XDG_DATA_HOME/icons/hicolor/<n>x<n>/apps/wren.png` for the sizes Wren embeds (16, 32, 64, 256, 512).
- `~/.local/bin/wren`: a symlink to the executable (the Path part). Only a link that runs this program is replaced or removed.

### NixOS

The release is linked for a usual Linux: the loader `/lib64/ld-linux-x86-64.so.2` and the libraries in the system's
folders. NixOS has neither, so the downloaded program starts only in an FHS sandbox (`steam-run`) or with nix-ld. Two ways
to install it:

- **The Nix package** (`nix profile add github:sachahjkl/wren`, or `packages.default` of `flake.nix` in a system
  configuration). Nix builds it from the sources, as `wrentool build release` does, with the menu entry and the icons, and
  `nix profile upgrade` updates it. A copy that runs from the Nix store does not offer Setup by itself.
- **Setup from the downloaded program.** On NixOS (`ID=nixos` in `/etc/os-release`), the install also does this
  (the toolkit's `nixos_linux.odin`):
  1. `nix-build --out-link <install>/nix-runtime` builds a profile of the loader and the libraries the program links
     and opens (`NIXOS_LIBRARIES`, the same list as `runtimeLibs` in `flake.nix`), from the system's nixpkgs
     (`NIX_PATH`, else the flake registry). The link is a root of the garbage collector.
  2. `patchelf` sets the installed copy's loader to the profile's and puts the profile first in its search path.

  The menu entry and `~/.local/bin/wren` then run the copy directly. The link is in the manifest: uninstalling removes it,
  and the next garbage collection frees the profile. If the profile is gone, the copy is *Repair*, and Repair builds it
  again.

## macOS

Not provided: what macOS lists is an application bundle, and Wren is an executable outside any bundle. See the
toolkit's `integration_darwin.odin`.

## Parts, and what the options map to

The integration is a set of **parts**; `install` writes the ones the options ask for and takes away the ones they do not
(that is what *Modify* does); `remove` takes away every part that carries Wren's mark.

| Part | Option in Setup | Windows | Linux |
|---|---|---|---|
| Launcher | Add to Start menu | `Wren.lnk` in the Start menu | the `.desktop` file |
| Desktop shortcut | Create desktop shortcut | a second `.lnk` (same AppUserModelID) in the Desktop folder | not provided |
| Registration | Register as a web browser | the `StartMenuInternet` / ProgID / link scheme keys above | `MimeType=` in the `.desktop` file |
| Path | Add Wren to PATH | the program's folder in `HKCU\Environment\Path` | the symlink `~/.local/bin/wren` |
| Icons | - | - | the hicolor icons |

PATH: the value stays a `REG_EXPAND_SZ`, entries are compared after expanding `%VARIABLES%` (case, slash direction and a
trailing separator do not matter), the folder is never added twice, and open programs are told (`WM_SETTINGCHANGE`
"Environment"). The value `PathDir` under `Software\FromentSoftware\Wren` says which folder Wren added: an entry the user put
there by hand is never taken out (except the folder of a copy that is being uninstalled).

The Path part also holds `wren.com`, the console launcher that makes `wren ctl ...` work in a terminal
([console-launcher.md](console-launcher.md)): `Options.launcher` carries its bytes (the shell passes the ones embedded in
`wren.exe`), `install` writes it beside the executable with the PATH entry and takes it away without it, `remove` and the
uninstall delete it, and the Path part is "incomplete" (Repair) while the entry is there and the launcher is not. A file
of that name without the launcher's mark is never replaced or deleted.

## Setup: the installed copy

The toolkit's `install.odin` (platform agnostic) and `src/browser/setup.odin`, `setup_ui.odin` (the dialog).

- **Where**: `%LOCALAPPDATA%\Programs\Wren\wren.exe` (`Wren Dev` for the development channel), or any folder that passes
  `check_install_dir`: an absolute path on a local drive, no forbidden character, not a drive root, not inside Windows,
  Program Files or ProgramData, not too long, and a file can be written in the nearest folder that exists (probe, nothing is
  created). On Linux: `$XDG_DATA_HOME/wren`.
- **What**: the executable, named `wren.exe` in the install folder, and the manifest `wren_install.txt` (version, channel, every
  file). The release is the program alone (its licenses, its version and the C runtime are in it), so there is nothing else to copy;
  `SETUP_PAYLOAD` can list names beside the running executable that are copied when they exist. The demos and the test server
  are the separate extras archive: they are not installed.
- **Where the installed copy is**: the Settings > Apps record, `Software\Microsoft\Windows\CurrentVersion\Uninstall\Wren`
  (name, version, publisher, `InstallLocation`, icon, `UninstallString` = `"<exe>" --setup`), else the default folder.
- **Replacing a copy that runs**: Windows lets a running program's file be renamed, not overwritten: each file already
  there is moved to `<name>.old`, the new one is written, and the `.old` files are removed (now if nothing holds them, else
  at the next start of the installed copy).
- **Uninstall**: the parts (shortcuts, PATH entry, registration), the record, exactly the files of the manifest, the folders
  that become empty, the install folder when nothing else is in it. A manifest edited by hand cannot reach outside its
  folder. The running copy's own file is renamed aside, and a hidden `cmd.exe` batch file in `%TEMP%` (started when Wren
  ends) waits for the process, deletes it and the manifest, removes the folder and deletes itself.
- **The profile is never touched** by an uninstall (bookmarks, history, settings stay).

States of the dialog (read from the disk by a job of the blocking pool): *Not installed*, *Running installed*, *Running another
copy* (a copy is installed elsewhere; same version or newer: **Replace installed copy**), *Older than installed*,
*Repair* (this is the installed copy but a shortcut, a key, the manifest or a file is missing or runs another executable).

### When it opens

- The command **Setup...** (main menu, palette, a button beside the box in `about:config`) and `wren.exe --setup`: always.
- At the start of a **release** copy that is not the installed one (`browser.desktop_integration.on_first_run`), and when the
  installed copy needs repair: never for development builds, `--profile` profiles, profiles in the temporary folder, portable
  copies, or with `WREN_DESKTOP_INTEGRATION=off` (`src/e2e` sets it for every test).
- The profile remembers the answer in `setup.txt`: **Use standalone** (`choice=standalone`) is for good; closing the dialog
  without an answer (X, Escape, a click outside) is `choice=dismissed` and holds for the current version only.

### Standalone and portable

*Standalone* is a copy that was not installed and keeps the **normal profile** (`%APPDATA%\Wren`). A *portable* copy is a
folder with a file `wren.portable` next to `wren.exe`: its profile (preferences, cookies, history, session, crash reports,
licence) is `<folder>\data`, it never offers Setup by itself, and `--profile DIR` still wins.

### Updates

`browser.update.check_daily` (off: no request is made unless asked): one GET a day of GitHub's latest release
(`browser.update.url`), compared with the running version, announced once per version; nothing is downloaded. The command
**Check for updates** asks at once and opens the release page. State in `update.txt` in the profile. Never for disposable
profiles or with `WREN_UPDATE_CHECK=off`.

### Following the disk

The state is read from the disk, never from a preference. On Windows one named thread (`wren-desktop-watch`) waits for the
system to say that a place of the integration changed: the registry subtree `HKCU\Software` (registration, Uninstall entry),
`HKCU\Environment` (PATH), the Start menu's Programs folder and the Desktop folder (the shortcuts). A change flags the state and
wakes the browser: the box in `about:config` reads it again when shown, and an open Setup dialog reads it again (its state and
badge follow what Settings > Apps, another Wren or a script did; the boxes being edited do not move). While the watcher runs
nothing reads the disk on a timer; without one (a platform without a watcher, or a profile of its own: `--profile`, a temporary
profile, `WREN_DESKTOP_INTEGRATION=off`) `browser.desktop_integration.status_refresh_ms` is the period. Coming back to the
window reads the box's state at once.

## Command line

`wren --desktop-integration=install|remove|status|uninstall`, without a window. Exit codes: install and remove 0 done /
1 failed; status 0 installed / 1 absent / 2 to repair / 3 unreadable. The program is a Windows GUI program: to get the
exit code, run it with `Start-Process -Wait -PassThru` (or `start /wait`); its output goes to a redirected standard
output, else to the parent's console. It applies the preferences below (what the last Setup chose).

`wren --uninstall [--purge]` is the shorthand for `--desktop-integration=uninstall`: it removes the whole installed copy
silently — the integration (shortcuts, the browser registration), the PATH entry, the Settings > Apps record and the
files Setup placed — and keeps the user's profile unless `--purge` is given (which also deletes the profile: preferences,
history, cookies, session, crash reports, licence). Exit codes: 0 done, 1 failed, 5 done but some files are in use and are
removed when the running copy closes (the one being uninstalled is the one running). `remove` takes away only the
integration; `uninstall` takes away the installed copy. `--install` is the shorthand for `--desktop-integration=install`.

## Links that open in Wren

A web page cannot link to `about:wren` (browsers block `about:` links), and an `https:` link opens in the user's default
browser. A link whose scheme is one of Wren's opens in Wren: the address is the link without its `wren-` prefix.

| Link | Opens |
|---|---|
| `wren-https://example.org/a?b#c` | `https://example.org/a?b#c` |
| `wren-http://...` | the same in `http:` |
| `wren-about:wren` | `about:wren` |

The system runs `wren.exe --open-url <link>` (Linux: the desktop entry's `%U`, a link among the addresses); the address
opens as a new tab of the Wren that runs on the profile ([one Wren per profile](#one-wren-per-profile)), else Wren starts
with it. The browser that had the link asks "Open Wren?" first; Wren asks nothing more.

A link comes from any page, so `src/desktop/links.odin` lets out only what it is meant for: the prefix taken away, the
rest is parsed by Wren's URL parser and must be an `http` or `https` address with a host, or exactly `about:wren`.
Refused, and nothing opens (exit code 2, the reason on the console): any other scheme (`wren-file:`, `wren-javascript:`,
`wren-data:`, `wren-blob:`), a control character, a link longer than 8 KiB (`LINK_MAX_BYTES`), and `--open-url`
anywhere but as the one but last argument or more than once (a quote in a link the system did not encode could only add
arguments after it). The tab has no referrer and nothing of the page that had the link; the link never goes through a
shell. A development build opens its own `wren-dev-` links and the release's `wren-` ones.

Where Wren is not installed the link does nothing (the browser says it cannot open it): a page shows the address beside
it ("or open `about:wren` in Wren") and never tries to find out with a script.

## Preferences

`browser.desktop_integration.on_first_run`, `.status_refresh_ms`, `.start_menu`, `.desktop_shortcut`, `.add_to_path`,
`.register_browser` (also register as a browser, or only the menu entry), `.file_types`, `browser.update.check_daily`,
`browser.update.url`.

## Tests

The toolkit's `odin test src/desktop` runs the backends and the installed copy on scratch folders and a scratch registry
key, with an identity of its own. `odin test src/desktop` here checks Wren's identity: the `.desktop` text an installed
Wren has, both channels, and NixOS's libraries against `flake.nix`. `odin test src/browser` has the
states of the dialog and install -> every state -> uninstall on scratch roots. A run can be pointed at scratch roots by the
environment too: `WREN_DESKTOP_MENU_DIR`, `WREN_DESKTOP_DESKTOP_DIR`, `WREN_DESKTOP_REGISTRY_ROOT`,
`WREN_DESKTOP_ENVIRONMENT_ROOT` (the key that stands for `HKCU\Environment`), `WREN_DESKTOP_INSTALL_DIR` (Windows),
`WREN_DESKTOP_APPLICATIONS_DIR`, `WREN_DESKTOP_ICONS_DIR`, `WREN_DESKTOP_BIN_DIR` (Linux, the link of the Path part). `src\tools\e2e\setup.odin` drives the real dialog of a built
`wren.exe` on such a scratch desktop, through Wren's own input (install with Enter, uninstall of the running copy and its deferred deletion, standalone,
the automatic opening and its exceptions, a portable copy) and compares the real Start menu, PATH, StartMenuInternet and
Settings > Apps before and after. The toolkit's one test that touches the real desktop runs only with
`TK_TEST_DESKTOP_REAL=1` and uses an identity of its own.

# One Wren per profile

`src/instance`, `src/browser/instance_shell.odin`. The first Wren of a channel and a profile owns it (a named mutex
`Local\WrenInstance.Wren.<channel>.<hash of the profile folder>` and a message-only window titled with that key); a second
start hands its addresses (`wren.exe <address or path>...`: paths become `file:` addresses by the command line's rules),
`--setup` and the request to come forward to it with `WM_COPYDATA` (a link, `--open-url wren-https://...`, is its address by then), after `AllowSetForegroundWindow`, and ends with exit code
0 before it has a window (about 30 ms). The first opens a tab per address, restores its window if minimized and takes the
foreground. Nothing is done per frame.

| Case | What happens |
|---|---|
| another profile, another channel | independent: each has its own key |
| another executable on the same profile (a newer download) | it answers "another copy": that one opens its own window (Setup can replace the installed copy while it runs) |
| the first one has no window yet (starting) or refuses (closing) | the second start tries again for up to 3 s; once the mutex is free it becomes the owner |
| the first one does not answer (busy, hung) | after 3 s the second start opens its own window and says so (a notice, a line in the console) |
| `--new-window`, `--no-single-instance` | a window of its own, once |
| `browser.single_instance` off, `WREN_SINGLE_INSTANCE=off` | never (`=on` forces it, for the script that checks it) |
| `browser.profile.persist` off | never: its folder is the user's, shared with a Wren that keeps it |

`src/e2e` sets `WREN_SINGLE_INSTANCE=off` for every test that starts the browser, so none can hand its address
to the user's Wren and end. `src\tools\e2e\instance.odin` checks the table on real processes and scratch profiles (hidden windows, `WREN_SINGLE_INSTANCE=on`: a driven Wren is its own otherwise);
`wrentool bench startup` measures the cost of a start (one `CreateMutexW`: no measurable difference of the first present).