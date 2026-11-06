type: Changed

**Heavy pages load faster**: the JavaScript interpreter's hot loop keeps its registers (it calls nothing now) and a value is copied in two words instead of field by field: simple instructions 15 to 30 % fewer; an object literal no longer searches every first key the page ever used (58 000 -> 1 700 instructions beside 3 000 of them); `slice`, `concat`, `map`, `filter`, `forEach`, spreads, `new Promise`, generators and async functions take a short way (up to three times faster).
