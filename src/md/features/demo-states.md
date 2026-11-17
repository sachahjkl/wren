# Demo states

## Purpose

Some screens of Wren exist only after an account action: the Vault unlocked with its items, its unlock dialog, a
licence registered. A tool that takes pictures of Wren (the README's, the site's, a review's) cannot reach them with
clicks: it would need a real account, a real master password and a real licence key. So Wren names these screens, and
a tool enters one before it takes its picture. No code changes for the time of a capture.

## The endpoint

The states are entered over the toolkit's interface endpoint (`ext/gui_toolkit/docs/devtools.md`, `Toolkit.demoState`),
which Wren starts as the other programs do (`src/browser/ui_cdp.odin`):

- It runs only when `TOOLKIT_DEVTOOLS=<port>` is in the environment of a build that has it (`-debug`: dev, quick,
  debug, check). A release has none of it. A person never sees it, so it has no changelog entry.
- It serves the first window. If that window closes, the endpoint ends with it: it does not move to another window,
  because a tool's connection names one window.
- It is not Wren's CDP for the pages (`--remote-debugging-port`, `cdp.odin`) nor the remote control of `wren ctl` (a
  pipe). If it gets the same port as `--remote-debugging-port`, it starts second, finds the port taken and stays off.
- Wren makes no frame for a wake that brings no cause (`windows_pass`). The endpoint only wakes the window, so while it
  waits for builds (a `waitFor`, a picture, a click's release), Wren asks for frames itself (`ui_cdp_frame`).

## The states

`src/browser/demo_states.odin`:

| Name | What it shows |
|---|---|
| `vault.unlocked` | The Vault unlocked with made-up items: three logins (two for `example.org`), a card, an identity. The panel, the palette's Vault source and the fill menu list them. |
| `vault.locked` | The Vault locked on a made-up account, its unlock dialog open on the master password. |
| `vault.pin` | The same dialog, on the account's PIN. |
| `vault.pin_set` | The Vault unlocked, the dialog that sets a PIN open. |
| `licence.registered` | A made-up licence registered, the settings open on their Licence page in a new tab. |

A state sets the data and opens what an account action opens. Other moves stay with the tool: the tool opens the panel
(`Toolkit.click` on the box `vault_icon`) and loads a page of `example.org` for its logins. `wrentool shots` takes two
of these pictures (`vault`, `vault-unlock-pin`): it starts Wren with `TOOLKIT_DEVTOOLS` and enters the state over the
toolkit's client (`toolkit:cdp`).

## The rule: memory only

A state changes memory only. It never writes the person's files (the vault, the preferences, the licence file) and
never calls a server or the Vault helper. The toolkit cannot check this, so each state keeps the rule as follows:

- **The Vault** (`src/vault/demo.odin`). `vault_demo` puts the Vault in demo. After that:
  - the Vault starts no helper (`ensure_helper`), locates and downloads none (`enable`), and writes no file
    (`file_job`);
  - its rows and searches come from the made-up items, filtered by Wren's own match rules (`row_matches`), and the
    helper is not asked.

  So the demo also holds for the clicks that follow it. A Lock, a Log out, a PIN or a Sync changes memory only or does
  nothing. A copy or a fill does nothing: there is no helper to give a value. The demo lasts until the browser ends.
  To leave it, the Vault would need a state to go back to, and the demo never kept one. An instance that a tool drives
  is closed after the capture anyway.
- **The licence.** The state sets `prefs_page.Licence`'s status as a read of the store would set it. The status is
  allocated with the allocator that the Licence frees it with. The store and its file are not touched. If a task on the
  store is still running (the first read, at the start), the state does nothing, because the task's answer would replace
  the status. The tool enters the state again later. A click on "Remove the licence" after the demo acts on the real
  store, as a person's click does: a tool does not click it.

## Remote control

The Vault shows nothing while a remote client drives Wren (`vault_usable`). Captures that go through the remote
channel (`wrentool shots`) therefore start Wren with `vault.test.remote=true`. The pictures then show the Vault's
surfaces, which hold only the made-up items.

## Refused

- **Temporary code for a capture** (a flag in the source, an account made for the pictures, a build of its own). It
  is forgotten in a commit or shipped. It also makes the picture differ from what the code does, and a real account
  shows real names and sites.
- **A fake helper process that answers the protocol.** It would show the same screens and keep the helper's code
  path. But it is a second program to build and ship with the tools, and it needs a server's state that it would have
  to invent too. The Vault's own demo is about 80 lines and touches no process.
- **Leaving the demo on a lock.** The Locked state of the demo is itself a screen (`vault.locked`). A lock that gave
  back the person's real state would need that state to be kept in memory beside the demo's.
