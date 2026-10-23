// Video and audio for the media tests (src/tools/videotest, examples/site/video.html).
//
//	/video/f/NAME                 a file of examples/site/media/video, with Range support (206) and its media type
//	                              (video/mp4, audio/mp4, video/webm); every request is counted
//	?delay=MS                     wait MS milliseconds before the first byte
//	?rate=BYTES                   send BYTES per second (a slow download: buffering, waiting events)
//	?status=CODE                  answer with this status and no body
//	/video/count?name=N           how many requests the file N had, and the Range header of the last one
package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var videoCounts = struct {
	sync.Mutex
	n     map[string]int
	rng   map[string]string
}{n: map[string]int{}, rng: map[string]string{}}

func videoType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".m4a":
		return "audio/mp4"
	case ".webm":
		return "video/webm"
	}
	return "application/octet-stream"
}

// A writer that sends `rate` bytes per second.
type slowWriter struct {
	w    http.ResponseWriter
	rate int
	last time.Time
}

func (s *slowWriter) Header() http.Header { return s.w.Header() }
func (s *slowWriter) WriteHeader(c int)   { s.w.WriteHeader(c) }
func (s *slowWriter) Write(b []byte) (int, error) {
	total := 0
	for len(b) > 0 {
		n := s.rate / 20
		if n < 1 {
			n = 1
		}
		if n > len(b) {
			n = len(b)
		}
		m, err := s.w.Write(b[:n])
		total += m
		if err != nil {
			return total, err
		}
		if f, ok := s.w.(http.Flusher); ok {
			f.Flush()
		}
		b = b[n:]
		time.Sleep(50 * time.Millisecond)
	}
	return total, nil
}

func registerVideoHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/video/f/", func(w http.ResponseWriter, r *http.Request) {
		name := filepath.Base(strings.TrimPrefix(r.URL.Path, "/video/f/"))
		videoCounts.Lock()
		videoCounts.n[name]++
		videoCounts.rng[name] = r.Header.Get("Range")
		videoCounts.Unlock()
		q := r.URL.Query()
		if d, err := strconv.Atoi(q.Get("delay")); err == nil {
			time.Sleep(time.Duration(d) * time.Millisecond)
		}
		if c, err := strconv.Atoi(q.Get("status")); err == nil && c != 0 {
			w.WriteHeader(c)
			return
		}
		f, err := os.Open(sitePath("media", "video", name))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		defer f.Close()
		st, _ := f.Stat()
		w.Header().Set("Content-Type", videoType(name))
		w.Header().Set("Cache-Control", "no-store")
		var out http.ResponseWriter = w
		if rate, err := strconv.Atoi(q.Get("rate")); err == nil && rate > 0 {
			out = &slowWriter{w: w, rate: rate}
		}
		http.ServeContent(out, r, name, st.ModTime(), f)
	})
	mux.HandleFunc("/video/count", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		videoCounts.Lock()
		n, rng := videoCounts.n[name], videoCounts.rng[name]
		videoCounts.Unlock()
		fmt.Fprintf(w, "%d\n%s\n", n, rng)
	})
}
