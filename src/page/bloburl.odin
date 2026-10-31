package page

// The blob URL store for a page's realm (package fetch, blob_urls.odin): a URL lasts as long as the realm that made it.

import "core:strings"
import "wb:base"
import "wb:fetch"

BlobURL_register :: proc(c: ^Call, url: string, type: string, data: []u8) {
	p := c.page
	fetch.blob_url_register(url, type, data, p.env.origin)
	if p.blob_urls == nil {
		p.blob_urls = new([dynamic]string)
		base.on_close(p.scope, proc(data: rawptr) {
			list := (^[dynamic]string)(data)
			for u in list^ { fetch.blob_url_revoke(u); delete(u) }
			delete(list^)
			free(list)
		}, p.blob_urls)
	}
	append(p.blob_urls, strings.clone(url))
}

BlobURL_revoke :: proc(c: ^Call, url: string) {
	fetch.blob_url_revoke(url)
	if list := c.page.blob_urls; list != nil {
		for u, i in list^ {
			if u == url {
				delete(u)
				unordered_remove(list, i)
				break
			}
		}
	}
}