// Where the demo pages are: examples/site from the repository (run from its root, as the tests do), or demos\ next
// to the executable (the release package: wren.exe, testserver.exe and demos\ side by side), or what -site DIR says.
//
// /site/ serves them as static servers usually do: a folder shows its index.html, else the list of its files; a path
// without an extension that names no file serves the .html page of that name (/site/grid -> grid.html); a folder
// without its final '/' is redirected to it; the Content-Type comes from a fixed table of the types the pages use, not
// from the Windows registry (which may say text/plain for .js, or nothing for .wasm and .avif).
package main

import (
	"bytes"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

var siteDir = findSiteDir()

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func findSiteDir() string {
	for i, a := range os.Args {
		if a == "-site" && i+1 < len(os.Args) {
			return os.Args[i+1]
		}
	}
	if isDir("examples/site") {
		return "examples/site"
	}
	if exe, err := os.Executable(); err == nil {
		if d := filepath.Join(filepath.Dir(exe), "demos"); isDir(d) {
			return d
		}
	}
	if isDir("demos") {
		return "demos"
	}
	return "examples/site"
}

// A file of the site: sitePath("images", "red.png").
func sitePath(parts ...string) string {
	return filepath.Join(append([]string{siteDir}, parts...)...)
}

var siteTypes = map[string]string{
	".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
	".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".json": "application/json",
	".wasm": "application/wasm", ".txt": "text/plain; charset=utf-8", ".xml": "application/xml",
	".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
	".webp": "image/webp", ".avif": "image/avif", ".bmp": "image/bmp", ".ico": "image/x-icon", ".tif": "image/tiff",
	".tiff": "image/tiff", ".woff2": "font/woff2", ".woff": "font/woff", ".ttf": "font/ttf", ".otf": "font/otf",
	".mp4": "video/mp4", ".webm": "video/webm", ".mp3": "audio/mpeg",
}

func setSiteType(w http.ResponseWriter, name string) {
	if t, ok := siteTypes[strings.ToLower(path.Ext(name))]; ok {
		w.Header().Set("Content-Type", t)
	}
}

// Serves one file as it is (no redirect of .../index.html, unlike http.ServeFile).
func serveSiteFile(w http.ResponseWriter, r *http.Request, full string) bool {
	f, err := os.Open(full)
	if err != nil {
		return false
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || st.IsDir() {
		return false
	}
	setSiteType(w, full)
	if !servePorted(w, r, full, st) {
		http.ServeContent(w, r, st.Name(), st.ModTime(), f)
	}
	return true
}

// A text file of the site with the ports of the default block moved to this server's (ports.go); false when nothing
// is to change (the default block, or a binary file), which the caller serves as it is.
func servePorted(w http.ResponseWriter, r *http.Request, full string, st os.FileInfo) bool {
	if basePort == defaultBasePort {
		return false
	}
	switch strings.ToLower(path.Ext(full)) {
	case ".html", ".htm", ".css", ".js", ".mjs", ".json", ".svg", ".txt", ".xml":
	default:
		return false
	}
	b, err := os.ReadFile(full)
	if err != nil {
		return false
	}
	http.ServeContent(w, r, st.Name(), st.ModTime(), bytes.NewReader(portsRewrite(b)))
	return true
}

// The handler of a folder of pages, mounted under a prefix with http.StripPrefix.
func siteHandler(root string) http.Handler {
	files := http.FileServer(http.Dir(root))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rel := path.Clean("/" + r.URL.Path)
		full := filepath.Join(root, filepath.FromSlash(rel))
		st, err := os.Stat(full)
		switch {
		case err == nil && st.IsDir():
			if r.URL.Path != "" && !strings.HasSuffix(r.URL.Path, "/") {
				target := path.Base(rel) + "/"
				if r.URL.RawQuery != "" {
					target += "?" + r.URL.RawQuery
				}
				http.Redirect(w, r, target, http.StatusMovedPermanently)
				return
			}
			for _, index := range []string{"index.html", "index.htm"} {
				if serveSiteFile(w, r, filepath.Join(full, index)) {
					return
				}
			}
			listSiteDir(w, r, full, rel)
		case err != nil && path.Ext(rel) == "" && rel != "/":
			// /site/grid -> grid.html
			if serveSiteFile(w, r, full+".html") {
				return
			}
			http.NotFound(w, r)
		default:
			setSiteType(w, full)
			if err == nil && servePorted(w, r, full, st) {
				return
			}
			files.ServeHTTP(w, r)
		}
	})
}

// "Index of /site/images/": folders then files, names sorted case-insensitively, hidden (dot) files left out.
func listSiteDir(w http.ResponseWriter, r *http.Request, dir, rel string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		http.Error(w, "cannot list the folder", http.StatusForbidden)
		return
	}
	sort.SliceStable(entries, func(i, j int) bool {
		a, b := entries[i], entries[j]
		if a.IsDir() != b.IsDir() {
			return a.IsDir()
		}
		return strings.ToLower(a.Name()) < strings.ToLower(b.Name())
	})
	// the path as requested (StripPrefix took the mount point off r.URL.Path)
	shown := r.RequestURI
	if i := strings.IndexByte(shown, '?'); i >= 0 {
		shown = shown[:i]
	}
	if u, err := url.PathUnescape(shown); err == nil {
		shown = u
	}
	title := html.EscapeString("Index of " + shown)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="light dark">
<title>%s</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font-family: system-ui; font-size: 14px; background-color: Canvas; color: CanvasText; }
  .wrap { max-width: 900px; margin: 0 auto; padding: 28px 24px; }
  h1 { font-size: 20px; font-weight: 600; margin: 0 0 14px; }
  a { color: LinkText; text-decoration: none; }
  a:hover { text-decoration: underline; }
  table { width: 100%%; border-collapse: collapse; }
  th { text-align: left; font-size: 12px; color: GrayText; padding: 6px 12px; border-bottom: 1px solid light-dark(#c9ced8, #3b4152); }
  td { padding: 5px 12px; border-bottom: 1px solid light-dark(#eceef3, #262b36); }
  .num { text-align: right; white-space: nowrap; }
  .dir { font-weight: 600; }
</style>
</head>
<body>
<div class="wrap">
<h1>%s</h1>
`, title, title)
	if rel != "/" {
		io.WriteString(w, "<p><a href=\"../\">&#8593; Parent folder</a></p>\n")
	}
	io.WriteString(w, "<table>\n<thead><tr><th>Name</th><th class=\"num\">Size</th><th>Date modified</th></tr></thead>\n<tbody>\n")
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		href := (&url.URL{Path: name}).EscapedPath()
		if strings.Contains(name, ":") {
			href = "./" + href // never read as a scheme
		}
		size, class, shown := fmt.Sprintf("%d B", info.Size()), "", name
		if e.IsDir() {
			href, size, class, shown = href+"/", "", " class=\"dir\"", name+"/"
		}
		fmt.Fprintf(w, "<tr><td><a%s href=\"%s\">%s</a></td><td class=\"num\">%s</td><td>%s</td></tr>\n",
			class, html.EscapeString(href), html.EscapeString(shown), size, info.ModTime().Format("2006-01-02 15:04"))
	}
	io.WriteString(w, "</tbody>\n</table>\n</div>\n</body>\n</html>\n")
}
