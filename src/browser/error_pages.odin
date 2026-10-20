package browser

// The pages the browser makes up when a document cannot be shown: what happened in words a reader understands (the
// site cannot be reached, its address was not found, it refused the connection, the secure connection failed, the file
// is not there...), what to try, and the technical reason underneath in small type. They follow the user's color scheme
// (color-scheme: light dark, system colors), use the system font, and the tab shows the host or the file's name as its
// title, as Chrome does.

import "core:fmt"
import "core:strings"
import "wb:fetch"
import "wb:url"

Error_Kind :: enum u8 {
	Generic,
	Dns,            // the host name was not found
	Refused,        // nothing listens there
	Timeout,
	Connection,     // the connection was lost or the answer was not HTTP
	Tls,            // the secure connection failed (certificate, protocol)
	Blocked,        // a policy of the browser stopped it (bad port, mixed content, CSP, credentials in the URL)
	Redirects,      // too many redirects, or a bad one
	File_Missing,   // file: not there, or unreadable
	Too_Large,
	Unsupported,    // a scheme or a navigation the browser does not do
	Content,        // it arrived, but cannot be shown (type, encoding)
}

Error_Text :: struct {
	kind:     Error_Kind,
	headline: string,
	explain:  string,   // one sentence, may name the host or the file
	advice:   string,   // what to try
	detail:   string,   // the technical reason (small type)
}

// Classifies a failed navigation (pure: error_pages_test.odin). `address` is what the tab shows.
classify_load_error :: proc(address: string, kind: fetch.Error_Kind, net_code: u32, detail: string) -> Error_Text {
	u, ok := url.parse_absolute(address, context.temp_allocator)
	host := ok ? u.host : address
	file := ok && u.scheme == "file"
	e := Error_Text{kind = .Generic, detail = detail}
	reach :: "This site can't be reached"
	#partial switch kind {
	case .Transport:
		switch {
		case file:
			e.kind = .File_Missing
		case net_code == 12007:
			e.kind = .Dns
		case net_code == 12029:
			e.kind = .Refused
		case net_code == 12002:
			e.kind = .Timeout
		case net_code == 12030 || net_code == 12152:
			e.kind = .Connection
		case net_code == 12157 || net_code == 12175 || net_code == 12038 || net_code == 12045 || net_code == 12037 || net_code == 12044 || net_code == 12169:
			e.kind = .Tls
		}
	case .Bad_Port, .Blocked_Mixed_Content, .Blocked_Csp, .Credentials_In_URL, .Blocked_File, .Blocked_Same_Origin, .Blocked_Cors:
		e.kind = .Blocked
	case .Redirect_Loop, .Bad_Redirect, .Redirect_Error:
		e.kind = .Redirects
	case .Body_Too_Large:
		e.kind = .Too_Large
	case .Bad_Scheme, .Unsupported, .Bad_URL, .Bad_Data_URL:
		e.kind = .Unsupported
	case .Bad_Mime:
		e.kind = .Content
	}
	switch e.kind {
	case .Dns:
		e.headline, e.explain = reach, fmt.tprintf("The server address of %s could not be found.", host)
		e.advice = "Check the spelling of the address, and that this computer is connected to the network."
	case .Refused:
		e.headline, e.explain = reach, fmt.tprintf("%s refused to connect.", host)
		e.advice = "The server may be down, or nothing listens on this port. Try again later."
	case .Timeout:
		e.headline, e.explain = reach, fmt.tprintf("%s took too long to respond.", host)
		e.advice = "Check the network connection, then try again (F5)."
	case .Connection:
		e.headline, e.explain = reach, fmt.tprintf("The connection to %s was interrupted.", host)
		e.advice = "Try again (F5)."
	case .Tls:
		e.headline, e.explain = "Your connection is not private", fmt.tprintf("The secure connection to %s could not be established: Windows did not accept its certificate or its encryption.", host)
		e.advice = "Someone may be trying to intercept the connection, or the site is misconfigured. Nothing was sent to it."
	case .Blocked:
		e.headline, e.explain = "This page has been blocked", fmt.tprintf("%s blocked this request to protect you.", APP_NAME)
		e.advice = "The reason is below."
	case .Redirects:
		e.headline, e.explain = "This page isn't working", fmt.tprintf("%s redirected you too many times, or to an address that cannot be opened.", host)
		e.advice = "Clearing the cookies of this site (page information, in the address bar) sometimes helps."
	case .File_Missing:
		name := default_tab_title(address)
		e.headline, e.explain = "Your file couldn't be accessed", fmt.tprintf("%s could not be read.", name)
		e.advice = "It may have been moved, renamed or deleted, or this account may not be allowed to read it."
	case .Too_Large:
		e.headline, e.explain = "This page is too large", "The document is larger than the browser accepts (network.max_response_bytes)."
		e.advice = "The limit can be raised in about:config."
	case .Unsupported:
		e.headline, e.explain = "This address can't be opened", fmt.tprintf("%s does not open this kind of address.", APP_NAME)
		e.advice = "Check the address."
	case .Content:
		e.headline, e.explain = "This page can't be shown", "The server sent something the browser cannot display here."
		e.advice = ""
	case .Generic:
		e.headline, e.explain = "This page could not be loaded", fmt.tprintf("Something went wrong while loading %s.", host)
		e.advice = "Try again (F5)."
	}
	return e
}

// The tab title of an error page: the host, else the file's name, else the address.
error_tab_title :: proc(address: string) -> string {
	u, ok := url.parse_absolute(address, context.temp_allocator)
	if ok && u.host != "" { return u.host }
	return default_tab_title(address)
}

@(private = "file")
ERROR_PAGE_CSS :: `:root { color-scheme: light dark; font-family: system-ui, "Segoe UI", sans-serif; }
body { margin: 0; background: Canvas; color: CanvasText; }
main { max-width: 600px; margin: 0 auto; padding: 14vh 28px 40px; }
.icon { width: 48px; height: 48px; border-radius: 50%; border: 3px solid GrayText; color: GrayText; font: bold 30px/48px system-ui, sans-serif; text-align: center; margin-bottom: 28px; }
.tls .icon { border-color: #d93025; color: #d93025; }
h1 { font-size: 26px; font-weight: 600; margin: 0 0 18px; line-height: 1.25; }
p { font-size: 15px; line-height: 1.55; margin: 0 0 12px; }
.advice { color: GrayText; }
.where { font-size: 13px; color: GrayText; overflow-wrap: anywhere; margin-top: 22px; }
.detail { font: 12px/1.5 Consolas, monospace; color: GrayText; overflow-wrap: anywhere; text-transform: uppercase; letter-spacing: 0.02em; }
`

// The error page's document.
error_page_html :: proc(e: Error_Text, address, title: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>%s</title><style>%s</style></head>", escape_html(title), ERROR_PAGE_CSS)
	fmt.sbprintf(&sb, "<body class=\"%s\"><main><div class=\"icon\">%s</div><h1>%s</h1><p>%s</p>",
		e.kind == .Tls ? "tls" : "", e.kind == .Tls ? "!" : e.kind == .File_Missing ? "?" : ":(",
		escape_html(e.headline), escape_html(e.explain))
	if e.advice != "" { fmt.sbprintf(&sb, "<p class=\"advice\">%s</p>", escape_html(e.advice)) }
	fmt.sbprintf(&sb, "<p class=\"where\">%s</p>", escape_html(address))
	if e.detail != "" { fmt.sbprintf(&sb, "<p class=\"detail\">%s</p>", escape_html(e.detail)) }
	strings.write_string(&sb, "</main></body></html>")
	return strings.to_string(sb)
}
