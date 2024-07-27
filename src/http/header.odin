package http

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:log"
import "core:strconv"
import "core:strings"

Header :: struct {
	method:          HttpMethod,
	route:           string,
	content_type:    Mime_Type,
	accept:          string,
	host:            string,
	accept_encoding: []Encoding,
	connection:      string,
}

HttpMethod :: enum {
	Unknown,
	Get,
	Post,
	Put,
	Patch,
	Delete,
	Copy,
	Head,
	Options,
	Link,
	Unlink,
	Purge,
	Lock,
	Unlock,
	Propfind,
	View,
}

string_to_method :: proc(method: string) -> HttpMethod {
	switch method {
	case "GET":
		return .Get
	case "POST":
		return .Post
	case "PUT":
		return .Put
	case "PATCH":
		return .Patch
	case "DELETE":
		return .Delete
	case "COPY":
		return .Copy
	case "HEAD":
		return .Head
	case "OPTIONS":
		return .Options
	case "LINK":
		return .Link
	case "UNLINK":
		return .Unlink
	case "PURGE":
		return .Purge
	case "LOCK":
		return .Lock
	case "UNLOCK":
		return .Unlock
	case "PROPFIND":
		return .Propfind
	case "VIEW":
		return .View
	}

	return .Unknown
}

Encoding :: enum {
	Unknown,
	Any,
	GZip,
	Compress,
	Deflate,
	Br,
	ZStd,
	Identity,
}

parse_header :: proc(content: []byte) -> (header: Header, content_length: int, ok: bool) {
	buf: bytes.Buffer
	bytes.buffer_init(&buf, content)

	method: string
	method, ok = read_until(&buf, ' ')
	header.method = string_to_method(method)
	if !ok do log.error("reading method")

	route: string
	route, ok = read_until(&buf, ' ')
	header.route = route
	if !ok do log.error("reading route")

	protocol: string
	protocol, ok = read_until(&buf, '\n', trim = 2)
	if !ok do log.error("reading protocol")

	for {
		if bytes.buffer_is_empty(&buf) || cast(string)buf.buf[0:2] == "\r\n" do break

		name: string
		name, ok = read_until(&buf, ':')
		// defer delete(name)

		value: string
		value, ok = read_until(&buf, '\n', trim = 2)
		value = strings.trim_left_space(value)

		switch name {
		case "Content-Type":
			header.content_type = content_to_mime(value)
		case "Host":
			header.host = value
		case "Accept":
			// TODO: Multiple values and Q-Factor
			header.accept = value
		case "Connection":
			header.connection = value
		case "Content-Length":
			defer delete(value)
			content_length, ok = strconv.parse_int(value)
			return
		}
	}

	return
}

@(private)
read_until :: proc(
	buf: ^bytes.Buffer,
	until: byte,
	trim := 1,
	allocator := context.temp_allocator,
) -> (
	output: string,
	ok: bool,
) {
	data, err := bytes.buffer_read_bytes(buf, until)
	if err == .None {
		ok = true
		output = cast(string)data[:len(data) - trim]
	}
	return
}
