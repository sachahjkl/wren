package i18n

// Every text the user reads goes through this package, so that Wren can be translated without going through the code again:
//
//	label := i18n.tr("Open in a new tab")
//	ctx   := i18n.trc("tab strip", "Close")                  // the same English word with another meaning elsewhere
//	n     := fmt.tprintf(i18n.trn(count, "%d request", "%d requests"), count)
//
// The English text is the key. Today English is the only language, so each call returns its argument and costs nothing; a
// language will be a table from the English text to its translation, embedded in the executable (#load of the files of the
// repository: the release stays one file) and chosen by browser.ui.language, with the language of Windows as its default. A
// text with no entry in the language shows in English. See docs/i18n.md for what to translate and how to write the texts.
//
// tools\i18n_list.ps1 lists the texts the code passes here.

// The text to show for `text`, an English sentence or label.
@(require_results)
tr :: #force_inline proc "contextless" (text: string) -> string {
	return text
}

// The text to show for `text` in the place named by `context`, to tell apart two meanings of the same English word ("Close"
// a tab, "Close" a dialog). The context is for the translator and is never shown.
@(require_results)
trc :: #force_inline proc "contextless" (context_: string, text: string) -> string {
	return text
}

// The singular or the plural form for `count`. Languages have more forms than two (Polish, Russian and Arabic have several;
// French reads 0 as singular): the choice belongs to the language, which is why a caller never writes `count == 1`.
@(require_results)
trn :: #force_inline proc "contextless" (count: int, one: string, other: string) -> string {
	return one if count == 1 else other
}
