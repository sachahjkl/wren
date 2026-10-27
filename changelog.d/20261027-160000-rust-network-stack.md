type: Added

**A built-in network stack in Rust, now the default** (`network.backend` = `rust`; `winhttp` stays selectable, and the `WREN_NET_BACKEND` environment variable overrides both) under the same `net` API: HTTP/1.1 and HTTP/2 (hyper), HTTP/3 (quinn + h3) raced against TCP, WebSockets (tungstenite), TLS 1.2 and 1.3 (rustls) checked against the system's trust store (a company's authorities included), the system resolver and proxy settings, gzip, deflate and Brotli bodies. A machine whose proxy is set by a script (PAC) keeps WinHTTP.
  - HTTP/3 is on again by default (`network.http3.enabled`): a site that announces it gets `network.http3.race_ms` (250 ms) for its QUIC connection before the request goes over TCP, and a site where QUIC fails is left to TCP for `network.http3.broken_host_ms`; the WinHTTP stack never uses HTTP/3 (it never fell back to TCP: odin-lang.org stayed on Connecting).
  - New preferences: `network.http3.race_ms`, `network.http3.broken_host_ms`, `network.tls.extra_ca_file`, `network.threads`, `network.pool.idle_timeout_ms`, `network.pool.max_idle_per_host`.
  - A body cut short (its Content-Length not reached) now fails (WinHTTP took it for a complete one).
  - `tools\net_parity.ps1` runs the network end-to-end tools on one backend; `nettest` checks the transport on both.
