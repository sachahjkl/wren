type: Changed

**What pages are told about touch follows the hardware** (`browser.touch.expose` = `auto` | `on` | `off`, was `javascript.touch_events`): `navigator.maxTouchPoints` (from the toolkit's `input_devices`), `ontouchstart` and the `Touch`, `TouchEvent`, `TouchList` constructors only with a touch screen, and `pointer` / `any-pointer` / `hover` / `any-hover` media queries matching the devices.
