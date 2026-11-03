type: Fixed

**Form keywords are matched ASCII case-insensitively**: an input's or a button's `type`, a form's `method` and `enctype` written with a non-ASCII letter that lowercases to an ASCII one (the Kelvin sign U+212A for `k`) are no longer taken for the keyword (`type="checKbox"` made a checkbox).
