# A person's keys

The keymap is the toolkit's (`ext/gui_toolkit/src/md/features/keymap.md`): `ui.Keymap`, the palette's recorder
(Ctrl+Enter) and aliases (Alt+Enter), the two settings `keys.custom` and `keys.aliases`. Wren only connects it.

- **The keymap lives in the command registry** (`Command_Registry.keymap`). Every window's `ui.State` points to it
  (`ui.keymap_use` in `standard_settings_watch`), and `standard_watch` reads and writes the two settings. It is freed
  with the registry, so no teardown path needs a second call.
- **The ids are known when the registry is built** (`commands_ready` calls `ui.keymap_known`), before the first key is
  read. A person's key then takes its chord from the first frame.
- **A generated id is ASCII** (`command_id_part`): "Rosé Pine" gives `view.theme.rose_pine`. An id with `é` failed
  `ui.command_ids_check`, and no key could be set for it.
- **Ctrl+Enter on a command is the toolkit's.** It opened a page command's page in a new tab before. That act is now
  the command `tab.open_page`, whose one argument is chosen from the pages the commands open (`Command.url`). Refused:
  one "in a new tab" twin per page command, which doubles a dozen lines of the palette, each label untranslatable.
  Refused: listing the built-in pages in the `/` source, where a plain search shows each page twice, as a command and
  as a page.
