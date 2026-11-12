type: Added

**Vault: idle lock and periodic sync**: the Vault locks after `vault.lock.idle_minutes` (15 by default) without a key press or a pointer move in the browser, and its helper exits; the helper also locks itself when the browser stops sending it signs of activity. While unlocked, the Vault syncs every `vault.sync.interval_minutes` (30 by default), and the panel has a Sync button.
