type: Fixed

**Writing a stylesheet rule's `style` restyles the page**: `sheet.cssRules[i].style.setProperty(...)`, a property set on it, `removeProperty` and `cssText` change the rule in the sheet, as JSS's dynamic values (Material UI v4's `makeStyles` with props) and theme switchers do; the rule's `cssText` reads back what was written. Rules inside `@media` and other blocks are not changed yet.
