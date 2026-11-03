type: Fixed

**A `<select>` picks its option again only when something asks for it** (an option inserted or removed, a `selected`, `multiple` or `size` attribute, `option.selected`, a form reset): `selectedIndex = -1` on a drop-down stays until then, where every read selected its first option again.
