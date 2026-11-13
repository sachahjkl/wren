type: Changed

**Pages and the interface scroll with the same settings**: smooth scrolling is `scrolling.smooth` (follow the system, on, off), a wheel notch's glide is `scrolling.duration`, its curve `scrolling.curve`, and middle-button scrolling is `scrolling.autoscroll.*`, on pages, in about: pages and in the developer tools alike (they were `browser.scroll.smooth.enabled`, `curve`, `impulse`, `wheel_ms`, `reduced_motion` and `browser.scroll.autoscroll.*`; the `mode` of autoscroll is now `scrolling.autoscroll.toggle`). The scroll bars' hiding is `scrolling.autohide_scrollbars`.
