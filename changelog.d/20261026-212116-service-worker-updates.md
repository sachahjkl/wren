type: Added

**Service worker updates**: `registration.update()` and `register()` fetch the script (`Service-Worker: script`, the HTTP cache bypassed unless `updateViaCache: "all"`), the same bytes install nothing; a navigation in the scope checks it when the last check is older than `service_workers.update_check_hours` (24); `Service-Worker-Allowed` lets a script control a scope above its folder.
