// The Python handlers of fetch/api/resources in Go (wpt_python.go: their request and response). Each mirrors its .py file.
package testserver

import (
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	fetchResources      = "/fetch/api/resources/"
	fetchRedirectStash  = "fetch-redirect"
	fetchPreflightStash = "fetch-preflight"
	badChunkDefaultMs   = 1000
	stashedChunkBytes   = 4096
	stashedChunkDelay   = 100 * time.Millisecond
	stashedChunkLinger  = 5 * time.Second
)

func init() {
	for name, main := range fetchHandlers {
		wptPyHandlers[fetchResources+name] = wptPy(main)
	}
	wptPyHandlers["/fetch/api/request/resources/cache.py"] = wptPy(fetchRequestCache)
}

// fetch/api/request/resources/cache.py: remembers the validators of each request of a token, answers as a cache's server does.
func fetchRequestCache(q *pyRequest, p *pyResponse) {
	const script = "fetch-request-cache"
	token := q.q.Get("token")
	if q.has("querystate") {
		p.set("Content-Type", "text/plain")
		value, _ := stashTake(script, token)
		p.body, _ = json.Marshal(value)
		return
	}
	tag := q.q.Get("tag")
	if tag != "" {
		tag = `"` + tag + `"`
	}
	date := q.q.Get("date")
	seen := []map[string]string{}
	if v, ok := stashTake(script, token); ok {
		seen = v.([]map[string]string)
	}
	state := map[string]string{}
	if !q.has("ignore") {
		for _, name := range []string{"If-None-Match", "If-Modified-Since", "Pragma", "Cache-Control"} {
			if value := q.header(name, ""); value != "" {
				state[name] = value
			}
		}
	}
	stashPut(script, token, append(seen, state))
	if tag != "" {
		p.set("ETag", tag)
	} else if date != "" {
		p.set("Last-Modified", date)
	}
	for _, a := range [][2]string{{"expires", "Expires"}, {"vary", "Vary"}, {"cache_control", "Cache-Control"}} {
		if value := q.q.Get(a[0]); value != "" {
			p.set(a[1], value)
		}
	}
	p.set("Access-Control-Allow-Origin", "*")
	switch {
	case q.q.Get("redirect") != "":
		p.set("Location", q.q.Get("redirect"))
		p.code, p.text = http.StatusFound, "Redirect"
	case q.hasHeader("If-None-Match") && q.header("If-None-Match", "") == tag, q.hasHeader("If-Modified-Since") && q.header("If-Modified-Since", "") == date:
		p.status(http.StatusNotModified)
	default:
		p.set("Content-Type", "text/plain")
		p.body = []byte(q.q.Get("content"))
	}
}

// What redirect.py remembers between the requests of a token.
type redirectState struct {
	count     int
	preflight string
}

// What preflight.py does; no controlHeaders: the preflight had none to report.
type preflightState struct {
	controlHeaders *string
	preflight      string
	referrer       string
	userAgent      string
}

// The folder of a request's path, the scope of stash-put.py and stash-take.py.
func urlDir(path string) string { return path[:strings.LastIndexByte(path, '/')+1] }

func fetchRedirect(q *pyRequest, p *pyResponse) {
	state := redirectState{preflight: "0"}
	p.add("Content-Type", "text/plain")
	p.add("Cache-Control", "no-cache")
	p.add("Pragma", "no-cache")
	if q.hasHeader("Origin") {
		p.add("Access-Control-Allow-Origin", q.origin())
		p.add("Access-Control-Allow-Credentials", "true")
	} else {
		p.add("Access-Control-Allow-Origin", "*")
	}
	token, hasToken := q.q.Get("token"), q.has("token")
	if hasToken {
		if v, ok := stashTake(fetchRedirectStash, token); ok {
			state = v.(redirectState)
		}
	}
	if q.r.Method == http.MethodOptions {
		if q.has("allow_headers") {
			p.add("Access-Control-Allow-Headers", q.q.Get("allow_headers"))
		}
		state.preflight = "1"
		if !q.has("redirect_preflight") {
			if hasToken {
				stashPut(fetchRedirectStash, token, state)
			}
			return
		}
	}
	status := http.StatusFound
	if q.has("redirect_status") {
		status = q.firstInt("redirect_status", status)
	} else if form, err := q.post(); err == nil && form.PostForm.Has("redirect_status") {
		status, _ = strconv.Atoi(form.PostForm.Get("redirect_status"))
	}
	state.count++
	if q.has("location") {
		location := q.q.Get("location")
		if !q.has("simple") {
			u, err := url.Parse(location)
			if err == nil && (u.Scheme == "" || u.Scheme == "http" || u.Scheme == "https") {
				if strings.Contains(location, "?") {
					location += "&"
				} else {
					location += "?"
				}
				params := url.Values{}
				for key, values := range q.q {
					params.Set(key, values[0])
				}
				location += params.Encode() + "&count=" + strconv.Itoa(state.count)
			}
		}
		p.add("Location", location)
	}
	if q.has("redirect_referrerpolicy") {
		p.add("Referrer-Policy", q.q.Get("redirect_referrerpolicy"))
	}
	time.Sleep(q.firstMs("delay", 0))
	if hasToken {
		stashPut(fetchRedirectStash, token, state)
		if q.has("max_count") && state.count > q.firstInt("max_count", 0) {
			p.headers = nil
			p.body = []byte(strconv.Itoa(state.count - 1))
			return
		}
	}
	p.status(status)
}

func fetchPreflight(q *pyRequest, p *pyResponse) {
	p.add("Content-Type", "text/plain")
	state := preflightState{controlHeaders: new(string), preflight: "0"}
	token, hasToken := q.q.Get("token"), q.has("token")
	if q.has("origin") {
		for _, origin := range strings.Split(q.q.Get("origin"), ", ") {
			p.add("Access-Control-Allow-Origin", origin)
		}
	} else {
		p.add("Access-Control-Allow-Origin", "*")
	}
	if q.has("clear-stash") {
		if _, ok := stashTake(fetchPreflightStash, token); ok {
			p.body = []byte("1")
		} else {
			p.body = []byte("0")
		}
		return
	}
	if q.has("credentials") {
		p.add("Access-Control-Allow-Credentials", "true")
	}
	if q.r.Method == http.MethodOptions {
		if !q.hasHeader("Access-Control-Request-Method") {
			p.status(http.StatusBadRequest)
			p.body = []byte("ERROR: No access-control-request-method in preflight!")
			return
		}
		if q.header("Accept", "") != "*/*" {
			p.status(http.StatusBadRequest)
			p.body = []byte("ERROR: Invalid access in preflight!")
			return
		}
		if q.has("control_request_headers") {
			state.controlHeaders = nil
			if q.hasHeader("Access-Control-Request-Headers") {
				value := q.header("Access-Control-Request-Headers", "")
				state.controlHeaders = &value
			}
		}
		for _, a := range [][2]string{{"max_age", "Access-Control-Max-Age"}, {"allow_headers", "Access-Control-Allow-Headers"}, {"allow_methods", "Access-Control-Allow-Methods"}} {
			if q.has(a[0]) {
				p.add(a[1], q.q.Get(a[0]))
			}
		}
		state.preflight = "1"
		state.referrer = q.header("Referer", "")
		state.userAgent = q.header("User-Agent", "")
		if hasToken {
			stashPut(fetchPreflightStash, token, state)
		}
		p.status(q.firstInt("preflight_status", http.StatusOK))
		return
	}
	if hasToken {
		if v, ok := stashTake(fetchPreflightStash, token); ok {
			state = v.(preflightState)
		}
	}
	if q.has("checkUserAgentHeaderInPreflight") && q.header("User-Agent", "") != state.userAgent {
		p.status(http.StatusBadRequest)
		p.body = []byte("ERROR: No user-agent header in preflight")
		return
	}
	p.add("Access-Control-Expose-Headers", "x-did-preflight, x-control-request-headers, x-referrer, x-preflight-referrer, x-origin")
	p.add("x-did-preflight", state.preflight)
	if state.controlHeaders != nil {
		p.add("x-control-request-headers", *state.controlHeaders)
	}
	p.add("x-preflight-referrer", state.referrer)
	p.add("x-referrer", q.header("Referer", ""))
	p.add("x-origin", q.origin())
	if hasToken {
		stashPut(fetchPreflightStash, token, state)
	}
}

var fetchHandlers = map[string]func(q *pyRequest, p *pyResponse){
	"status.py":    pyStatus,
	"redirect.py":  fetchRedirect,
	"preflight.py": fetchPreflight,
	"inspect-headers.py": func(q *pyRequest, p *pyResponse) {
		var checked []string
		if q.has("headers") {
			checked = strings.Split(q.q.Get("headers"), "|")
			for _, name := range checked {
				if q.hasHeader(name) {
					p.add("x-request-"+name, q.header(name, ""))
				}
			}
		}
		if q.has("cors") {
			if q.hasHeader("Origin") {
				p.add("Access-Control-Allow-Origin", q.origin())
			} else {
				p.add("Access-Control-Allow-Origin", "*")
			}
			p.add("Access-Control-Allow-Credentials", "true")
			p.add("Access-Control-Allow-Methods", "GET, POST, HEAD")
			exposed := make([]string, len(checked))
			for i, name := range checked {
				exposed[i] = "x-request-" + name
			}
			p.add("Access-Control-Expose-Headers", strings.Join(exposed, ", "))
			if q.has("allow_headers") {
				p.add("Access-Control-Allow-Headers", q.q.Get("allow_headers"))
			} else {
				var names []string
				for _, h := range q.raw {
					names = append(names, strings.ToLower(h[0]))
				}
				p.add("Access-Control-Allow-Headers", strings.Join(names, ", "))
			}
		}
		p.add("content-type", "text/plain")
	},
	"trickle.py": func(q *pyRequest, p *pyResponse) {
		delay := q.firstMs("ms", delayDefaultMs)
		time.Sleep(delay)
		if !q.has("notype") {
			p.set("Content-type", "text/plain")
		}
		p.start()
		time.Sleep(delay)
		for range q.firstInt("count", trickleDefaultCount) {
			p.write([]byte("TEST_TRICKLE\n"))
			time.Sleep(delay)
		}
	},
	"echo-content.py": func(q *pyRequest, p *pyResponse) {
		p.add("X-Request-Method", q.r.Method)
		p.add("X-Request-Content-Length", q.header("Content-Length", "NO"))
		p.add("X-Request-Content-Type", q.header("Content-Type", "NO"))
		p.add("Content-Type", "text/plain")
		p.body = q.body
	},
	"method.py": func(q *pyRequest, p *pyResponse) {
		if q.has("cors") {
			p.add("Access-Control-Allow-Origin", "*")
			p.add("Access-Control-Allow-Credentials", "true")
			p.add("Access-Control-Allow-Methods", "GET, POST, PUT, FOO")
			p.add("Access-Control-Allow-Headers", "x-test, x-foo")
			p.add("Access-Control-Expose-Headers", "x-request-method")
		}
		p.add("x-request-method", q.r.Method)
		for _, name := range []string{"Content-Type", "Content-Length", "Content-Encoding", "Content-Language", "Content-Location"} {
			p.add("x-request-"+strings.ToLower(name), q.header(name, "NO"))
		}
		p.body = q.body
	},
	"stash-put.py": func(q *pyRequest, p *pyResponse) {
		if q.r.Method == http.MethodOptions {
			p.set("Access-Control-Allow-Origin", "*")
			p.set("Access-Control-Allow-Methods", "*")
			p.set("Access-Control-Allow-Headers", "*")
			p.body = []byte("done")
			return
		}
		if !q.has("disallow_cross_origin") {
			p.set("Access-Control-Allow-Origin", "*")
		} else if q.q.Get("mode") != "no-cors" && q.q.Get("frame_origin") != q.scheme()+"://"+q.r.Host {
			p.body = []byte("not stashing for cors request")
			return
		}
		stashPut(urlDir(q.r.URL.Path), q.q.Get("key"), q.q.Get("value"))
		p.body = []byte("done")
	},
	"stash-take.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-Type", "application/json")
		p.set("Access-Control-Allow-Origin", "*")
		value, _ := stashTake(urlDir(q.r.URL.Path), q.q.Get("key"))
		p.body, _ = json.Marshal(value)
	},
	"clean-stash.py": func(q *pyRequest, p *pyResponse) {
		if _, ok := stashTake(fetchPreflightStash, q.q.Get("token")); ok {
			p.body = []byte("1")
		} else {
			p.body = []byte("0")
		}
	},
	"authentication.py": func(q *pyRequest, p *pyResponse) {
		if user, password, _ := q.r.BasicAuth(); user == "user" && password == "password" {
			p.body = []byte("Authentication done")
			return
		}
		p.code, p.text = http.StatusUnauthorized, "Unauthorized"
		p.add("WWW-Authenticate", `Basic realm="`+q.first("realm", "test")+`"`)
		p.body = []byte("Please login with credentials 'user' and 'password'")
	},
	"bad-chunk-encoding.py": func(q *pyRequest, p *pyResponse) {
		delay := q.firstMs("ms", badChunkDefaultMs)
		time.Sleep(delay)
		p.set("Transfer-Encoding", "chunked")
		p.start()
		time.Sleep(delay)
		for range q.firstInt("count", trickleDefaultCount) {
			p.write([]byte("a\r\nTEST_CHUNK\r\n"))
			time.Sleep(delay)
		}
		p.write([]byte("garbage"))
	},
	"cache.py": func(q *pyRequest, p *pyResponse) {
		const etag = `"123abc"`
		if q.header("If-None-Match", "") == etag {
			p.set("X-HTTP-STATUS", strconv.Itoa(http.StatusNotModified))
			p.status(http.StatusNotModified)
			return
		}
		p.set("ETag", etag)
		p.set("Content-Type", "text/plain")
		p.body = []byte("lorem ipsum dolor sit amet")
	},
	"dump-authorization-header.py": func(q *pyRequest, p *pyResponse) {
		p.add("Content-Type", "text/html")
		p.add("Cache-Control", "no-cache")
		if q.q.Get("strip_auth_header") != "" && q.r.Method == http.MethodOptions &&
			strings.Contains(strings.ToLower(q.header("Access-Control-Request-Headers", "")), "authorization") {
			p.status(http.StatusInternalServerError)
			p.body = []byte("fail")
			return
		}
		if q.hasHeader("Origin") {
			p.add("Access-Control-Allow-Origin", q.origin())
			p.add("Access-Control-Allow-Credentials", "true")
		} else {
			p.add("Access-Control-Allow-Origin", "*")
		}
		p.add("Access-Control-Allow-Headers", "Authorization")
		p.body = []byte(q.header("Authorization", "none"))
	},
	"echo-header-bytes.py": func(q *pyRequest, p *pyResponse) {
		p.add("content-type", "text/plain")
		var lines []string
		for _, name := range strings.Split(q.q.Get("headers"), "|") {
			lines = append(lines, name+": "+hex.EncodeToString([]byte(q.header(name, ""))))
		}
		p.body = []byte(strings.Join(lines, "\n"))
	},
	"script-with-header.py": func(q *pyRequest, p *pyResponse) {
		p.add("Content-type", q.q.Get("mime"))
		if q.q.Get("content") != "empty" {
			p.body = []byte("console.log('Script loaded')")
		}
	},
	"redirect-empty-location.py": func(q *pyRequest, p *pyResponse) {
		p.status(http.StatusFound)
		p.add("Location", "")
	},
	"stashed-chunk.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-Type", "application/octet-stream")
		p.set("Cache-Control", "no-store")
		p.start()
		for _, c := range "ABC" {
			p.write([]byte(strings.Repeat(string(c), stashedChunkBytes)))
			time.Sleep(stashedChunkDelay)
		}
		time.Sleep(stashedChunkLinger)
	},
}
