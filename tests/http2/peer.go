// Local loopback peer for the Saba h2 adapter. No module download.
package main

import (
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"time"
)

func main() {
	if len(os.Args) != 3 {
		fatal("usage: peer <mode> <host:port>")
	}
	mode, address := os.Args[1], os.Args[2]
	var err error
	switch mode {
	case "success":
		err = httpExchange(address, []string{"h2"}, true)
	case "http1":
		err = httpExchange(address, []string{"http/1.1"}, false)
	case "noalpn":
		err = rawHTTP1(address)
	case "malformed":
		err = malformed(address)
	case "stall":
		err = stall(address)
	default:
		err = fmt.Errorf("unknown mode %s", mode)
	}
	if err != nil {
		fatal(err.Error())
	}
	fmt.Println("OK", mode)
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}

func dialTLS(address string, next []string) (*tls.Conn, error) {
	raw, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return nil, err
	}
	conn := tls.Client(raw, &tls.Config{
		InsecureSkipVerify: true,
		ServerName:         "fixture.invalid",
		NextProtos:         next,
		MinVersion:         tls.VersionTLS13,
		MaxVersion:         tls.VersionTLS13,
	})
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	if err = conn.Handshake(); err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

func httpExchange(address string, next []string, h2 bool) error {
	conn, err := dialTLS(address, next)
	if err != nil {
		return err
	}
	negotiated := conn.ConnectionState().NegotiatedProtocol
	conn.Close()
	want := "h2"
	if !h2 {
		want = "http/1.1"
	}
	if negotiated != want {
		return fmt.Errorf("negotiated %q", negotiated)
	}
	transport := &http.Transport{
		ForceAttemptHTTP2:  h2,
		DisableCompression: true,
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true,
			ServerName:         "fixture.invalid",
			NextProtos:         next,
			MinVersion:         tls.VersionTLS13,
			MaxVersion:         tls.VersionTLS13,
		},
		DialTLS: func(network, addr string) (net.Conn, error) {
			return dialTLS(address, next)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	base := "https://fixture.invalid"
	if err = one(client, base+"/echo"); err != nil {
		return err
	}
	return post(client, base+"/echo")
}

func one(client *http.Client, url string) error {
	response, err := client.Get(url)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return err
	}
	if response.StatusCode != 200 || string(body) != "ok" || response.Proto == "" {
		return fmt.Errorf("GET %s %q %q", response.Proto, response.Status, body)
	}
	return nil
}

func post(client *http.Client, url string) error {
	response, err := client.Post(url, "text/plain", io.NopCloser(bytesReader("ping")))
	if err != nil {
		return err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return err
	}
	if response.StatusCode != 200 || string(body) != "ping" {
		return fmt.Errorf("POST %s %q %q", response.Proto, response.Status, body)
	}
	return nil
}

type bytesReader string

func (b bytesReader) Read(p []byte) (int, error) {
	if len(b) == 0 {
		return 0, io.EOF
	}
	n := copy(p, b)
	return n, io.EOF
}

func rawHTTP1(address string) error {
	conn, err := dialTLS(address, nil)
	if err != nil {
		return err
	}
	defer conn.Close()
	if conn.ConnectionState().NegotiatedProtocol != "" {
		return fmt.Errorf("absent ALPN negotiated %q", conn.ConnectionState().NegotiatedProtocol)
	}
	_, err = io.WriteString(conn, "GET /echo HTTP/1.1\r\nHost: fixture.invalid\r\nConnection: close\r\n\r\n")
	if err != nil {
		return err
	}
	buffer := make([]byte, 1024)
	n, err := conn.Read(buffer)
	if n == 0 && err != nil {
		return err
	}
	text := string(buffer[:n])
	if len(text) < 12 || text[:12] != "HTTP/1.1 200" {
		return fmt.Errorf("noalpn response %q", text)
	}
	return nil
}

func malformed(address string) error {
	conn, err := dialTLS(address, []string{"h2"})
	if err != nil {
		return err
	}
	defer conn.Close()
	if conn.ConnectionState().NegotiatedProtocol != "h2" {
		return fmt.Errorf("malformed negotiated %q", conn.ConnectionState().NegotiatedProtocol)
	}
	preface := "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
	// SETTINGS ACK with a one-byte payload is a connection error.
	frame := []byte{0, 0, 1, 4, 1, 0, 0, 0, 0, 0}
	if _, err = io.WriteString(conn, preface); err != nil {
		return err
	}
	if _, err = conn.Write(frame); err != nil {
		return err
	}
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	sawGoaway := false
	err = readFrames(conn, func(kind, flags byte, stream uint32, payload []byte) bool {
		if kind == 7 {
			sawGoaway = true
			return true
		}
		return false
	})
	if sawGoaway {
		return nil
	}
	if err == io.EOF || err == io.ErrUnexpectedEOF {
		return nil
	}
	if netErr, ok := err.(net.Error); ok && netErr.Timeout() && sawGoaway {
		return nil
	}
	if err != nil && !sawGoaway {
		// A peer close without a parsed GOAWAY still ends the bad connection.
		if _, ok := err.(net.Error); ok {
			return nil
		}
		return err
	}
	return fmt.Errorf("malformed connection stayed open")
}

func stall(address string) error {
	conn, err := dialTLS(address, []string{"h2"})
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err = io.WriteString(conn, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"); err != nil {
		return err
	}
	if err = writeFrame(conn, 4, 0, 0, nil); err != nil {
		return err
	}
	// Indexed POST and https, literal :path /stall, :authority, content-length 32.
	block := []byte{
		0x83, 0x87,
		0x04, 0x06, '/', 's', 't', 'a', 'l', 'l',
		0x01, 0x09, 'l', 'o', 'c', 'a', 'l', 'h', 'o', 's', 't',
		0x0f, 0x0d, 0x02, '3', '2',
	}
	if err = writeFrame(conn, 1, 0x4, 1, block); err != nil {
		return err
	}
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	sawReset := false
	err = readFrames(conn, func(kind, flags byte, stream uint32, payload []byte) bool {
		if kind == 4 && flags&1 == 0 {
			_ = writeFrame(conn, 4, 1, 0, nil)
		}
		if kind == 3 && stream == 1 {
			sawReset = true
			return true
		}
		return false
	})
	if sawReset {
		return nil
	}
	if err != nil {
		return err
	}
	return fmt.Errorf("stalled stream was not reset")
}

func writeFrame(w io.Writer, kind, flags byte, stream uint32, payload []byte) error {
	header := []byte{
		byte(len(payload) >> 16), byte(len(payload) >> 8), byte(len(payload)),
		kind, flags,
		byte(stream >> 24), byte(stream >> 16), byte(stream >> 8), byte(stream),
	}
	if _, err := w.Write(header); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func readFrames(r io.Reader, visit func(kind, flags byte, stream uint32, payload []byte) bool) error {
	header := make([]byte, 9)
	for {
		if _, err := io.ReadFull(r, header); err != nil {
			return err
		}
		length := int(header[0])<<16 | int(header[1])<<8 | int(header[2])
		if length > 1<<20 {
			return fmt.Errorf("frame length %d", length)
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(r, payload); err != nil {
			return err
		}
		stream := uint32(header[5])<<24 | uint32(header[6])<<16 | uint32(header[7])<<8 | uint32(header[8])
		if visit(header[3], header[4], stream&0x7fffffff, payload) {
			return nil
		}
	}
}
