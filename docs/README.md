# Writing documentation

Every page of the documentation site is a Markdown file under `docs/`. The generator `src/tools/docsite` turns them
into the static site under `site/docs/`. There is no framework and nothing is fetched at runtime; the pages render in
Wren itself. The pages, their sidebar, search, Markdown, highlighter and link check are the toolkit's site package
(`ext/gui_toolkit/src/site`, documented in `ext/gui_toolkit/docs/site.md`); `src/tools/docsite` gives it Wren's names,
header, footer, colours, the WIDL language and the directives below, and makes the classic presentation.

The site has a second, classic presentation under `site/classic/` (plain links, one column of text, light and dark;
`site/classic/classic.css`), reached by "Classic version" in every footer and back by "Modern version". The same tool
makes it from the same sources: each doc is rendered a second time in the classic frame, and each hand-written page of
the site (`site/<page>/index.html`) gives its `<main>` and its scripts, its links moved into the classic tree. Only the
classic home, `site/classic/index.html`, is written by hand; its top, footer, version and release news are stamped
between markers. So edit the modern page or the `.md`, never a generated classic page, and run `wrentool docs`.

## The workflow

1. Write or edit a `.md` file under `docs/`.
2. If the page is new, add it to `docs/_nav.txt` so it appears in the sidebar where you want it. A page you forget is
   still generated and linked (it lands in a "More" section), so nothing is lost, but the order and the section are up
   to you.
3. Run `wrentool docs`. It regenerates `site/docs/` and `site/classic/` and checks that every internal link and anchor
   resolves.
4. Commit the `.md` **and** the regenerated `site/docs/` and `site/classic/`. The generation is deterministic (same
   input, same bytes), and CI fails if either is out of date — the same rule as `wrentool changelog -Check`.

## The sidebar: `docs/_nav.txt`

The file lists the sections and the pages in each, in the order they appear. Its own header documents the format. In
short:

```
Section Title
  page.md            a page whose label is its first heading
  page.md  Label     a page with an explicit sidebar label
  dir/*    Label      every .md of a directory, as a sub-group (an _index.md or README.md leads it)
```

## The Markdown it understands

The generator implements the slice of CommonMark and GitHub-flavored Markdown the docs use:

- **Headings** `#` to `######`. The first `# ` heading is the page title. Each heading gets a stable `#anchor`.
- **Paragraphs**, **bold** (`**x**`), *italic* (`*x*` or `_x_`), `inline code`, and hard breaks (two trailing spaces).
- **Lists**, bullet (`-`, `*`, `+`) and ordered (`1.`), nested by indentation.
- **Links** `[text](url)`. A relative link to another doc — `remote.md`, `api/dom.md`, `../README.md` — is rewritten
  to the site's URL automatically. A link that leaves `docs/` becomes a GitHub link. Keep writing links as `.md`
  paths; do not hand-write `.html`.
- **Images** `![alt](src)`. Put image files under `docs/` and reference them relatively.
- **Blockquotes** `>` and **thematic breaks** (`---`).
- **Tables**, GitHub style, with `:---:` alignment. A `|` inside a code span does not split a cell.
- **Fenced code blocks** with a language for syntax highlighting:

      ```odin
      main :: proc() { }
      ```

  The highlighter knows `odin`, `c`, `js` / `javascript`, `powershell`, `json`, `rust` and `widl`. Colouring happens
  at generation time; there is no client-side highlighter.

A bare `<!-- comment -->` and a few inline tags (`<sub>`, `<a>`, …) pass through. Anything the generator does not
understand is shown as escaped text rather than failing, so a mistake is visible on the page.

## Generated directives

The conformance page uses two directives the generator fills from data:

- `<!-- docsite:chart -->` — the WPT pass-rate chart, an inline SVG built from the git history of `wpt/expectations`.
- `<!-- docsite:wpt-table -->` — the pass rate by folder, read from `wpt/expectations`.

You rarely need these; they belong to `docs/conformance.md`.

## Rules of thumb

- **One `# ` heading per page**, at the top. The site, the search index and the breadcrumbs use it as the title.
- **Link to other docs by their `.md` path.** Never write a site `.html` URL by hand.
- **Keep headings in order** (don't jump from `#` to `###`): the table of contents and screen readers follow the
  levels.
- The site has a dark and a light theme (it follows the operating system). Do not assume a background colour in any
  inline HTML you add.
