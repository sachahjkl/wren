type: Fixed

**A link clicked by a script is followed** (`forms.Host.follow_link`, `page.navigation_follow_script_link`): `a.click()` and `area.click()` navigate the document (after the `navigate` event), as a link the user clicks does; links with `download` or a `target` other than `_self` are still left alone.
