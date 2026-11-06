// Gates: what a test holds back until it says so, with no clock in it. A file asked for with ?gate=K (handlers call gateWait) is answered once K is open:
//
//	/gate/open?name=K   lets go of what waits for K, now and from now on
package testserver

import (
	"fmt"
	"net/http"
	"sync"
)

var gates = struct {
	sync.Mutex
	open map[string]chan struct{}
}{open: map[string]chan struct{}{}}

func gateOf(name string) chan struct{} {
	gates.Lock()
	defer gates.Unlock()
	g, ok := gates.open[name]
	if !ok {
		g = make(chan struct{})
		gates.open[name] = g
	}
	return g
}

// gateWait holds a request until its gate opens, if it names one; false: the client went away.
func gateWait(r *http.Request) bool {
	name := r.URL.Query().Get("gate")
	if name == "" {
		return true
	}
	select {
	case <-gateOf(name):
		return true
	case <-r.Context().Done():
		return false
	}
}

func registerGateHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/gate/open", func(w http.ResponseWriter, r *http.Request) {
		g := gateOf(r.URL.Query().Get("name"))
		gates.Lock()
		select {
		case <-g:
		default:
			close(g)
		}
		gates.Unlock()
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fmt.Fprint(w, "open")
	})
}
