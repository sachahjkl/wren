package i18n

// Every text the user reads goes through this package, so that Wren can be translated without going through the code again:
//
//	label := i18n.tr("Open in a new tab")
//	ctx   := i18n.trc("tab strip", "Close")                  // the same English word with another meaning elsewhere
//	n     := fmt.tprintf(i18n.trn(count, "%d request", "%d requests"), count)
//
// The English text is the key. English is the only language for now: each call returns its argument, which is a string literal
// in the executable's read-only data, so a call costs nothing (no lookup, no allocation, no copy) and the texts sit where the
// linker put them, side by side. There is no code to load a language yet, on purpose.
//
// What a language will be, so that it never costs more than that (the interface is immediate: tr runs for every label, every
// frame, so a lookup must not hash the text or walk a map of heap strings):
//   - one blob, embedded in the executable (#load of a file of the repository: the release stays one file), holding every
//     translated text one after the other; no string of it is allocated on its own, and the blob is not freed or moved;
//   - one flat table, open addressing, in one allocation: the key is the address and the length of the English literal (the
//     pointer is the identity of a literal: a hash of two machine words, not of the characters), the value is the address and the
//     length of the translation in the blob; a text with no entry returns itself;
//   - changing the language swaps the table, nothing else moves; the English path stays the identity.
// See docs/i18n.md for what to translate and how to write the texts.
//// tools\i18n_list.ps1 lists the texts the code passes here.

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
