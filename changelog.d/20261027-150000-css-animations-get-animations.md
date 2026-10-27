type: Added

**CSS animations and transitions in `getAnimations()`** (`CSSAnimation`, `CSSTransition`, `style.timeline_css_animations`): `element.getAnimations()` and `document.getAnimations()` list them (transitions, then animations, then the scripts' ones) with `animationName` / `transitionProperty`, their `effect` (target, timing), `playState`, `currentTime` and `startTime`; `pause()`, `play()`, `cancel()`, `finish()` and setting `currentTime` act on the running animation.
