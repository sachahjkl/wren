package browser

// Units the shell converts between in many places: one name for each, so that a conversion reads as what it is.

MS_PER_SECOND :: 1000
MS_PER_MINUTE :: 60_000
NS_PER_MS :: 1_000_000
SECONDS_PER_MINUTE :: 60
SECONDS_PER_HOUR :: 3600
SECONDS_PER_DAY :: 86400
MINUTES_PER_HOUR :: 60
BYTES_PER_MB_DECIMAL :: 1_000_000
BYTES_PER_KB_DECIMAL :: 1000
BYTES_PER_KIB :: 1024
BYTES_PER_MIB :: 1024 * 1024

// The longest line a preview of the developer tools shows of a text response.
DEVTOOLS_PREVIEW_LINE_MAX :: 2000
// An outline cache's size before the page's settings are there.
CANVAS_GLYPH_CACHE_FALLBACK :: 4096
// MCI (the system's media player of the developer tools): what its volume calls full, its positions per second.
MCI_VOLUME_FULL :: 1000
MCI_UNITS_PER_SECOND :: 1000
