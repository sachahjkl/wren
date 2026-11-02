type: Fixed

**Each frame keeps its own built-ins.** `frame.contentWindow.Array`, `Object`, `Promise`, `Error` and the other ECMAScript built-ins are the frame's, no longer the reader's: `w.Array !== Array`, `new w.Object` is an object of the frame, an array of another frame is not `instanceof Array` (`Array.isArray` still says true), and what a frame throws is a `w.TypeError`. A listener of another frame that cannot be called fails with a `TypeError` of that frame, reported there (`dom/events/EventListener-handleEvent-cross-realm.html`).
