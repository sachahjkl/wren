type: Added

**A built-in network stack in Rust** (`network.backend` = `rust`, or the `WREN_NET_BACKEND` environment variable) under the same `net` API as WinHTTP: HTTP/1.1 and HTTP/2 (hyper), HTTP/3 (quinn + h3) raced against TCP, WebSockets (tungstenite), TLS 1.2 and 1.3 (rustls) checked against the system's trust store (CA of a company included), the system resolver and proxy settings, gzip, deflate and Brotli bodies. WinHTTP stays the default until the parity is proven.
  - New preferences: `network.http3.race_ms`, `network.http3.broken_host_ms`, `network.tls.extra_ca_file`, `network.threads`, `network.pool.idle_timeout_ms`, `network.pool.max_idle_per_host`.
  - `tools\net_parity.ps1` runs the network end-to-end tools on one backend.
