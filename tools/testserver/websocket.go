package main

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// A hand-written RFC 6455 server (the standard library has none) for the WebSocket tests.
//
//	/ws/echo[?frag=N]   echoes text and binary messages with the same opcode (in frames of N bytes with frag).
//	                    Offers "chat.v2" or "chat" when the client asks for one. Sets the cookie wscookie=handshake.
//	                    Text commands instead of an echo:
//	                      "header:<Name>"       the value of that handshake request header
//	                      "ping:<payload>"      the server pings; once the pong is back it sends "pong:<payload>"
//	                      "close:<code>:<why>"  the server starts the closing handshake with that code and reason
//	                      "badutf8"             a text frame that is not UTF-8
//	                      "big:<n>"             a text message of n bytes, in frames of 64 KiB
//	/ws/drop            after the handshake: one text "bye", then the TCP connection is cut without a close frame
//	/ws/bad-proto       selects a subprotocol nobody offered
//	/ws/deflate         answers with Sec-WebSocket-Extensions: permessage-deflate
//	/ws/forbidden       answers 403 instead of 101
//	/ws/slow-handshake  waits 3 s before answering
//	/ws/hits            handshakes accepted so far
const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
const wsMaxFrame = 64 << 20

var wsHandshakes int64

const (
	opCont   = 0x0
	opText   = 0x1
	opBinary = 0x2
	opClose  = 0x8
	opPing   = 0x9
	opPong   = 0xA
)

func headerHasToken(h http.Header, name, token string) bool {
	for _, v := range h.Values(name) {
		for _, t := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(t), token) {
				return true
			}
		}
	}
	return false
}

// Validates the upgrade request and hijacks the connection after writing the 101 with `extra` header lines.
func wsUpgrade(w http.ResponseWriter, r *http.Request, extra []string) (net.Conn, *bufio.ReadWriter, bool) {
	key := r.Header.Get("Sec-WebSocket-Key")
	if r.Method != http.MethodGet || !headerHasToken(r.Header, "Connection", "upgrade") || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") ||
		r.Header.Get("Sec-WebSocket-Version") != "13" || key == "" {
		http.Error(w, "not a WebSocket handshake", http.StatusBadRequest)
		return nil, nil, false
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "cannot hijack (HTTP/2?)", http.StatusInternalServerError)
		return nil, nil, false
	}
	conn, brw, err := hj.Hijack()
	if err != nil {
		return nil, nil, false
	}
	sum := sha1.Sum([]byte(key + wsGUID))
	var sb strings.Builder
	sb.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n")
	sb.WriteString("Sec-WebSocket-Accept: " + base64.StdEncoding.EncodeToString(sum[:]) + "\r\n")
	for _, e := range extra {
		sb.WriteString(e + "\r\n")
	}
	sb.WriteString("\r\n")
	brw.WriteString(sb.String())
	brw.Flush()
	atomic.AddInt64(&wsHandshakes, 1)
	return conn, brw, true
}

type wsFrame struct {
	fin     bool
	op      byte
	payload []byte
}

func wsRead(br *bufio.Reader) (wsFrame, error) {
	var f wsFrame
	var h [2]byte
	if _, err := io.ReadFull(br, h[:]); err != nil {
		return f, err
	}
	f.fin = h[0]&0x80 != 0
	if h[0]&0x70 != 0 {
		return f, errors.New("reserved bits set without an extension")
	}
	f.op = h[0] & 0x0F
	masked := h[1]&0x80 != 0
	n := uint64(h[1] & 0x7F)
	switch n {
	case 126:
		var b [2]byte
		if _, err := io.ReadFull(br, b[:]); err != nil {
			return f, err
		}
		n = uint64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err := io.ReadFull(br, b[:]); err != nil {
			return f, err
		}
		n = binary.BigEndian.Uint64(b[:])
	}
	if n > wsMaxFrame {
		return f, errors.New("frame too large")
	}
	if !masked {
		return f, errors.New("client frames must be masked")
	}
	var mask [4]byte
	if _, err := io.ReadFull(br, mask[:]); err != nil {
		return f, err
	}
	f.payload = make([]byte, n)
	if _, err := io.ReadFull(br, f.payload); err != nil {
		return f, err
	}
	for i := range f.payload {
		f.payload[i] ^= mask[i&3]
	}
	return f, nil
}

func wsWrite(bw *bufio.Writer, fin bool, op byte, payload []byte) error {
	b0 := op
	if fin {
		b0 |= 0x80
	}
	hdr := []byte{b0}
	switch n := len(payload); {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n <= 0xFFFF:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		var b [8]byte
		binary.BigEndian.PutUint64(b[:], uint64(n))
		hdr = append(append(hdr, 127), b[:]...)
	}
	if _, err := bw.Write(hdr); err != nil {
		return err
	}
	if _, err := bw.Write(payload); err != nil {
		return err
	}
	return bw.Flush()
}

// Sends one message, split in frames of `frag` bytes (0 = one frame).
func wsSendMessage(bw *bufio.Writer, op byte, data []byte, frag int) error {
	if frag <= 0 || len(data) <= frag {
		return wsWrite(bw, true, op, data)
	}
	for off := 0; off < len(data); off += frag {
		end := off + frag
		if end > len(data) {
			end = len(data)
		}
		o := byte(opCont)
		if off == 0 {
			o = op
		}
		if err := wsWrite(bw, end == len(data), o, data[off:end]); err != nil {
			return err
		}
	}
	return nil
}

func closePayload(code int, reason string) []byte {
	b := make([]byte, 2, 2+len(reason))
	binary.BigEndian.PutUint16(b, uint16(code))
	return append(b, reason...)
}

func pickProtocol(r *http.Request) string {
	offered := []string{}
	for _, v := range r.Header.Values("Sec-WebSocket-Protocol") {
		for _, p := range strings.Split(v, ",") {
			offered = append(offered, strings.TrimSpace(p))
		}
	}
	for _, want := range []string{"chat.v2", "chat"} {
		for _, o := range offered {
			if o == want {
				return want
			}
		}
	}
	return ""
}

// The echo session: reads messages (reassembling fragments, answering pings, honouring close) until the end.
func wsEcho(conn net.Conn, brw *bufio.ReadWriter, r *http.Request, frag int) {
	defer conn.Close()
	br, bw := brw.Reader, brw.Writer
	var msg []byte
	var msgOp byte
	pending := "" // payload of the ping we sent, waiting for its pong
	for {
		conn.SetReadDeadline(time.Now().Add(2 * time.Minute))
		f, err := wsRead(br)
		if err != nil {
			return
		}
		switch f.op {
		case opPing:
			wsWrite(bw, true, opPong, f.payload)
			continue
		case opPong:
			if pending != "" && string(f.payload) == pending {
				wsWrite(bw, true, opText, []byte("pong:"+pending))
				pending = ""
			}
			continue
		case opClose:
			// echo the code (an empty close is answered with an empty close), then end the TCP connection
			if len(f.payload) >= 2 {
				wsWrite(bw, true, opClose, f.payload[:2])
			} else {
				wsWrite(bw, true, opClose, nil)
			}
			return
		case opText, opBinary:
			msg, msgOp = append(msg[:0], f.payload...), f.op
		case opCont:
			msg = append(msg, f.payload...)
		default:
			wsWrite(bw, true, opClose, closePayload(1002, "unknown opcode"))
			return
		}
		if !f.fin {
			continue
		}
		data := msg
		if msgOp == opText {
			s := string(data)
			switch {
			case strings.HasPrefix(s, "header:"):
				wsWrite(bw, true, opText, []byte(r.Header.Get(strings.TrimPrefix(s, "header:"))))
				continue
			case strings.HasPrefix(s, "ping:"):
				pending = strings.TrimPrefix(s, "ping:")
				wsWrite(bw, true, opPing, []byte(pending))
				continue
			case strings.HasPrefix(s, "close:"):
				parts := strings.SplitN(s, ":", 3)
				code, _ := strconv.Atoi(parts[1])
				reason := ""
				if len(parts) == 3 {
					reason = parts[2]
				}
				wsWrite(bw, true, opClose, closePayload(code, reason))
				// wait for the client's answer, then cut
				conn.SetReadDeadline(time.Now().Add(5 * time.Second))
				for {
					g, err := wsRead(br)
					if err != nil || g.op == opClose {
						return
					}
				}
			case s == "badutf8":
				wsWrite(bw, true, opText, []byte{0xC3, 0x28, 0xFF})
				continue
			case strings.HasPrefix(s, "big:"):
				n, _ := strconv.Atoi(strings.TrimPrefix(s, "big:"))
				b := []byte(strings.Repeat("x", n))
				wsSendMessage(bw, opText, b, 64<<10)
				continue
			}
		}
		if err := wsSendMessage(bw, msgOp, data, frag); err != nil {
			return
		}
	}
}

func registerWebSocketHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/ws/echo", func(w http.ResponseWriter, r *http.Request) {
		extra := []string{"Set-Cookie: wscookie=handshake; Path=/"}
		if p := pickProtocol(r); p != "" {
			extra = append(extra, "Sec-WebSocket-Protocol: "+p)
		}
		conn, brw, ok := wsUpgrade(w, r, extra)
		if !ok {
			return
		}
		frag, _ := strconv.Atoi(r.URL.Query().Get("frag"))
		wsEcho(conn, brw, r, frag)
	})
	mux.HandleFunc("/ws/drop", func(w http.ResponseWriter, r *http.Request) {
		conn, brw, ok := wsUpgrade(w, r, nil)
		if !ok {
			return
		}
		wsWrite(brw.Writer, true, opText, []byte("bye"))
		time.Sleep(100 * time.Millisecond)
		if tc, ok := conn.(*net.TCPConn); ok {
			tc.SetLinger(0) // RST: an abrupt end, not a FIN after a close frame
		}
		conn.Close()
	})
	mux.HandleFunc("/ws/bad-proto", func(w http.ResponseWriter, r *http.Request) {
		conn, brw, ok := wsUpgrade(w, r, []string{"Sec-WebSocket-Protocol: nobody-asked"})
		if ok {
			wsEcho(conn, brw, r, 0)
		}
	})
	mux.HandleFunc("/ws/deflate", func(w http.ResponseWriter, r *http.Request) {
		conn, brw, ok := wsUpgrade(w, r, []string{"Sec-WebSocket-Extensions: permessage-deflate"})
		if ok {
			wsEcho(conn, brw, r, 0)
		}
	})
	mux.HandleFunc("/ws/forbidden", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "no", http.StatusForbidden)
	})
	mux.HandleFunc("/ws/slow-handshake", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
			return
		case <-time.After(3 * time.Second):
		}
		conn, brw, ok := wsUpgrade(w, r, nil)
		if ok {
			wsEcho(conn, brw, r, 0)
		}
	})
	mux.HandleFunc("/ws/hits", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%d", atomic.LoadInt64(&wsHandshakes))
	})
}
