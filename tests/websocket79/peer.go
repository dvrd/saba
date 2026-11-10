// Independent bounded RFC6455 peer for the owned Saba WS/WSS fixture.
package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

func require(ok bool, format string, args ...any) {
	if !ok {
		panic(fmt.Sprintf(format, args...))
	}
}

type frame struct {
	final   bool
	opcode  byte
	payload []byte
}

// Bound HTTP header reads so combined probes consume no application bytes.
type oneByteReader struct{ io.Reader }

func (r oneByteReader) Read(p []byte) (int, error) {
	if len(p) > 1 {
		p = p[:1]
	}
	return r.Reader.Read(p)
}

type websocket struct {
	conn   net.Conn
	reader *bufio.Reader
	limit  int
}

func encode(op byte, final, masked bool, payload []byte) []byte {
	first := op
	if final {
		first |= 0x80
	}
	wire := []byte{first, 0}
	mask := byte(0)
	if masked {
		mask = 0x80
	}
	switch {
	case len(payload) < 126:
		wire[1] = mask | byte(len(payload))
	case len(payload) <= 65535:
		wire[1] = mask | 126
		wire = binary.BigEndian.AppendUint16(wire, uint16(len(payload)))
	default:
		wire[1] = mask | 127
		wire = binary.BigEndian.AppendUint64(wire, uint64(len(payload)))
	}
	key := []byte{1, 2, 3, 4}
	if masked {
		wire = append(wire, key...)
	}
	for i, b := range payload {
		if masked {
			b ^= key[i%4]
		}
		wire = append(wire, b)
	}
	return wire
}
func (w *websocket) write(op byte, final bool, payload []byte) {
	_, e := w.conn.Write(encode(op, final, true, payload))
	require(e == nil, "write frame %v", e)
}
func (w *websocket) read() frame {
	header := make([]byte, 2)
	_, e := io.ReadFull(w.reader, header)
	require(e == nil, "read frame header %v", e)
	require(header[0]&0x70 == 0 && header[1]&0x80 == 0, "unexpected server RSV/masking %v", header)
	length := uint64(header[1] & 127)
	if length == 126 {
		b := make([]byte, 2)
		_, e = io.ReadFull(w.reader, b)
		require(e == nil, "16bit length %v", e)
		length = uint64(binary.BigEndian.Uint16(b))
		require(length >= 126, "nonminimal server length")
	}
	if length == 127 {
		b := make([]byte, 8)
		_, e = io.ReadFull(w.reader, b)
		require(e == nil, "64bit length %v", e)
		length = binary.BigEndian.Uint64(b)
		require(length > 65535, "nonminimal server length")
	}
	require(length <= uint64(w.limit), "server frame exceeds configured limit %d>%d", length, w.limit)
	payload := make([]byte, int(length))
	_, e = io.ReadFull(w.reader, payload)
	require(e == nil, "read frame payload %v", e)
	return frame{header[0]&0x80 != 0, header[0] & 15, payload}
}
func (w *websocket) message(op byte, expected []byte) {
	var body []byte
	first := true
	for {
		f := w.read()
		if first {
			require(f.opcode == op, "first message opcode %d wanted%d", f.opcode, op)
			first = false
		} else {
			require(f.opcode == 0, "continuation opcode%d", f.opcode)
		}
		require(len(body)+len(f.payload) <= 8*1024*1024, "bounded received message")
		body = append(body, f.payload...)
		if f.final {
			break
		}
	}
	require(bytes.Equal(body, expected), "message payload mismatch got%d wanted%d", len(body), len(expected))
}
func (w *websocket) pong(expected []byte) {
	f := w.read()
	require(f.final && f.opcode == 10 && bytes.Equal(f.payload, expected), "pong mismatch op%d data%q", f.opcode, f.payload)
}
func (w *websocket) close(code uint16) {
	payload := binary.BigEndian.AppendUint16(nil, code)
	payload = append(payload, []byte("bye")...)
	w.write(8, true, payload)
	f := w.read()
	require(f.final && f.opcode == 8 && bytes.Equal(f.payload, payload), "close echo %d %v", f.opcode, f.payload)
	one := make([]byte, 1)
	n, e := w.conn.Read(one)
	require(n == 0 && e == io.EOF, "ordered transport close %d %v", n, e)
	w.conn.Close()
}
func main() {
	require(len(os.Args) == 5, "endpoint CA mode tls")
	endpoint, ca, mode := os.Args[1], os.Args[2], os.Args[3]
	secure, e := strconv.ParseBool(os.Args[4])
	require(e == nil, "tls selector")
	require(strings.HasPrefix(endpoint, "127.0.0.1:"), "owned loopback only")
	roots := x509.NewCertPool()
	cert, e := os.ReadFile(ca)
	require(e == nil && roots.AppendCertsFromPEM(cert), "public test CA")
	dialTCP := func() net.Conn {
		raw, e := net.DialTimeout("tcp4", endpoint, 2*time.Second)
		require(e == nil, "loopback dial %v", e)
		raw.SetDeadline(time.Now().Add(30 * time.Second))
		if !secure {
			return raw
		}
		conn := tls.Client(raw, &tls.Config{MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13, RootCAs: roots, ServerName: "synthetic.invalid", NextProtos: []string{"http/1.1"}})
		require(conn.Handshake() == nil, "verified WSS handshake")
		require(conn.ConnectionState().NegotiatedProtocol == "http/1.1", "WSS ALPN")
		return conn
	}
	upgrade := func(path, origin, protocols, auth string, extra []byte) (*websocket, *http.Response) {
		conn := dialTCP()
		reader := bufio.NewReader(conn)
		if strings.HasPrefix(mode, "combined-") {
			reader = bufio.NewReader(oneByteReader{conn})
		}
		text := "GET " + path + " HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
		if origin != "" {
			text += "Origin: " + origin + "\r\n"
		}
		if protocols != "" {
			text += "Sec-WebSocket-Protocol: " + protocols + "\r\n"
		}
		if auth != "" {
			text += "X-Test-Auth: " + auth + "\r\n"
		}
		text += "\r\n"
		_, e := conn.Write(append([]byte(text), extra...))
		require(e == nil, "upgrade request %v", e)
		response, e := http.ReadResponse(reader, &http.Request{Method: "GET"})
		require(e == nil, "upgrade response %v", e)
		w := &websocket{conn, reader, 1024}
		if strings.HasPrefix(path, "/slow") {
			w.limit = 65536
		}
		return w, response
	}
	normal := func(path string, extra []byte) *websocket {
		w, res := upgrade(path, "https://allowed.invalid", "chat.v1, chat.v2", "allow", extra)
		require(res.StatusCode == 101, "upgrade status%d", res.StatusCode)
		require(res.Header.Get("Sec-WebSocket-Accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "WebSocket challenge response")
		require(res.Header.Get("Sec-WebSocket-Protocol") == "chat.v2", "explicit subprotocol selection%q", res.Header.Get("Sec-WebSocket-Protocol"))
		return w
	}
	result := map[string]any{"passed": true, "mode": mode, "secure": secure}
	if mode == "policy" {
		cases := []struct {
			path, origin, protocols, auth string
			status                        int
		}{
			{"/ws", "https://wrong.invalid", "chat.v2", "allow", 403},
			{"/ws", "", "chat.v2", "allow", 403},
			{"/ws", "https://allowed.invalid", "chat.v2", "deny", 403},
			{"/ws", "https://allowed.invalid", "chat.v2", "", 403},
			{"/ws", "https://allowed.invalid", "bad protocol", "allow", 400},
			{"/ws", "https://allowed.invalid", "chat.v2, chat.v2", "allow", 400},
			{"/ws", "https://allowed.invalid", "other", "allow", 400},
			{"/not-websocket", "https://allowed.invalid", "chat.v2", "allow", 404},
		}
		for _, c := range cases {
			w, res := upgrade(c.path, c.origin, c.protocols, c.auth, nil)
			require(res.StatusCode == c.status, "policy status got%d wanted%d path%s protocols%q", res.StatusCode, c.status, c.path, c.protocols)
			body, e := io.ReadAll(io.LimitReader(res.Body, 4097))
			require(e == nil && len(body) <= 4096, "bounded rejection")
			res.Body.Close()
			w.conn.Close()
		}
		w := normal("/ws", nil)
		w.close(1000)
		result["rejections"] = len(cases)
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if mode == "invalid" {
		cases := []struct {
			name string
			wire []byte
			code uint16
		}{
			{"unmasked", encode(1, true, false, []byte("x")), 1002},
			{"rsv", []byte{0xc1, 0x80, 1, 2, 3, 4}, 1002},
			{"opcode", []byte{0x83, 0x80, 1, 2, 3, 4}, 1002},
			{"control-fragment", encode(9, false, true, []byte("x")), 1002},
			{"control-size", encode(9, true, true, make([]byte, 126)), 1002},
			{"nonminimal-length", []byte{0x81, 0xfe, 0, 1, 1, 2, 3, 4, 'x' ^ 1}, 1002},
			{"bad-utf8", encode(1, true, true, []byte{0xff}), 1007},
			{"unexpected-continuation", encode(0, true, true, []byte("x")), 1002},
			{"close-one-byte", encode(8, true, true, []byte{1}), 1002},
			{"close-bad-utf8", encode(8, true, true, []byte{3, 232, 0xff}), 1007},
			{"frame-oversize", encode(2, true, true, make([]byte, 1025)), 1009},
		}
		for _, c := range cases {
			w := normal("/ws", nil)
			_, e = w.conn.Write(c.wire)
			require(e == nil, "invalid write %s %v", c.name, e)
			f := w.read()
			require(f.opcode == 8 && len(f.payload) >= 2 && binary.BigEndian.Uint16(f.payload[:2]) == c.code, "exact invalid close%s got%d %v wanted%d", c.name, f.opcode, f.payload, c.code)
			w.conn.Close()
		}
		w := normal("/ws", nil)
		w.write(2, false, make([]byte, 1024))
		w.write(0, false, make([]byte, 1024))
		w.write(0, true, []byte{1})
		f := w.read()
		require(f.opcode == 8 && len(f.payload) >= 2 && binary.BigEndian.Uint16(f.payload[:2]) == 1009, "fragmented message bound%v", f.payload)
		w.conn.Close()
		w = normal("/ws", nil)
		w.write(2, false, []byte{1})
		for count := 0; count < 3; count++ {
			w.write(0, false, []byte{1})
		}
		w.write(0, true, []byte{1})
		f = w.read()
		require(f.opcode == 8 && len(f.payload) >= 2 && binary.BigEndian.Uint16(f.payload[:2]) == 1009, "fragment-count limit %v", f.payload)
		w.conn.Close()
		result["invalid_frames"] = len(cases) + 2
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if mode == "combined-frame" || mode == "combined-fragment" {
		prefix := []byte{0x81}
		if mode == "combined-fragment" {
			prefix = encode(1, false, true, []byte{'x'})
		}
		w := normal("/"+mode, prefix)
		fmt.Println("HELD")
		line, e := bufio.NewReader(os.Stdin).ReadString('\n')
		require(e == nil && strings.TrimSpace(line) == "release", "combined release %q %v", line, e)
		w.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		count, readError := io.Copy(io.Discard, io.LimitReader(w.conn, 9*1024*1024))
		require(count < 8*1024*1024, "held reader received whole pending message %d", count)
		w.conn.Close()
		result["drained_transport_prefix_bytes"] = count
		result["read_after_owner_retired"] = true
		if readError != nil {
			result["unclean_transport_error"] = readError.Error()
		}
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if mode == "empty-close" {
		w := normal("/ws", nil)
		w.write(8, true, nil)
		f := w.read()
		require(f.final && f.opcode == 8 && len(f.payload) == 0, "empty close echo %d %v", f.opcode, f.payload)
		one := make([]byte, 1)
		n, e := w.conn.Read(one)
		require(n == 0 && e == io.EOF, "empty clean close %d %v", n, e)
		w.conn.Close()
		result["empty_close_clean"] = true
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if mode == "application-noack" {
		w := normal("/ws", nil)
		started := time.Now()
		w.write(1, true, []byte("application-noack"))
		f := w.read()
		require(f.opcode == 8 && bytes.Equal(f.payload, append([]byte{3, 232}, []byte("no-ack")...)), "no-ack application close %d %q", f.opcode, f.payload)
		one := make([]byte, 1)
		n, e := w.conn.Read(one)
		elapsed := time.Since(started)
		require(n == 0 && e != nil, "unacknowledged close did not terminate %d %v", n, e)
		require(elapsed >= 100*time.Millisecond && elapsed < 2*time.Second, "bounded close cutoff %v", elapsed)
		w.conn.Close()
		result["no_peer_ack"] = true
		result["close_milliseconds"] = elapsed.Milliseconds()
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if mode == "application-close" {
		w := normal("/ws", nil)
		w.write(1, true, []byte("application-close"))
		w.message(1, []byte("before-close-1"))
		w.message(1, []byte("before-close-2"))
		f := w.read()
		require(f.opcode == 8 && bytes.Equal(f.payload, append([]byte{3, 232}, []byte("app-done")...)), "application close drained data then close %d %q", f.opcode, f.payload)
		w.write(8, true, f.payload)
		one := make([]byte, 1)
		n, e := w.conn.Read(one)
		require(n == 0 && e == io.EOF, "application close transport %d %v", n, e)
		w.conn.Close()
		result["drained_messages"] = 2
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if mode == "peer-close-discard" {
		w := normal("/slow", nil)
		w.write(1, true, []byte("peer-close-discard"))
		f := w.read()
		require(f.opcode == 2 && !f.final, "first large frame %d %v", f.opcode, f.final)
		total := len(f.payload)
		for i, b := range f.payload {
			require(b == byte(i%251), "first large byte %d", i)
		}
		w.write(8, true, []byte{3, 232, 'b', 'y', 'e'})
		closed := false
		for count := 0; count < 130; count++ {
			f = w.read()
			if f.opcode == 8 {
				require(bytes.Equal(f.payload, []byte{3, 232, 'b', 'y', 'e'}), "peer close echo %v", f.payload)
				closed = true
				break
			}
			require(f.opcode == 0 && !f.final, "unsent final message or forbidden tail delivered opcode%d fin%v", f.opcode, f.final)
			for i, b := range f.payload {
				require(b == byte((total+i)%251), "partial large byte %d", total+i)
			}
			total += len(f.payload)
		}
		require(closed && total < 8*1024*1024, "peer-close must discard unsent message tail, got%d closed%v", total, closed)
		w.conn.Close()
		result["delivered_prefix_bytes"] = total
		result["unsent_tail_discarded"] = true
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if mode == "queue" {
		w := normal("/ws", nil)
		w.write(1, true, []byte("queue-count"))
		w.message(1, []byte("count-1"))
		w.message(1, []byte("count-2"))
		w.write(9, true, []byte("after-count"))
		w.pong([]byte("after-count"))
		w.close(1000)
		w = normal("/queue-bytes", nil)
		w.write(1, true, []byte("queue-bytes"))
		w.message(2, bytes.Repeat([]byte{'A'}, 1024))
		w.message(2, bytes.Repeat([]byte{'C'}, 512))
		w.write(9, true, []byte("after-bytes"))
		w.pong([]byte("after-bytes"))
		w.close(1000)
		w = normal("/ws", nil)
		w.write(1, true, []byte("oversized-output"))
		w.message(1, []byte("output-rejected"))
		w.close(1000)
		result["queue_boundaries"] = 3
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if mode == "slow" || mode == "hold" {
		var parked []*websocket
		if mode == "slow" {
			large := normal("/slow", nil)
			large.write(1, true, []byte("slow"))
			_, e = large.reader.Peek(1)
			require(e == nil, "large output started%v", e)
			started := time.Now()
			for i := 0; i < 24; i++ {
				parked = append(parked, normal("/ws", nil))
			}
			cheap := dialTCP()
			_, e = io.WriteString(cheap, "GET /fast HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: close\r\n\r\n")
			require(e == nil, "cheap HTTPwrite%v", e)
			res, e := http.ReadResponse(bufio.NewReader(cheap), &http.Request{Method: "GET"})
			require(e == nil && res.StatusCode == 200, "cheap HTTPresponse%v", e)
			body, e := io.ReadAll(io.LimitReader(res.Body, 128))
			require(e == nil && string(body) == "websocket79-ok\n", "cheap HTTPbody%q", body)
			cheap.Close()
			elapsed := time.Since(started)
			require(elapsed < 8*time.Second, "oneworker progress blocked%v", elapsed)
			fmt.Println("HELD")
			line, releaseError := bufio.NewReader(os.Stdin).ReadString('\n')
			require(releaseError == nil && strings.TrimSpace(line) == "release", "slow peer release %q %v", line, releaseError)
			expected := make([]byte, 8*1024*1024)
			for i := range expected {
				expected[i] = byte(i % 251)
			}
			large.message(2, expected)
			large.close(1000)
			result["bytes"] = len(expected)
			result["parked"] = len(parked)
			result["progress_milliseconds"] = elapsed.Milliseconds()
		} else {
			for i := 0; i < 24; i++ {
				parked = append(parked, normal("/ws", nil))
			}
			_, e = parked[0].conn.Write([]byte{0x81, 0x84, 1})
			require(e == nil, "held partial frame%v", e)
			fmt.Println("HELD")
			for _, w := range parked {
				one := make([]byte, 256)
				_, e = w.conn.Read(one)
				if e == nil {
					_, e = w.conn.Read(one)
				}
				require(e != nil, "shutdown did not close parked session")
			}
		}
		for _, w := range parked {
			w.conn.Close()
		}
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	w := normal("/ws", encode(9, true, true, []byte("coalesced")))
	defer w.conn.Close()
	w.pong([]byte("coalesced"))
	for _, value := range encode(9, true, true, []byte("fragmented")) {
		_, e = w.conn.Write([]byte{value})
		require(e == nil, "byte-fragmented ping%v", e)
	}
	w.pong([]byte("fragmented"))
	w.write(1, false, []byte("hello "))
	w.write(9, true, []byte("interleave"))
	w.write(0, false, []byte{0xe2})
	w.write(0, false, []byte{0x82})
	w.write(0, true, []byte{0xac})
	w.pong([]byte("interleave"))
	w.message(1, []byte("hello €"))
	exact := bytes.Repeat([]byte{'E'}, 2048)
	w.write(2, false, exact[:1024])
	w.write(0, true, exact[1024:])
	w.message(2, exact)
	w.write(1, true, nil)
	w.message(1, nil)
	w.write(2, true, []byte{0, 255, 128})
	w.message(2, []byte{0, 255, 128})
	control := bytes.Repeat([]byte{'P'}, 125)
	w.write(9, true, control)
	w.pong(control)
	w.close(1000)
	result["exact_message_limit"] = len(exact)
	json.NewEncoder(os.Stdout).Encode(result)
}
