type: Added

**Idle service workers stop**: after `service_workers.idle_ms` (30 s) without an event, the worker's thread and realm go; the next event starts it again.
