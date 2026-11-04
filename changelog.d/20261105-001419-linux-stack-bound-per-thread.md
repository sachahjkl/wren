type: Fixed

**Linux: pages that froze the browser for minutes** (vimeo.com, css-tricks.com; everything script-heavy was slower): each call into the script engine asked glibc where the thread's stack ends, which on the main thread reads `/proc/self/maps`. Asked once per thread now.
