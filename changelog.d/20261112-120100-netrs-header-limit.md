type: Security

**One limit for the size of response headers**: a response head larger than 256 KiB fails the request, the same over HTTP/1.1, HTTP/2, HTTP/3 and WebSocket handshakes. Before, HTTP/3 accepted headers of any size, and HTTP/2 refused heads larger than 16 KiB (some sites with many cookies failed to load).
