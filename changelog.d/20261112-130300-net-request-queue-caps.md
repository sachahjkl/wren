type: Changed

**A page cannot queue requests or WebSocket data without end**: past `network.queue.max_waiting_per_page` (2000) requests of one page, or `network.queue.max_waiting` (10000) in total, waiting for a connection, a new request fails at once. A WebSocket with more than `network.websocket.max_buffered_bytes` (64 MiB) waiting to be sent is closed with code 1009.
