type: Changed

**2D canvas and Web Animations glue in Odin** (`native/js/odin/web_canvas.odin`, `web_animations.odin`, `api_decl/canvas.odin`, `api_decl/animations.odin`): getContext, the encoders, styles, paths, ImageData, drawImage, createImageBitmap, KeyframeEffect, Animation, the timelines and the animation events leave the C glue; every host call is declared and bound through `jsb`, the keyframes are packed without a malloc per member name.
