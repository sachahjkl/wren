// Package i18n: the text catalogue now lives in the toolkit (toolkit:i18n), a cross-application concern. This is a thin
// alias so Wren's many callers keep writing `import "wb:i18n"` and `i18n.tr(...)` unchanged. See toolkit:i18n for the
// whole picture (docs/i18n.md in the toolkit).
//
// `tr` is a procedure group, which Odin resolves inside the package that declares it: the group is re-declared here over
// the toolkit's three member procedures (aliased by `::`), so `i18n.tr` keeps picking the form from its arguments. The
// members are also re-exported under their own names for the rare caller that referred to one directly.
package i18n

import ti18n "../../ext/gui_toolkit/i18n"

tr :: proc{tr_text, tr_context, tr_count}

tr_text :: ti18n.tr_text
tr_context :: ti18n.tr_context
tr_count :: ti18n.tr_count
