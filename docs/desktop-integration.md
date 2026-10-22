# Desktop integration

Wren is one portable executable with no installer. The *desktop integration* is what makes it part of the user's
desktop anyway: a launcher in the application menu, its icon, and the registration as a program that can open web
addresses. It is added and removed by one switch, in the user's own profile, never system-wide and never with
administrator rights.

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
  its own icon, its folder as working directory (`policies.txt` is read from there), and the **AppUserModelID**
  `FromentSoftware.Wren` (`IPropertyStore`, `PKEY_AppUserModel_ID`). The program sets the same ID for its windows
  (`SetCurrentProcessExplicitAppUserModelID`, before the first window), so pinning the shortcut to the taskbar and
  grouping the windows under it work.
- Registration as a *candidate* browser. Windows does not let a program make itself the default browser: the user picks
  one in Settings > Apps > Default apps (the box has a button that opens that page).
  - `Software\Clients\StartMenuInternet\Wren` (name, icon, command, `Capabilities` with the URL associations `http` and
    `https` and the file associations of `browser.desktop_integration.file_types`)
  - `Software\RegisteredApplications`, value `Wren`
  - `Software\Classes\WrenHTML`, the ProgID, whose `shell\open\command` is `"<exe>" "%1"`
  - then `SHChangeNotify(SHCNE_ASSOCCHANGED)`.
- Development builds use `Wren Dev`, `WrenDev`, `FromentSoftware.Wren.Dev`: they never touch the release's entries.

Removal deletes the shortcut when it carries the AppUserModelID or runs the executable, the keys that hold the
`WrenIntegration` mark or run the executable, and the `RegisteredApplications` value that names Wren's Capabilities key.
Nothing else: the user's choices (`UserChoice`), other programs' keys, a `Wren.lnk` that is not Wren's all stay.

## Linux

- `$XDG_DATA_HOME/applications/wren.desktop` (`~/.local/share/applications` by default): `Type`, `Name`, `Exec` (quoted as
  the Desktop Entry Specification says, `%U`), `TryExec`, `Icon`, `Categories=Network;WebBrowser;`, `MimeType=` for
  `x-scheme-handler/http`, `x-scheme-handler/https` and the file types, and the marker `X-Wren-Integration=wren`.
  `update-desktop-database` runs afterwards when installed. The entry passes `desktop-file-validate`.
- `$XDG_DATA_HOME/icons/hicolor/<n>x<n>/apps/wren.png` for the sizes Wren embeds (16, 32, 64, 256, 512).

## macOS

Not provided: what macOS lists is an application bundle, and Wren is an executable outside any bundle. See
`src/desktop/integration_darwin.odin`.

## Parts, and what the options map to

The integration is a set of **parts**; `install` writes the ones the options ask for and takes away the ones they do not
(that is what *Modify* does); `remove` takes away every part that carries Wren's mark.

| Part | Option in Setup | Windows | Linux |
|---|---|---|---|
| Launcher | Add to Start menu | `Wren.lnk` in the Start menu | the `.desktop` file |
| Desktop shortcut | Create desktop shortcut | a second `.lnk` (same AppUserModelID) in the Desktop folder | not provided |
| Registration | Register as a web browser | the `StartMenuInternet` / ProgID keys above | `MimeType=` in the `.desktop` file |
| Path | Add Wren to PATH | the program's folder in `HKCU\Environment\Path` | not provided |
| Icons | - | - | the hicolor icons |

PATH: the value stays a `REG_EXPAND_SZ`, entries are compared after expanding `%VARIABLES%` (case, slash direction and a
trailing separator do not matter), the folder is never added twice, and open programs are told (`WM_SETTINGCHANGE`
"Environment"). The value `PathDir` under `Software\FromentSoftware\Wren` says which folder Wren added: an entry the user put
there by hand is never taken out (except the folder of a copy that is being uninstalled).

## Setup: the installed copy

`src/desktop/install.odin` (platform agnostic) and `src/browser/setup.odin`, `setup_ui.odin` (the dialog).

- **Where**: `%LOCALAPPDATA%\Programs\Wren\wren.exe` (`Wren Dev` for the development channel), or any folder that passes
  `check_install_dir`: an absolute path on a local drive, no forbidden character, not a drive root, not inside Windows,
  Program Files or ProgramData, not too long, and a file can be written in the nearest folder that exists (probe, nothing is
  created). On Linux: `$XDG_DATA_HOME/wren`.
- **What**: the executable and what `tools\package.ps1` puts beside it (`vcruntime140.dll`, `LICENSE.txt`, `THIRD_PARTY.md`,
  `README.txt`, `licenses\`, `demos\`, `examples\`, `testserver.exe`, `demo.bat`: `SETUP_PAYLOAD`; a name that is not there
  is skipped, so a development build installs just `wren.exe`), then the manifest `wren_install.txt` (version, channel,
  every file).
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
  copies, or with `WREN_DESKTOP_INTEGRATION=off` (`tools\test_env.ps1` sets it for every script).
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

## Command line

`wren --desktop-integration=install|remove|status`, without a window. Exit codes: install and remove 0 done / 1 failed;
status 0 installed / 1 absent / 2 to repair / 3 unreadable. The program is a Windows GUI program: to get the exit code, run
it with `Start-Process -Wait -PassThru` (or `start /wait`); its output goes to a redirected standard output, else to the
parent's console. It applies the preferences below (what the last Setup chose).

## Preferences

`browser.desktop_integration.on_first_run`, `.status_refresh_ms`, `.start_menu`, `.desktop_shortcut`, `.add_to_path`,
`.register_browser` (also register as a browser, or only the menu entry), `.file_types`, `browser.update.check_daily`,
`browser.update.url`.

## Tests

`odin test src/desktop` runs the backend and the installed copy on scratch folders and a scratch registry key
(`HKCU\Software\WrenTest\<id>`, deleted afterwards), and, on Linux, on scratch directories. `odin test src/browser` has the
states of the dialog and install -> every state -> uninstall on scratch roots. A run can be pointed at scratch roots by the
environment too: `WREN_DESKTOP_MENU_DIR`, `WREN_DESKTOP_DESKTOP_DIR`, `WREN_DESKTOP_REGISTRY_ROOT`,
`WREN_DESKTOP_ENVIRONMENT_ROOT` (the key that stands for `HKCU\Environment`), `WREN_DESKTOP_INSTALL_DIR` (Windows),
`WREN_DESKTOP_APPLICATIONS_DIR`, `WREN_DESKTOP_ICONS_DIR` (Linux). `tools\setup_e2e.ps1` drives the real dialog of a built
`wren.exe` on such a scratch desktop (install with Enter, uninstall of the running copy and its deferred deletion, standalone,
the automatic opening and its exceptions, a portable copy) and compares the real Start menu, PATH, StartMenuInternet and
Settings > Apps before and after. The one test that touches the real desktop runs only with `WREN_TEST_DESKTOP_REAL=1` and
uses an identity of its own.

# One Wren per profile

`src/instance`, `src/browser/instance_shell.odin`. The first Wren of a channel and a profile owns it (a named mutex
`Local\WrenInstance.Wren.<channel>.<hash of the profile folder>` and a message-only window titled with that key); a second
start hands its addresses (`wren.exe <address or path>...`: paths become `file:` addresses by the command line's rules),
`--setup` and the request to come forward to it with `WM_COPYDATA`, after `AllowSetForegroundWindow`, and ends with exit code
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

`tools\test_env.ps1` sets `WREN_SINGLE_INSTANCE=off` for every script that starts the browser, so none can hand its address
to the user's Wren and end. `tools\instance_e2e.ps1` checks the table on real processes and scratch profiles;
`tools\instance_startup.ps1` measures the cost of a start (one `CreateMutexW`: no measurable difference of the first present).