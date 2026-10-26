type: Fixed

**Images appear sooner** (toolkit 0.26.0): a new image texture is no longer zeroed one row at a time (551 driver calls and 1 to 4 ms for a photo), opaque images (every JPEG, most PNG, WebP and AVIF) are uploaded from the decoder's buffer with no conversion pass, and translucent ones are premultiplied a word at a time.
