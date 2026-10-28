// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dom order=37 partial
/// CSSOM for JavaScript (src/page/js_dom_style.odin): element.style, a CSSStyleDeclaration over the `style` attribute
/// (parsed and validated by the style engine's own parser, written back serialized), and getComputedStyle, read-only
/// over the computed values (the used values of layout for the box sizes, as CSSOM says). Property names are CSS names
/// ("margin-top", "--custom").
package api_js_dom_style

/// style.getPropertyValue(name): a longhand, a shorthand rebuilt from its longhands, or a custom property.
//@wb fn
InlineStyle_getProperty :: proc(element: Element, name: string) -> string

/// style.getPropertyPriority(name): "important" or "".
//@wb fn
InlineStyle_priority :: proc(element: Element, name: string) -> string

/// style.setProperty(name, value, priority): an empty value removes it; an unknown property or an invalid value
/// changes nothing (as CSSOM says).
//@wb fn raises
InlineStyle_setProperty :: proc(element: Element, name: string, value: string, priority: string)

/// style.removeProperty(name): the value it had.
//@wb fn raises effects
InlineStyle_removeProperty :: proc(element: Element, name: string) -> string

/// style.cssText
//@wb fn
InlineStyle_cssText :: proc(element: Element) -> string

/// style.cssText = text
//@wb fn raises
InlineStyle_setCssText :: proc(element: Element, text: string)

/// style.length: the longhands declared (shorthands count as theirs).
//@wb fn
InlineStyle_length :: proc(element: Element) -> u32

/// style.item(index) ("" past the end).
//@wb fn
InlineStyle_item :: proc(element: Element, index: u32) -> string

/// getComputedStyle(element, pseudo).getPropertyValue(name): "" for a property the browser does not compute.
/// `pseudo`: "", "::before", "::after" (":before" too).
//@wb fn
ComputedStyle_get :: proc(element: Element, pseudo: string, name: string) -> string

/// The number of properties getComputedStyle lists.
//@wb fn
ComputedStyle_count :: proc() -> u32

/// The name of the listed property at `index` ("" past the end).
//@wb fn
ComputedStyle_name :: proc(index: u32) -> string

/// CSS.supports(property, value) (CSS Conditional 3 §8.1): a property the style engine knows whose value it parses.
//@wb fn
CSS_supportsDeclaration :: proc(property: string, value: string) -> bool

/// CSS.supports(conditionText): a <supports-condition>, or a declaration without its parentheses.
//@wb fn
CSS_supportsCondition :: proc(condition: string) -> bool

