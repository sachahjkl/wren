type: Added

**A label for builds that are not the release** (`set WREN_VERSION_LABEL=experimental-2026-10-24` before `build.bat`): the version the user is shown becomes `0.3.0-experimental-2026-10-24` (about:wren, the menu, the status bar, the DevTools' HAR, Setup, the file's ProductVersion, the name of the packaged file). `APP_VERSION` stays the plain number: Setup, the update check and the User-Agent keep comparing and sending `0.3.0`.
