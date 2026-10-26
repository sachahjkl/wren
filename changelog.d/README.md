# changelog.d

One file per change, assembled into `CHANGELOG.md` when a version is published. A branch adds its fragment here and
never edits `CHANGELOG.md` (nor `APP_VERSION`): two branches never conflict on them.

A fragment is `changelog.d/<yyyyMMdd-HHmmss>-<subject>.md` (subject: lowercase letters, digits and `-`):

```
type: Added

**Tabs in a sidebar** (`browser.tabs.position`): what it does, in one entry (no leading "- ").
```

- `type` is `Added`, `Changed`, `Fixed` or `Removed`: it picks the subsection.
- The text is one entry of the list, as it will read there. It may span lines; sub-items are indented `  - ` lines;
  no blank line, no heading.
- One change, one fragment. Two fragments may share a subject (the time keeps them apart). A change of the toolkit
  names what it uses (`ui.rich_paragraph`), not a toolkit version: the toolkit's version is written when it is published.

`powershell -File tools\changelog.ps1 -New -Type Added -Subject tab-sidebar -Text "**...**: ..."` writes one (or write
the file with an editor); `-Check` (CI, `test_all`) says whether they are all well formed and none was already
released; `-Assemble` prints what the next version brings (the notes of `tools\experimental.ps1` come from it).
`tools\changelog.ps1 -Assemble -Version X.Y.Z` makes the version's section, writes `APP_VERSION` and deletes them
(CONTRIBUTING.md, "Making a release").
