# Roadmap

## Now

## Next

- **One page embedding, the browser without its shell.** A page's embedding is built in 5 places and the navigation algorithm exists twice: one `embed` package holds both ([docs/organisation-review.md](docs/organisation-review.md), section 1).
- **`src/browser` cut into packages.** It is one package of 235 files, its App has about 170 fields and `the_app` is used 1092 times: 8 packages, the leaves first (section 2).
- **Preferences read one way.** They are read 3 ways today: one settings struct and one watch per group (section 4).
- **A frame asked for with its cause.** 317 calls ask for frames with a number from 0 to 4: each asks with a cause and a condition instead (section 5).
- **The toolkit's systems used, Wren's shared ones moved into it.** Wren keeps copies of toolkit systems and systems that the toolkit must carry: use its packages, and move 6 systems into it (section 6). The settings' standard pages, Setup and the updater are the toolkit's now ([src/md/features/settings-pages.md](src/md/features/settings-pages.md)).

## Later

- **One table of the programs, one file of versions.** 25 programs live beside wrentool, and their versions are pinned in 8 places (section 9).
- **The rules of shared memory written and checked.** The rules are not written, and the lint of globals covers 6 packages of 40: write them, extend the lint (section 10).
- **`src/page` split by subject.** It mixes six subjects (section 11).
- **Dialogs and prompts made one way.** Section 12 of the review.
- **Names and terms made consistent.** Section 13 of the review.
- **Documents matched to the code.** Section 14 of the review.
