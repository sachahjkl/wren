package page

// Media Source Extensions (MediaSource, SourceBuffer): the host side of a MediaSource object URL a media element plays.
// Written in the next step; until then no object URL is a Media Source.

Media_Source_Link :: struct {}

@(private)
media_source_detach :: proc(el: ^Media_Element) {}

@(private)
media_source_attach_url :: proc(el: ^Media_Element, href: string) -> bool { return false }

@(private)
media_source_ended :: proc(el: ^Media_Element) -> bool { return false }

@(private)
media_source_buffered :: proc(el: ^Media_Element) -> [][2]f64 { return nil }

@(private)
media_source_seekable :: proc(el: ^Media_Element) -> [][2]f64 { return nil }
