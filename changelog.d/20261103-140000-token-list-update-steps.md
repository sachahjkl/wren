type: Fixed

**`classList.add()` and `remove()` without a token, `replace()` with an empty one**: `add()` and `remove()` with no argument still write the attribute back in its serialized form (`"a b c a "` becomes `"a b c"`), as the DOM's update steps say, and `replace()` with an empty token throws a `SyntaxError` before looking for whitespace in the other.