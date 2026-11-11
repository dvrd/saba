// Independent RFC8441 and RFC6455 wire peer using only the Go standard library.
package main

import (
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

type frame struct {
	kind, flags byte
	id          uint32
	data        []byte
}

func write(c net.Conn, kind, flags byte, id uint32, data []byte) error {
	h := make([]byte, 9)
	h[0] = byte(len(data) >> 16)
	h[1] = byte(len(data) >> 8)
	h[2] = byte(len(data))
	h[3] = kind
	h[4] = flags
	binary.BigEndian.PutUint32(h[5:], id)
	if _, e := c.Write(h); e != nil {
		return e
	}
	_, e := c.Write(data)
	return e
}
func read(c net.Conn) (frame, error) {
	h := make([]byte, 9)
	if _, e := io.ReadFull(c, h); e != nil {
		return frame{}, e
	}
	n := int(h[0])<<16 | int(h[1])<<8 | int(h[2])
	if n > 1<<16 {
		return frame{}, fmt.Errorf("oversize frame")
	}
	f := frame{kind: h[3], flags: h[4], id: binary.BigEndian.Uint32(h[5:]) & 0x7fffffff, data: make([]byte, n)}
	_, e := io.ReadFull(c, f.data)
	return f, e
}
func lit(dst []byte, name, value string) []byte {
	return append(append(append(append(dst, 0, byte(len(name))), []byte(name)...), byte(len(value))), []byte(value)...)
}
func indexed(dst []byte, index byte, value string) []byte {
	return append(append(dst, index, byte(len(value))), []byte(value)...)
}
func connect(path string) []byte {
	b := indexed(nil, 2, "CONNECT")
	b = lit(b, ":protocol", "websocket")
	b = append(b, 0x87)
	b = indexed(b, 1, "synthetic.invalid")
	b = indexed(b, 4, path)
	b = lit(b, "sec-websocket-version", "13")
	b = lit(b, "sec-websocket-protocol", "chat.v2")
	return lit(b, "origin", "https://allowed.invalid")
}
func masked(op byte, data []byte) []byte {
	if len(data) > 125 {
		panic("short fixture only")
	}
	out := []byte{0x80 | op, 0x80 | byte(len(data)), 1, 2, 3, 4}
	for i, v := range data {
		out = append(out, v^out[2+i%4])
	}
	return out
}
func advance(c net.Conn, f frame) error {
	if f.kind == 4 && f.flags&1 == 0 {
		return write(c, 4, 1, 0, nil)
	}
	if f.kind == 6 && f.flags&1 == 0 {
		return write(c, 6, 1, 0, f.data)
	}
	if f.kind == 0 && len(f.data) > 0 {
		v := make([]byte, 4)
		binary.BigEndian.PutUint32(v, uint32(len(f.data)))
		if e := write(c, 8, 0, f.id, v); e != nil {
			return e
		}
		return write(c, 8, 0, 0, v)
	}
	return nil
}
func until(c net.Conn, id uint32, kind byte) (frame, error) {
	for i := 0; i < 100; i++ {
		f, e := read(c)
		if e != nil {
			return f, e
		}
		if e = advance(c, f); e != nil {
			return f, e
		}
		if f.kind == 3 {
			return f, fmt.Errorf("unexpected RST stream%d: %x", f.id, f.data)
		}
		if f.id == id && f.kind == kind {
			return f, nil
		}
	}
	return frame{}, fmt.Errorf("no frame")
}
func data(c net.Conn, id uint32, want []byte) error {
	got := []byte{}
	for len(got) < len(want) {
		f, e := until(c, id, 0)
		if e != nil {
			return e
		}
		got = append(got, f.data...)
	}
	if string(got) != string(want) {
		return fmt.Errorf("DATA mismatch got%x want%x", got, want)
	}
	return nil
}
func exchange(address string) error {
	c, e := tls.Dial("tcp", address, &tls.Config{InsecureSkipVerify: true, ServerName: "localhost", NextProtos: []string{"h2"}, MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13})
	if e != nil {
		return e
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(8 * time.Second))
	if c.ConnectionState().NegotiatedProtocol != "h2" {
		return fmt.Errorf("missing ALPN")
	}
	if _, e = c.Write([]byte("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")); e != nil {
		return e
	}
	if e = write(c, 4, 0, 0, []byte{0, 2, 0, 0, 0, 0}); e != nil {
		return e
	}
	settings, e := until(c, 0, 4)
	if e != nil {
		return e
	}
	enabled := false
	for at := 0; at+6 <= len(settings.data); at += 6 {
		if binary.BigEndian.Uint16(settings.data[at:]) == 8 && binary.BigEndian.Uint32(settings.data[at+2:]) == 1 {
			enabled = true
		}
	}
	if !enabled {
		return fmt.Errorf("missing SETTINGS_ENABLE_CONNECT_PROTOCOL")
	}
	if e = write(c, 1, 4, 1, connect("/socket")); e != nil {
		return e
	}
	response, e := until(c, 1, 1)
	if e != nil {
		return e
	}
	if response.flags&1 != 0 || len(response.data) == 0 || response.data[0] != 0x88 {
		return fmt.Errorf("CONNECT did not return open200: flags%d %x", response.flags, response.data)
	}
	// An idle WebSocket must not hold the ordinary request slot.
	normal := []byte{0x82, 0x87}
	normal = indexed(normal, 1, "synthetic.invalid")
	normal = indexed(normal, 4, "/health")
	if e = write(c, 1, 5, 3, normal); e != nil {
		return e
	}
	if e = data(c, 3, []byte("http-ok")); e != nil {
		return e
	}
	// Empty and padding-only DATA carry no WebSocket bytes or EOF.
	if e = write(c, 0, 0, 1, nil); e != nil {
		return e
	}
	if e = write(c, 0, 8, 1, []byte{3, 0, 0, 0}); e != nil {
		return e
	}
	if e = write(c, 0, 0, 1, masked(1, []byte("hello"))); e != nil {
		return e
	}
	if e = data(c, 1, []byte{0x81, 5, 'h', 'e', 'l', 'l', 'o'}); e != nil {
		return e
	}
	if e = write(c, 0, 0, 1, masked(9, []byte("P"))); e != nil {
		return e
	}
	if e = data(c, 1, []byte{0x8a, 1, 'P'}); e != nil {
		return e
	}
	if e = write(c, 0, 0, 1, masked(8, []byte{3, 232})); e != nil {
		return e
	}
	if e = data(c, 1, []byte{0x88, 2, 3, 232}); e != nil {
		return e
	}
	if e = write(c, 0, 1, 1, nil); e != nil {
		return e
	}
	// A reset is stream-local; the same connection remains usable.
	if e = write(c, 1, 4, 5, connect("/socket")); e != nil {
		return e
	}
	if _, e = until(c, 5, 1); e != nil {
		return e
	}
	if e = write(c, 3, 0, 5, []byte{0, 0, 0, 8}); e != nil {
		return e
	}
	if e = write(c, 1, 5, 7, normal); e != nil {
		return e
	}
	return data(c, 7, []byte("http-ok"))
}
func main() {
	if len(os.Args) != 2 {
		panic("peer host:port")
	}
	if e := exchange(os.Args[1]); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
	fmt.Println("OK independent-rfc8441")
}
