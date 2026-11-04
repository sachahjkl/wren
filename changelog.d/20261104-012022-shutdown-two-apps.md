type: Fixed

**Two browsers of one process closing at once**: the second joined the shutdown watchdog the first had already freed (a crash at exit, seen when both ended together); the teardowns under way are counted, the last one stops the watchdog.
