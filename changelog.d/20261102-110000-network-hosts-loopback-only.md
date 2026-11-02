type: Added

**Names resolved by the browser itself, and connections kept on this machine** (built-in network stack): `network.hosts` (`name=address` pairs; a name stands for its subdomains too) answers those names without asking the system or a hosts file, and `network.loopback_only` (or `WREN_NETWORK_LOOPBACK_ONLY=1`) makes any connection to an address that is not this machine's fail at once, named on the standard error. The tests run with both: web-platform-tests under its own names (`web-platform.test`, `www1.web-platform.test`...), and nothing tested reaches the Internet.
