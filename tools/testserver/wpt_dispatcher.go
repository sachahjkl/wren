// Two Python handlers of web-platform-tests in Go: /common/dispatcher/dispatcher.py, the stash through which the pages of a test
// talk across origins and browsing context groups (dispatcher.js: send() posts to a uuid's queue, receive() polls it), and
// html/cross-origin-opener-policy/resources/coop-coep.py, the page a COOP test opens with the policies of its query. Each mirrors
// its .py file.
package testserver

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
)

var dispatcherStash = struct {
	sync.Mutex
	queues map[string][][]byte
}{queues: map[string][][]byte{}}

func init() {
	wptPyHandlers["/common/dispatcher/dispatcher.py"] = wptDispatcher
	wptPyHandlers["/html/cross-origin-opener-policy/resources/coop-coep.py"] = wptCoopCoep
}

func wptDispatcherReset() {
	dispatcherStash.Lock()
	dispatcherStash.queues = map[string][][]byte{}
	dispatcherStash.Unlock()
}

func wptDispatcher(w http.ResponseWriter, r *http.Request) {
	h := w.Header()
	h.Set("Access-Control-Allow-Credentials", "true")
	h.Set("Access-Control-Allow-Methods", "OPTIONS, GET, POST")
	h.Set("Access-Control-Allow-Headers", "Content-Type")
	origin := r.Header.Get("Origin")
	if origin == "" {
		origin = "*"
	}
	h.Set("Access-Control-Allow-Origin", origin)
	q := r.URL.Query()
	if q.Has("cacheable") {
		h.Set("Cache-Control", "max-age=31536000")
	} else {
		h.Set("Cache-Control", "no-cache, no-store, must-revalidate")
	}
	if r.Method == http.MethodOptions {
		return
	}
	uuid := q.Get("uuid")
	dispatcherStash.Lock()
	defer dispatcherStash.Unlock()
	queue := dispatcherStash.queues[uuid]
	var ret []byte
	switch {
	case q.Has("show-headers"):
		headers := map[string]string{}
		for k := range r.Header {
			headers[strings.ToLower(k)] = r.Header.Get(k)
		}
		data, _ := json.Marshal(headers)
		queue = append(queue, data)
	case r.Method == http.MethodPost:
		body, _ := io.ReadAll(r.Body)
		queue = append(queue, body)
		ret = []byte("done")
	case len(queue) == 0:
		ret = []byte("not ready")
	default:
		ret, queue = queue[0], queue[1:]
	}
	dispatcherStash.queues[uuid] = queue
	w.Write(ret)
}

// The query (or the form of a POST), the first value of a key, and whether it is there.
func firstValue(r *http.Request, key string) (string, bool) {
	values := r.URL.Query()
	if r.Method == http.MethodPost {
		r.ParseForm()
		values = r.PostForm
	}
	v, ok := values[key]
	if !ok || len(v) == 0 {
		return "", false
	}
	return v[0], true
}

func wptCoopCoep(w http.ResponseWriter, r *http.Request) {
	coop, _ := firstValue(r, "coop")
	coep, _ := firstValue(r, "coep")
	if coop != "" {
		w.Header().Set("Cross-Origin-Opener-Policy", coop)
	}
	if v, ok := firstValue(r, "coop-report-only"); ok {
		w.Header().Set("Cross-Origin-Opener-Policy-Report-Only", v)
	}
	if coep != "" {
		w.Header().Set("Cross-Origin-Embedder-Policy", coep)
	}
	if v, ok := firstValue(r, "coep-report-only"); ok {
		w.Header().Set("Cross-Origin-Embedder-Policy-Report-Only", v)
	}
	if _, ok := firstValue(r, "cache"); ok {
		w.Header().Set("Cache-Control", "max-age=3600")
	}
	if to, ok := firstValue(r, "redirect"); ok {
		w.Header().Set("Location", to)
		w.WriteHeader(http.StatusFound)
		return
	}
	// the parameters the page reads, as json.dumps writes them (null when absent)
	var params strings.Builder
	params.WriteString("{")
	for i, key := range []string{"navHistory", "avoidBackAndForth", "navigate", "channel", "responseToken", "iframeToken"} {
		if i > 0 {
			params.WriteString(", ")
		}
		value := "null"
		if v, ok := firstValue(r, key); ok && v != "" {
			b, _ := json.Marshal(v)
			value = string(b)
		}
		fmt.Fprintf(&params, "%q: %s", key, value)
	}
	params.WriteString("}")
	w.Header().Set("Content-Type", "text/html")
	fmt.Fprintf(w, coopCoepPage, params.String())
}

const coopCoepPage = `
<!doctype html>
<meta charset=utf-8>
<script src="/common/get-host-info.sub.js"></script>
<script src="/html/cross-origin-opener-policy/resources/fully-loaded.js"></script>
<body>
<script>
  const params = %s;
  const navHistory = params.navHistory;
  const avoidBackAndForth = params.avoidBackAndForth;
  const navigate = params.navigate;
  if (navHistory !== null) {
    fullyLoaded().then(() => {
      history.go(Number(navHistory));
    });
  } else if (navigate !== null && (history.length === 1 || !avoidBackAndForth)) {
    fullyLoaded().then(() => {
      self.location = navigate;
    });
  } else {
    let openerDOMAccessAllowed = false;
    try {
      openerDOMAccessAllowed = !!self.opener.document.URL;
    } catch(ex) {
    }
    // Handle the response from the frame, closing the popup once the
    // test completes.
    addEventListener("message", event => {
      if (event.data == "close") {
        close();
      }
    });
    iframe = document.createElement("iframe");
    iframe.onload = () => {
      const payload = { name: self.name, opener: !!self.opener, openerDOMAccess: openerDOMAccessAllowed };
      iframe.contentWindow.postMessage(payload, "*");
    };
    const channelName = params.channel;
    const responseToken = params.responseToken;
    const iframeToken = params.iframeToken;
    iframe.src = ` + "`${get_host_info().HTTPS_ORIGIN}/html/cross-origin-opener-policy/resources/postback.html` +\n" +
	"                 `?channel=${encodeURIComponent(channelName)}` +\n" +
	"                 `&responseToken=${responseToken}` +\n" +
	"                 `&iframeToken=${iframeToken}`;" + `
    document.body.appendChild(iframe);
  }
</script>
</body>
`
