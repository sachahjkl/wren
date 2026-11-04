type: Fixed

**Workers: errors of scripts of other origins stay hidden**: what a script that `importScripts()` takes from another origin without CORS throws (a syntax error too) reaches the worker as a `NetworkError`, as in the other browsers, and an uncaught `DOMException` reports where it was thrown. `fetch()` with an `integrity` hash refuses an opaque response.
