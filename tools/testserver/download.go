package main

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"strconv"
	"time"
)

// Downloads and tab icons for the browser's chrome (src/browser/download.odin, favicon.odin).
//
//	/download/attachment?bytes=N&name=X  Content-Disposition: attachment; filename*=UTF-8''X (default "report été.txt"),
//	                                     N bytes (default 3 MiB) of a repeating pattern, text/plain
//	/download/binary/NAME?bytes=N        application/octet-stream without Content-Disposition (the name comes from the URL)
//	/download/slow?bytes=N&ms=M          application/octet-stream, sent in 64 KiB pieces M ms apart (default 1 MiB, 200 ms)
//	/icon/page?icon=PATH                 an HTML page whose <link rel=icon> is PATH (default /icon/red.png); no PATH
//	                                     parameter value "none": no link (the browser then tries /favicon.ico)
//	/icon/red.png, /icon/blue.png        32 x 32 PNG squares
//	/favicon.ico                         a 16 x 16 green PNG (browsers accept PNG data at .ico addresses)
func registerDownloadHandlers(mux *http.ServeMux) {
	pattern := func(n int) []byte {
		b := make([]byte, n)
		for i := range b {
			b[i] = byte('a' + i%26)
			if i%64 == 63 {
				b[i] = '\n'
			}
		}
		return b
	}
	size := func(r *http.Request, def int) int {
		if v, err := strconv.Atoi(r.URL.Query().Get("bytes")); err == nil && v >= 0 && v <= 1<<30 {
			return v
		}
		return def
	}
	mux.HandleFunc("/download/attachment", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		if name == "" {
			name = "report été.txt"
		}
		body := pattern(size(r, 3<<20))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Disposition", "attachment; filename=\"report.txt\"; filename*=UTF-8''"+pathEscape(name))
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.Write(body)
	})
	mux.HandleFunc("/download/binary/", func(w http.ResponseWriter, r *http.Request) {
		body := pattern(size(r, 256<<10))
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.Write(body)
	})
	mux.HandleFunc("/download/slow", func(w http.ResponseWriter, r *http.Request) {
		n := size(r, 1<<20)
		ms, err := strconv.Atoi(r.URL.Query().Get("ms"))
		if err != nil || ms < 0 {
			ms = 200
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Content-Length", strconv.Itoa(n))
		body := pattern(n)
		f, _ := w.(http.Flusher)
		for off := 0; off < n; off += 64 << 10 {
			end := min(off+64<<10, n)
			if _, err := w.Write(body[off:end]); err != nil {
				return
			}
			if f != nil {
				f.Flush()
			}
			select {
			case <-r.Context().Done():
				return
			case <-time.After(time.Duration(ms) * time.Millisecond):
			}
		}
	})
	square := func(c color.RGBA, n int) []byte {
		img := image.NewRGBA(image.Rect(0, 0, n, n))
		for y := 0; y < n; y++ {
			for x := 0; x < n; x++ {
				img.Set(x, y, c)
			}
		}
		var buf bytes.Buffer
		png.Encode(&buf, img)
		return buf.Bytes()
	}
	red, blue, green := square(color.RGBA{220, 40, 40, 255}, 32), square(color.RGBA{40, 90, 230, 255}, 32), square(color.RGBA{30, 170, 60, 255}, 16)
	servePNG := func(b []byte) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "image/png")
			w.Write(b)
		}
	}
	mux.HandleFunc("/icon/red.png", servePNG(red))
	mux.HandleFunc("/icon/blue.png", servePNG(blue))
	mux.HandleFunc("/favicon.ico", servePNG(green))
	mux.HandleFunc("/icon/page", func(w http.ResponseWriter, r *http.Request) {
		icon := r.URL.Query().Get("icon")
		if icon == "" {
			icon = "/icon/red.png"
		}
		link := ""
		if icon != "none" {
			link = fmt.Sprintf("<link rel=\"icon\" href=\"%s\">", icon)
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, "<!doctype html><title>Icon test</title>%s<p>A page with an icon.</p>", link)
	})
}

func pathEscape(s string) string {
	var b bytes.Buffer
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
