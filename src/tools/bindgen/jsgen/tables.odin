package jsgen

// What the IDL does not say: which interface an element of a given name gets (HTML "element interface" of each
// element, SVG and MathML element interfaces), and the interfaces that must exist even with nothing of them
// implemented (wrappers need their prototypes).

HTML_ELEMENTS := [?][2]string{
	{"a", "HTMLAnchorElement"}, {"abbr", "HTMLElement"}, {"address", "HTMLElement"}, {"area", "HTMLAreaElement"},
	{"article", "HTMLElement"}, {"aside", "HTMLElement"}, {"audio", "HTMLAudioElement"}, {"b", "HTMLElement"},
	{"base", "HTMLBaseElement"}, {"bdi", "HTMLElement"}, {"bdo", "HTMLElement"}, {"blockquote", "HTMLQuoteElement"},
	{"body", "HTMLBodyElement"}, {"br", "HTMLBRElement"}, {"button", "HTMLButtonElement"}, {"canvas", "HTMLCanvasElement"},
	{"caption", "HTMLTableCaptionElement"}, {"cite", "HTMLElement"}, {"code", "HTMLElement"}, {"col", "HTMLTableColElement"},
	{"colgroup", "HTMLTableColElement"}, {"data", "HTMLDataElement"}, {"datalist", "HTMLDataListElement"}, {"dd", "HTMLElement"},
	{"del", "HTMLModElement"}, {"details", "HTMLDetailsElement"}, {"dfn", "HTMLElement"}, {"dialog", "HTMLDialogElement"},
	{"div", "HTMLDivElement"}, {"dl", "HTMLDListElement"}, {"dt", "HTMLElement"}, {"em", "HTMLElement"},
	{"embed", "HTMLEmbedElement"}, {"fieldset", "HTMLFieldSetElement"}, {"figcaption", "HTMLElement"}, {"figure", "HTMLElement"},
	{"footer", "HTMLElement"}, {"form", "HTMLFormElement"}, {"h1", "HTMLHeadingElement"}, {"h2", "HTMLHeadingElement"},
	{"h3", "HTMLHeadingElement"}, {"h4", "HTMLHeadingElement"}, {"h5", "HTMLHeadingElement"}, {"h6", "HTMLHeadingElement"},
	{"head", "HTMLHeadElement"}, {"header", "HTMLElement"}, {"hgroup", "HTMLElement"}, {"hr", "HTMLHRElement"},
	{"html", "HTMLHtmlElement"}, {"i", "HTMLElement"}, {"iframe", "HTMLIFrameElement"}, {"img", "HTMLImageElement"},
	{"input", "HTMLInputElement"}, {"ins", "HTMLModElement"}, {"kbd", "HTMLElement"}, {"label", "HTMLLabelElement"},
	{"legend", "HTMLLegendElement"}, {"li", "HTMLLIElement"}, {"link", "HTMLLinkElement"}, {"main", "HTMLElement"},
	{"map", "HTMLMapElement"}, {"mark", "HTMLElement"}, {"menu", "HTMLMenuElement"}, {"meta", "HTMLMetaElement"},
	{"meter", "HTMLMeterElement"}, {"nav", "HTMLElement"}, {"noscript", "HTMLElement"}, {"object", "HTMLObjectElement"},
	{"ol", "HTMLOListElement"}, {"optgroup", "HTMLOptGroupElement"}, {"option", "HTMLOptionElement"}, {"output", "HTMLOutputElement"},
	{"p", "HTMLParagraphElement"}, {"picture", "HTMLPictureElement"}, {"pre", "HTMLPreElement"}, {"progress", "HTMLProgressElement"},
	{"q", "HTMLQuoteElement"}, {"rp", "HTMLElement"}, {"rt", "HTMLElement"}, {"ruby", "HTMLElement"}, {"s", "HTMLElement"},
	{"samp", "HTMLElement"}, {"search", "HTMLElement"}, {"section", "HTMLElement"}, {"script", "HTMLScriptElement"},
	{"select", "HTMLSelectElement"}, {"slot", "HTMLSlotElement"}, {"small", "HTMLElement"}, {"source", "HTMLSourceElement"},
	{"span", "HTMLSpanElement"}, {"strong", "HTMLElement"}, {"style", "HTMLStyleElement"}, {"sub", "HTMLElement"},
	{"summary", "HTMLElement"}, {"sup", "HTMLElement"}, {"table", "HTMLTableElement"}, {"tbody", "HTMLTableSectionElement"},
	{"td", "HTMLTableCellElement"}, {"template", "HTMLTemplateElement"}, {"textarea", "HTMLTextAreaElement"},
	{"tfoot", "HTMLTableSectionElement"}, {"th", "HTMLTableCellElement"}, {"thead", "HTMLTableSectionElement"},
	{"time", "HTMLTimeElement"}, {"title", "HTMLTitleElement"}, {"tr", "HTMLTableRowElement"}, {"track", "HTMLTrackElement"},
	{"u", "HTMLElement"}, {"ul", "HTMLUListElement"}, {"var", "HTMLElement"}, {"video", "HTMLVideoElement"}, {"wbr", "HTMLElement"},
	// obsolete and legacy (HTML "Obsolete features" and "Elements in the DOM")
	{"acronym", "HTMLElement"}, {"basefont", "HTMLElement"}, {"big", "HTMLElement"}, {"center", "HTMLElement"},
	{"nobr", "HTMLElement"}, {"noembed", "HTMLElement"}, {"noframes", "HTMLElement"}, {"plaintext", "HTMLElement"},
	{"rb", "HTMLElement"}, {"rtc", "HTMLElement"}, {"strike", "HTMLElement"}, {"tt", "HTMLElement"},
	{"listing", "HTMLPreElement"}, {"xmp", "HTMLPreElement"}, {"dir", "HTMLDirectoryElement"}, {"font", "HTMLFontElement"},
	{"frame", "HTMLFrameElement"}, {"frameset", "HTMLFrameSetElement"}, {"marquee", "HTMLMarqueeElement"},
	{"param", "HTMLParamElement"}, {"applet", "HTMLUnknownElement"}, {"bgsound", "HTMLUnknownElement"},
	{"blink", "HTMLUnknownElement"}, {"isindex", "HTMLUnknownElement"}, {"keygen", "HTMLUnknownElement"},
	{"multicol", "HTMLUnknownElement"}, {"nextid", "HTMLUnknownElement"}, {"spacer", "HTMLUnknownElement"},
}

// Lower-cased local names (the browser's DOM keeps element names in lower case).
SVG_ELEMENTS := [?][2]string{
	{"svg", "SVGSVGElement"}, {"g", "SVGGElement"}, {"defs", "SVGDefsElement"}, {"desc", "SVGDescElement"},
	{"title", "SVGTitleElement"}, {"metadata", "SVGMetadataElement"}, {"symbol", "SVGSymbolElement"}, {"use", "SVGUseElement"},
	{"switch", "SVGSwitchElement"}, {"path", "SVGPathElement"}, {"rect", "SVGRectElement"}, {"circle", "SVGCircleElement"},
	{"ellipse", "SVGEllipseElement"}, {"line", "SVGLineElement"}, {"polyline", "SVGPolylineElement"},
	{"polygon", "SVGPolygonElement"}, {"text", "SVGTextElement"}, {"tspan", "SVGTSpanElement"},
	{"textpath", "SVGTextPathElement"}, {"image", "SVGImageElement"}, {"foreignobject", "SVGForeignObjectElement"},
	{"marker", "SVGMarkerElement"}, {"lineargradient", "SVGLinearGradientElement"}, {"radialgradient", "SVGRadialGradientElement"},
	{"stop", "SVGStopElement"}, {"pattern", "SVGPatternElement"}, {"clippath", "SVGClipPathElement"}, {"mask", "SVGMaskElement"},
	{"filter", "SVGFilterElement"}, {"a", "SVGAElement"}, {"view", "SVGViewElement"}, {"script", "SVGScriptElement"},
	{"style", "SVGStyleElement"}, {"animate", "SVGAnimateElement"}, {"set", "SVGSetElement"},
	{"animatemotion", "SVGAnimateMotionElement"}, {"animatetransform", "SVGAnimateTransformElement"}, {"mpath", "SVGMPathElement"},
	{"feblend", "SVGFEBlendElement"}, {"fecolormatrix", "SVGFEColorMatrixElement"}, {"fecomposite", "SVGFECompositeElement"},
	{"feflood", "SVGFEFloodElement"}, {"fegaussianblur", "SVGFEGaussianBlurElement"}, {"feimage", "SVGFEImageElement"},
	{"femerge", "SVGFEMergeElement"}, {"femergenode", "SVGFEMergeNodeElement"}, {"feoffset", "SVGFEOffsetElement"},
	{"fedropshadow", "SVGFEDropShadowElement"}, {"feturbulence", "SVGFETurbulenceElement"}, {"femorphology", "SVGFEMorphologyElement"},
	{"fetile", "SVGFETileElement"}, {"fecomponenttransfer", "SVGFEComponentTransferElement"}, {"fefunca", "SVGFEFuncAElement"},
	{"fefuncr", "SVGFEFuncRElement"}, {"fefuncg", "SVGFEFuncGElement"}, {"fefuncb", "SVGFEFuncBElement"},
	{"fediffuselighting", "SVGFEDiffuseLightingElement"}, {"fespecularlighting", "SVGFESpecularLightingElement"},
	{"fedistantlight", "SVGFEDistantLightElement"}, {"fepointlight", "SVGFEPointLightElement"},
	{"fespotlight", "SVGFESpotLightElement"}, {"feconvolvematrix", "SVGFEConvolveMatrixElement"},
	{"fedisplacementmap", "SVGFEDisplacementMapElement"},
}

// Node types (DOM "node type") and the interface of their wrapper.
NODE_INTERFACES := [?]string{
	"Node", "Element", "HTMLElement", "HTMLUnknownElement", "SVGElement", "MathMLElement", "Text", "Comment", "CDATASection",
	"ProcessingInstruction", "Document", "HTMLDocument", "XMLDocument", "DocumentType", "DocumentFragment", "ShadowRoot", "Attr",
	"CharacterData",
}

// Interfaces present whatever is implemented of them: the global objects and what the engine needs to exist.
ALWAYS := [?]string{
	"Window", "WorkerGlobalScope", "DedicatedWorkerGlobalScope", "EventTarget", "Event", "DOMException", "console",
	"NodeFilter",   // a callback interface of constants only: nothing to implement, scripts use NodeFilter.SHOW_*
}
