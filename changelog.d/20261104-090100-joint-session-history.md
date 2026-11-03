type: Fixed

**Back and forward through frames**: the back button after following a link inside a frame takes the frame back and leaves the page where it is, as other browsers do; `history.length`, `history.back()` and `history.go()` in a page count and move through its frames' navigations too, and `navigation.back()` / `traverseTo()` in a frame move the page with it when they have to (HTML's joint session history).
