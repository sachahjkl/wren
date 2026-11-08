type: Fixed

**XMLHttpRequest reads the body as it arrives**: the request is LOADING with readystatechange and progress events (the first part at once, then at most every 50 ms), and responseText has what came. The body was seen only at its end, so video.js, which reads the first bytes of a whole video to know its container and then aborts, waited for a video that never ended: an Invidious video never played. The callback API of module net tells a guest of each part of the body (FetchState.Body).
