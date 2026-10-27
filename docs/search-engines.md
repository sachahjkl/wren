# Search engines

Words typed in the address bar that are not an address, and the context menu's *Search … for "…"*, go to a search
engine. The engines are a list the user edits; one of them is the default.

## Using them

| Where | What happens |
|---|---|
| Address bar, words that are not an address | searched with the default engine (`browser.search.engine`) |
| Address bar, a keyword first: `@g cats`, `k rust` | `cats` searched with the engine whose keyword is `@g` (letter case aside); the keyword wins over an address (`@w example.com` searches it) |
| Suggestions, the search row | reads *Search with &lt;engine&gt;*; **Ctrl+Down / Ctrl+Up** picks the next or previous engine for this time (the search row is chosen; Enter opens it) |
| Suggestions, the last row | *This time, search with:* a badge per engine (its initial); a click searches the text with it (`browser.urlbar.suggest.engines`) |
| Context menu on selected text | *Search &lt;default&gt; for "…"*, and a *Search with* submenu with the other engines |

## Managing them: about:config, category Search

The first row of the category lists the engines: badge, name, keyword, address. Per engine: *Make default* (the default
shows a *Default* pill), *Edit*, move up or down (the order of every list that shows them), remove (not the last one).
Under them: *Add a search engine* and *Restore the built-in engines (n)* (puts back the built-in engines the list lacks).
Enter on the row opens the form of a new engine.

The form: name, keyword (optional, one word: `@x` or `x`), address with `%s` where the words go
(`https://example.com/search?q=%s`; the words are percent-encoded, spaces as `+`). Enter or *Add* / *Save* applies it,
Escape or *Cancel* leaves it. Refused, with the reason under the form: no name, an address that is not `http(s)://`,
no `%s`, a keyword with a space, a keyword or a name another engine has.

`browser.search.engine` (the row under the list) is a choice of the engines' names; its value is the engine's id.
An id the list lacks means its first engine; removing the default makes the first engine the default.

Built-in engines: DuckDuckGo (`@d`, the default), Bing (`@b`), Google (`@g`), Qwant (`@q`), Ecosia (`@e`), Startpage
(`@s`), Wikipedia (`@w`). They can be edited or removed like the others.

## Stored in the profile

`search_engines.txt` in the profile folder, written at every change (not with `browser.profile.persist` off: the list
then lives for the run). Plain text, versioned:

```
wren-search-engines 1
# id	name	keyword	address (%s: the words searched)
duckduckgo	DuckDuckGo	@d	https://duckduckgo.com/?q=%s
my-wiki	My wiki		https://wiki.example/?search=%s
```

One engine per line, fields separated by a tab (a tab, a line break or a backslash inside a field is written `\t`, `\n`,
`\\`). Ids are stable: an edit keeps it, a new engine gets one from its name. A file of another version is not read (the
built-in engines are used, and the file is overwritten only at the next change). Lines that are malformed, and a second
engine with an id already seen, are skipped.

Without the file: the built-in engines, nothing written until something changes.

### Profiles of before the list

Before the list there was a fixed choice (`browser.search.engine` = duckduckgo, bing, google, qwant, ecosia, startpage
or custom) and `browser.search.custom_url`. A profile keeps its choice without anything to do: the built-in ids are the
same, and `custom` becomes an engine *Custom* (id `custom`) with the former `browser.search.custom_url` (read from the
profile's preferences although no longer registered: `config.user_text`); that list is written at once.

## Code

* `src/browser/search_engines.odin`: the list (`Search_Engines`, pure procedures: `engines_parse` / `engines_serialize`,
  `engines_keyword`, `engine_validate`, `engines_add` / `update` / `remove` / `move`, `engines_migrate`), the browser's
  list `sengines` and `search_url(words, engine = -1)`.
* `src/browser/search_engines_ui.odin`: the about:config row and its form, the badges.
* `src/browser/context_menu.odin`: `address_target` (what the address bar opens, and the search it is).
* `src/browser/urlbar.odin`: the search rows, Ctrl+Up / Down, the row of engines.
* Tests: `src/browser/search_engines_test.odin`; end to end: `tools/search_e2e.ps1`.
