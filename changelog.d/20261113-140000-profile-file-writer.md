type: Fixed

**Profile files survive a crash and a slow disk**: the service worker registrations and scripts, the notification decisions, the storage buckets, the update check, the Setup answer, the search engines, the blocker's configuration and the Vault's account are written off the interface thread and atomically, so a crash during a write no longer leaves a file cut short. A failed write is tried again later and Wren tells you once.
