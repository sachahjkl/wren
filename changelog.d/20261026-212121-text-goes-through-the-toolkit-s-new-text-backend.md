type: Changed

Text goes through the toolkit's new text backend interface (toolkit 0.37.0): DirectWrite is one backend among others, with the same result (pages captured before and after are identical); the `text.backend` preference (`default`, `dwrite`, `native`, at restart) picks the shaper of a build that has the native one.
