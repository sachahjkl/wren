type: Changed

**WPT runner: windows with a history, a second http port**: the windows a test opens keep a session history across their documents and follow `history.back()`, `history.go()` and `navigation.traverseTo()` between them, and the test server answers wptserve's second http port (`{{ports[http][1]}}`), so tests of another origin on another port run instead of timing out.
