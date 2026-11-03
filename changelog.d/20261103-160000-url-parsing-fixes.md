type: Fixed

**URLs parsed as the URL Standard says where Lexbor did not**: a host whose last label is digits past 2^32 then letters (`1.12345678901c`) is a domain, not a refused IPv4 address; a dot segment followed by a query or a fragment (`/a/b/%2e%2e?query`) keeps its `?` or `#`; `^` in a path is percent-encoded; the last space of an opaque path before a query or a fragment becomes `%20`; the pathname of a path that begins with an empty segment (`non-spec:/.//p`) no longer starts with `/.`.
