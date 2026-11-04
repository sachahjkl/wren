type: Changed

**Pages load without waiting for frames**: what arrives while a frame waits for its moment on the screen (a document, a stylesheet, a script's answer) runs at once instead of after the wait, and a page's first picture is drawn as soon as it can be, without waiting for the screen's next slot: a page of 10 000 elements is ready at 21 ms instead of 33 and first painted at 44 ms instead of 57, a page with an imported stylesheet first painted at 26 ms instead of 42. Frame pacing and the browser at rest are unchanged. The numbers: `docs/performance.md`.
