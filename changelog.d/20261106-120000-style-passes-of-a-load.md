type: Changed

**Pages that use `:has()` restyle far less while they load**: a change is read by the anchors it concerns, partial passes read classes as bits and answer `:has()` from what they know, restyles share out work by weight between the style threads, a script writing in a form control no longer restyles the document, `window.scrollY` at the top asks for no layout: cnn.com loads about 19 % sooner and paints first about 24 % sooner.
