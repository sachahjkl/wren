type: Security

**Scripts can no longer exhaust memory through the DOM or timers.** A document holds at most `javascript.dom.max_nodes` nodes and `javascript.dom.max_bytes` bytes of text and attributes, and one event target holds at most `javascript.dom.max_listeners_per_target` listeners. Past these limits, the operation fails with QuotaExceededError. A page has at most `timers.max_timers` pending setTimeout and setInterval timers.
