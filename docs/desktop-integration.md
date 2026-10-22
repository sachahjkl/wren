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

## First run, updates, command line

- **First run.** A release build integrates itself once per profile (`browser.desktop_integration.on_first_run`). A mark
  file (`desktop_integration.txt`) in the profile records it: removing the integration later does not bring it back.
  Development builds, profiles given with `--profile`, profiles in the temporary folder and runs with
  `WREN_DESKTOP_INTEGRATION=off` never do. `tools\test_env.ps1` sets that variable for every test and tool script.
- **Moved or updated.** At start-up an existing integration that runs another copy of the same channel is not changed in
  silence: a line under the address bar offers *Update*, *Not now*, *Don't ask again* (`...offer_update`).
- **Command line.** `wren --desktop-integration=install|remove|status`, without a window. Exit codes: install and remove
  0 done / 1 failed; status 0 installed / 1 absent / 2 to repair / 3 unreadable. The program is a Windows GUI program: to
  get the exit code, run it with `Start-Process -Wait -PassThru` (or `start /wait`); its output goes to a redirected
  standard output, else to the parent's console.

## Preferences

`browser.desktop_integration.on_first_run`, `.offer_update`, `.status_refresh_ms`, `.register_browser` (also register as
a browser, or only the menu entry), `.file_types`.

## Tests

`odin test src/desktop` runs the backend on a scratch Start menu folder and a scratch registry key
(`HKCU\Software\WrenTest\<id>`, deleted afterwards), and, on Linux, on scratch directories: round trip, to repair,
removal leaving other programs' files. The environment can point a run at scratch roots too: `WREN_DESKTOP_MENU_DIR`,
`WREN_DESKTOP_REGISTRY_ROOT` (Windows), `WREN_DESKTOP_APPLICATIONS_DIR`, `WREN_DESKTOP_ICONS_DIR` (Linux). The one test
that touches the real desktop runs only with `WREN_TEST_DESKTOP_REAL=1` and uses an identity of its own.
