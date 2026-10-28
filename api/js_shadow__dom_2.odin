// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=47 partial
package api_js_shadow__dom_2

/// new CSSStyleSheet(options): a constructed stylesheet (an object of the page).
//@wb fn
CSSStyleSheet_create :: proc(media: string, disabled: bool, base_url: string) -> u64

/// replaceSync(text) / replace(text): the rules of `text`, @import rules dropped.
//@wb fn raises
CSSStyleSheet_replaceText :: proc(sheet: u64, text: string)

/// The number of top-level rules, and the text of one (Index_Size past the end).
//@wb fn
CSSStyleSheet_ruleCount :: proc(sheet: u64) -> u32

//@wb fn raises
CSSStyleSheet_ruleText :: proc(sheet: u64, index: u32) -> string

/// insertRule(rule, index): Index_Size past the end, Syntax when `rule` is not one rule; the index.
//@wb fn raises
CSSStyleSheet_insertRuleAt :: proc(sheet: u64, rule: string, index: u32) -> u32

/// deleteRule(index): Index_Size past the end.
//@wb fn raises
CSSStyleSheet_deleteRuleAt :: proc(sheet: u64, index: u32)

/// sheet.disabled
//@wb fn
CSSStyleSheet_isDisabled :: proc(sheet: u64) -> bool

//@wb fn
CSSStyleSheet_setDisabled :: proc(sheet: u64, disabled: bool)

/// sheet.media.mediaText
//@wb fn
CSSStyleSheet_mediaText :: proc(sheet: u64) -> string

//@wb fn
CSSStyleSheet_setMediaText :: proc(sheet: u64, media: string)

/// Whether `sheet` is a constructed stylesheet of this page.
//@wb fn
CSSStyleSheet_isConstructed :: proc(sheet: u64) -> bool

/// document.adoptedStyleSheets / shadowRoot.adoptedStyleSheets = sheets (constructed sheets, in order):
/// Not_Allowed for a sheet that was not constructed.
//@wb fn raises
DocumentOrShadowRoot_adopt :: proc(root: Node, sheets: []u64)

