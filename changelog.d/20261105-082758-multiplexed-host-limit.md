type: Changed

**A host that answers over HTTP/2 or HTTP/3 takes its requests at once**: six at a time was the limit of HTTP/1.1 connections, applied to the streams of one connection too (`network.max_streams_per_host`, 100; `network.max_connections_total` is now 256). github.com's issues waited 2.4 s in the queue at most, now 0.25 s.
