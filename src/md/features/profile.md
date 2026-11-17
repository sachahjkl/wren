# The profile's folder

A profile is one folder: the settings, the history, the sessions, the Vault, the logs, the crash reports and the caches.
Without `--profile` and without a portable copy, it is the toolkit's configuration folder of `FromentSoftware/Wren`
(`platform.user_dir(.Config, APP_FOLDER)`): `%APPDATA%\FromentSoftware\Wren`, `~/.config/FromentSoftware/Wren`. The
toolkit's rule (`ext/gui_toolkit/src/md/features/folders.md`) puts every program of the vendor together, under the names
the person reads.

- **One procedure names the folder** (`default_profile_dir`). The browser and `wren ctl` both call it: the remote
  channel's name comes from the profile's path, so a client that computed another folder would not find the browser.
- **The old folder moves once.** Up to 0.8.0 the profile was `<config>/Wren`. At start, before anything reads the
  profile, `platform.user_dirs_move("Wren", APP_FOLDER, {.Config})` renames it. A person keeps their settings, their
  history and their Vault. If the new folder exists already, the old one stays: the move never writes over what is new.
- **Only `.Config` moves.** Wren keeps nothing in the data, state or cache folders: the profile holds them all.
  Refused: one folder per kind (cache in `.Cache`, logs in `.State`). A profile is the unit that `--profile`,
  a portable copy and a private window copy or throw away; split, each of them would need the whole list of kinds.
- **A failed move keeps the old folder.** If the rename fails (a file held open by another program), Wren runs on
  `<config>/Wren` this time and logs why; the next start tries again. Refused: starting on the new, empty folder, which
  would show a person an empty browser while their profile sits next to it.
