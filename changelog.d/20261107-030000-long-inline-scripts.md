type: Changed

**A page with a very long inline script loads sooner**: while such a script's compile finishes, the parser waits and the window thread goes on with what has arrived instead of standing still, and a container whose new size flips no `@container` rule no longer restyles everything under it (cnn.com's load event comes 18 % sooner).
