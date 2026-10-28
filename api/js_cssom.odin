// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=25 partial
/// The stylesheets of <style> and <link> elements for JavaScript (CSSOM §6.1, §6.2.1, §6.3: LinkStyle.sheet,
/// document.styleSheets, StyleSheet.ownerNode / href / title): src/page/js_cssom.odin, native/js/runtime/shadow.c.
/// Their CSSStyleSheet objects share the rule-list functions of constructed sheets (js_shadow.widl).
package api_js_cssom

/// element.sheet of a <style> or <link rel=stylesheet> (any other node: 0, null): its CSSStyleSheet, the same
/// object for as long as the element keeps that sheet. A <style> gets its sheet brought up to date first (HTML
/// "update a style block"); a <link>'s is there once loaded.
//@wb fn
LinkStyle_sheetOf :: proc(node: Node) -> u64

/// document.styleSheets / shadowRoot.styleSheets: how many sheets the tree of `root` has (its <style> and loaded
/// <link> elements, in tree order) ...
//@wb fn
DocumentOrShadowRoot_sheetCount :: proc(root: Node) -> u32

/// ... and the one at `index` (0 past the end).
//@wb fn
DocumentOrShadowRoot_sheetAt :: proc(root: Node, index: u32) -> u64

/// Whether `sheet` is a CSSStyleSheet of this page, constructed or an element's.
//@wb fn
CSSStyleSheet_isSheet :: proc(sheet: u64) -> bool

/// sheet.ownerNode: the element of an element's sheet while it has it (0: null).
//@wb fn
CSSStyleSheet_ownerNodeOf :: proc(sheet: u64) -> u64

/// sheet.href: the URL of a <link>'s sheet ("" for null).
//@wb fn
CSSStyleSheet_hrefOf :: proc(sheet: u64) -> string

/// sheet.title: the title attribute of its element ("" for null).
//@wb fn
CSSStyleSheet_titleOf :: proc(sheet: u64) -> string

/// A number that changes with every change of the sheet's rules (the rule list's items are made again then).
//@wb fn
CSSStyleSheet_rulesVersion :: proc(sheet: u64) -> u32

/// The identity of cssRules[index], a number never given to another rule of the page (0 past the end): the rule
/// list gives a rule the same object across insertions and deletions around it.
//@wb fn
CSSStyleSheet_ruleId :: proc(sheet: u64, index: u32) -> u32

