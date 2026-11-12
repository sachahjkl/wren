type: Security

**Long URLs no longer escape the content blocker**: the filters are matched against the whole URL. Before, only its first 8 KiB, its first 96 words and its first 2048 positions were looked at, so a filter that matched further on never blocked.
