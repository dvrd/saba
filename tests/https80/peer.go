// Owned independent Go TLS/HTTP peer; no network endpoint outside loopback.
package main

import (
	"bufio"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

type splitConn struct{ net.Conn }

func (c splitConn) Read(p []byte) (int, error) {
	if len(p) > 7 {
		p = p[:7]
	}
	return c.Conn.Read(p)
}
func (c splitConn) Write(p []byte) (int, error) {
	total := 0
	for len(p) > 0 {
		n := len(p)
		if n > 7 {
			n = 7
		}
		w, e := c.Conn.Write(p[:n])
		total += w
		p = p[w:]
		if e != nil {
			return total, e
		}
		if w == 0 {
			return total, io.ErrNoProgress
		}
	}
	return total, nil
}
func require(ok bool, format string, args ...any) {
	if !ok {
		panic(fmt.Sprintf(format, args...))
	}
}
func main() {
	require(len(os.Args) == 4, "endpoint CA mode")
	endpoint, caFile, mode := os.Args[1], os.Args[2], os.Args[3]
	ca, e := os.ReadFile(caFile)
	require(e == nil, "CA: %v", e)
	roots := x509.NewCertPool()
	require(roots.AppendCertsFromPEM(ca), "CA PEM")
	if mode == "trust" {
		roots = x509.NewCertPool()
	}
	dial := func(fragment bool) (net.Conn, error) {
		raw, e := net.DialTimeout("tcp4", endpoint, 2*time.Second)
		if e != nil {
			return nil, e
		}
		raw.SetDeadline(time.Now().Add(20 * time.Second))
		if mode == "plain" {
			return raw, nil
		}
		if fragment {
			raw = splitConn{raw}
		}
		name := "synthetic.invalid"
		if mode == "hostname" {
			name = "wrong.invalid"
		}
		config := &tls.Config{MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13, RootCAs: roots, ServerName: name, NextProtos: []string{"http/1.1"}}
		if mode == "expired" {
			config.Time = func() time.Time { return time.Unix(2000000000, 0) }
		}
		if mode == "before" {
			config.Time = func() time.Time { return time.Unix(0, 0) }
		}
		conn := tls.Client(raw, config)
		if e = conn.Handshake(); e != nil {
			raw.Close()
			return nil, e
		}
		require(conn.ConnectionState().NegotiatedProtocol == "http/1.1", "ALPN %q", conn.ConnectionState().NegotiatedProtocol)
		return conn, nil
	}
	if mode == "hold-handshake" || mode == "timeout" {
		raw, e := net.DialTimeout("tcp4", endpoint, 2*time.Second)
		require(e == nil, "raw dial: %v", e)
		defer raw.Close()
		raw.SetDeadline(time.Now().Add(5 * time.Second))
		_, e = raw.Write([]byte{22, 3, 1, 0, 64, 1})
		require(e == nil, "partial ClientHello: %v", e)
		fmt.Println("HELD")
		started := time.Now()
		one := make([]byte, 1024)
		_, e = raw.Read(one)
		require(e != nil, "stalled handshake unexpectedly produced application data")
		if mode == "timeout" {
			require(time.Since(started) > 150*time.Millisecond && time.Since(started) < 3*time.Second, "handshake timeout duration %v", time.Since(started))
		}
		fmt.Println(`{"passed":true,"held":"handshake"}`)
		return
	}
	conn, e := dial(mode == "fragment")
	if mode == "trust" || mode == "hostname" || mode == "expired" || mode == "before" {
		require(e != nil, "negative peer unexpectedly trusted server")
		var unknown x509.UnknownAuthorityError
		var host x509.HostnameError
		var invalid x509.CertificateInvalidError
		switch mode {
		case "trust":
			require(errors.As(e, &unknown), "wrong trust cause: %v", e)
		case "hostname":
			require(errors.As(e, &host), "wrong hostname cause: %v", e)
		default:
			require(errors.As(e, &invalid) && invalid.Reason == x509.Expired, "wrong validity cause: %v", e)
		}
		json.NewEncoder(os.Stdout).Encode(map[string]any{"passed": true, "mode": mode, "typed_rejection": fmt.Sprintf("%T", e)})
		return
	}
	require(e == nil, "handshake: %v", e)
	defer conn.Close()
	reader := bufio.NewReader(conn)
	request := func(connection net.Conn, method, path, body string, close bool) {
		policy := "keep-alive"
		if close {
			policy = "close"
		}
		text := fmt.Sprintf("%s %s HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: %s\r\nContent-Length: %d\r\n\r\n%s", method, path, policy, len(body), body)
		_, e := io.WriteString(connection, text)
		require(e == nil, "request: %v", e)
	}
	response := func(r *bufio.Reader, method string, expected string) {
		res, e := http.ReadResponse(r, &http.Request{Method: method})
		require(e == nil, "HTTP response: %v", e)
		require(res.StatusCode == 200, "HTTP status %d", res.StatusCode)
		body, e := io.ReadAll(io.LimitReader(res.Body, 8*1024*1024+1))
		require(e == nil, "HTTP body: %v", e)
		res.Body.Close()
		require(string(body) == expected, "body mismatch len=%d expected=%d", len(body), len(expected))
	}
	if mode == "helpers" {
		_, e = io.WriteString(conn, "POST /echo HTTP/1.1\r\nHost: synthetic.invalid\r\nTransfer-Encoding: chunked\r\n\r\n4\r\npart\r\n4\r\ndone\r\n0\r\n\r\n")
		require(e == nil, "chunked request: %v", e)
		response(reader, "POST", "partdone")
		request(conn, "GET", "/stream", "", false)
		response(reader, "GET", "onetwo")
		request(conn, "GET", "/close", "", true)
		response(reader, "GET", "https80-ok\n")
		fmt.Println(`{"passed":true,"helpers":"chunked-request-and-response"}`)
		return
	}
	if mode == "deferred" || mode == "deferred-pipeline" {
		request(conn, "GET", "/deferred", "", false)
		if mode == "deferred-pipeline" {
			_, e = io.WriteString(conn, "GET /nex")
			require(e == nil, "prefetch %v", e)
		}
		fmt.Println("HELD")
		line, e := bufio.NewReader(os.Stdin).ReadString('\n')
		require(e == nil && strings.TrimSpace(line) == "release", "release %q %v", line, e)
		response(reader, "GET", "deferred-ready")
		time.Sleep(550 * time.Millisecond)
		if mode == "deferred-pipeline" {
			_, e = io.WriteString(conn, "t HTTP/1.1\r\nHost: synthetic.invalid\r\nConnection: close\r\n\r\n")
			require(e == nil, "complete prefetched request %v", e)
		} else {
			request(conn, "GET", "/close", "", true)
		}
		response(reader, "GET", "https80-ok\n")
		fmt.Println(`{"passed":true,"deferred":"ready-retarget-and-fresh-keepalive-budget"}`)
		return
	}
	if mode == "wss" || mode == "wss-stop" {
		mask := []byte{1, 2, 3, 4}
		frame := func(op byte, payload []byte) []byte {
			wire := []byte{0x80 | op, 0x80 | byte(len(payload))}
			wire = append(wire, mask...)
			for i, b := range payload {
				wire = append(wire, b^mask[i%4])
			}
			return wire
		}
		readFrame := func() (byte, []byte) {
			header := make([]byte, 2)
			_, e := io.ReadFull(reader, header)
			require(e == nil, "WSS frame header %v", e)
			require(header[0]&0x80 != 0 && header[1]&0x80 == 0 && header[1] < 126, "bounded unmasked WSS frame %v", header)
			payload := make([]byte, int(header[1]))
			_, e = io.ReadFull(reader, payload)
			require(e == nil, "WSS payload %v", e)
			return header[0] & 15, payload
		}
		text := "GET /__reload HTTP/1.1\r\nHost: synthetic.invalid\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
		coalesced := append([]byte(text), frame(9, []byte("coalesced"))...)
		_, e = conn.Write(coalesced)
		require(e == nil, "WSS upgrade %v", e)
		res, e := http.ReadResponse(reader, &http.Request{Method: "GET"})
		require(e == nil && res.StatusCode == 101, "WSS upgrade response %v", e)
		require(res.Header.Get("Sec-WebSocket-Accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "WebSocket accept")
		op, payload := readFrame()
		require(op == 10 && string(payload) == "coalesced", "coalesced masked ping/pong %d %q", op, payload)
		for _, b := range frame(9, []byte("fragmented")) {
			_, e = conn.Write([]byte{b})
			require(e == nil, "fragmented ping %v", e)
		}
		op, payload = readFrame()
		require(op == 10 && string(payload) == "fragmented", "fragmented masked ping/pong %d %q", op, payload)
		if mode == "wss-stop" {
			_, e = conn.Write([]byte{0x89, 0x83, 1})
			require(e == nil, "partial WSS frame %v", e)
		}
		fmt.Println("HELD")
		if mode == "wss" {
			op, payload = readFrame()
			require(op == 1 && string(payload) == "reload", "watcher reload %d %q", op, payload)
			op, payload = readFrame()
			require(op == 8 && len(payload) >= 2 && payload[0] == 3 && payload[1] == 232, "reload close1000 %d %v", op, payload)
		}
		one := make([]byte, 1)
		_, e = conn.Read(one)
		require(e != nil, "WSS not closed")
		fmt.Println(`{"passed":true,"wss":"coalesced-fragmented-pong-and-owned-close"}`)
		return
	}
	if mode == "backpressure" {
		request(conn, "GET", "/large", "", true)
		_, e = reader.Peek(1)
		require(e == nil, "large response started: %v", e)
		time.Sleep(150 * time.Millisecond)
		started := time.Now()
		cheap, e := dial(false)
		require(e == nil, "cheap TLS handshake while large output held: %v", e)
		request(cheap, "GET", "/fast", "", true)
		response(bufio.NewReader(cheap), "GET", "https80-ok\n")
		cheap.Close()
		elapsed := time.Since(started)
		require(elapsed < time.Second, "sole-worker cheap request blocked: %v", elapsed)
		time.Sleep(400 * time.Millisecond)
		res, e := http.ReadResponse(reader, &http.Request{Method: "GET"})
		require(e == nil && res.StatusCode == 200, "large HTTP: %v", e)
		require(res.ContentLength == 8*1024*1024, "large Content-Length %d", res.ContentLength)
		buffer := make([]byte, 8192)
		at := 0
		for {
			n, e := res.Body.Read(buffer)
			for i, v := range buffer[:n] {
				require(v == byte((at+i)%251), "large byte mismatch %d", at+i)
			}
			at += n
			if e == io.EOF {
				break
			}
			require(e == nil, "large read: %v", e)
		}
		require(at == 8*1024*1024, "large body %d", at)
		res.Body.Close()
		json.NewEncoder(os.Stdout).Encode(map[string]any{"passed": true, "mode": mode, "bytes": at, "cheap_milliseconds": elapsed.Milliseconds()})
		return
	}
	if mode == "hold-http" || mode == "drain-body" {
		_, e = io.WriteString(conn, "POST /echo HTTP/1.1\r\nHost: synthetic.invalid\r\nContent-Length: 8\r\n\r\npart")
		require(e == nil, "partial body %v", e)
		fmt.Println("HELD")
		if mode == "drain-body" {
			line, e := bufio.NewReader(os.Stdin).ReadString('\n')
			require(e == nil && strings.TrimSpace(line) == "release", "release %q %v", line, e)
			_, e = io.WriteString(conn, "done")
			require(e == nil, "complete body %v", e)
			response(reader, "POST", "partdone")
		}
		one := make([]byte, 1024)
		_, e = conn.Read(one)
		require(e != nil, "held request did not close")
		fmt.Println(`{"passed":true,"held":"http"}`)
		return
	}
	for _, path := range []string{"/fast", "/second"} {
		request(conn, "GET", path, "", false)
		response(reader, "GET", "https80-ok\n")
	}
	body := "fragmented-body"
	request(conn, "POST", "/echo", body, false)
	response(reader, "POST", body)
	request(conn, "GET", "/close", "", true)
	response(reader, "GET", "https80-ok\n")
	one := make([]byte, 1)
	n, e := conn.Read(one)
	require(n == 0 && e == io.EOF, "clean TLS/HTTP closure %d %v", n, e)
	json.NewEncoder(os.Stdout).Encode(map[string]any{"passed": true, "mode": mode, "requests": 4})
}
