type: Security

**A compressed response can no longer exhaust memory**: gzip, deflate and Brotli bodies are decoded 64 KiB at a time, and each step goes to the page before the next is decoded. A response that expands to far more than its size stops at the body limit, with at most one step in memory. Brotli streams that ask for a window larger than the standard's 16 MiB are refused.
