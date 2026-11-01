type: Fixed

**`MediaSource` kept alive by its object URL and its element**: a page that made a `MediaSource` in a function and set `video.src = URL.createObjectURL(mediaSource)` lost `sourceopen` when a collection came first, and the video never started; the URL and the element now hold it, whatever the script keeps.
