package http_parity_tests

Request_Case :: struct {
	name, wire: string,
	status:     int,
}
REQUESTS :: [?]Request_Case {
	{"valid", "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", 0},
	{"query", "GET /a?b=c HTTP/1.1\r\nHost: example.com\r\n\r\n", 0},
	{"missing Host", "GET / HTTP/1.1\r\n\r\n", 400},
	{"duplicate Host", "GET / HTTP/1.1\r\nHost: a.example\r\nHost: a.example\r\n\r\n", 400},
	{"mixed-case duplicate Host", "GET / HTTP/1.1\r\nHost: a.example\r\nhOsT: b.example\r\n\r\n", 400},
	{"userinfo Host", "GET / HTTP/1.1\r\nHost: user@example.com\r\n\r\n", 400},
	{"empty Host", "GET / HTTP/1.1\r\nHost: \r\n\r\n", 400},
	{"Host path", "GET / HTTP/1.1\r\nHost: example.com/path\r\n\r\n", 400},
	{"Host port overflow", "GET / HTTP/1.1\r\nHost: example.com:65536\r\n\r\n", 400},
	{"root-dot Host", "GET / HTTP/1.1\r\nHost: example.com.:8080\r\n\r\n", 0},
	{"IPv6 Host", "GET / HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n", 0},
	{
		"duplicate length",
		"POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
		400,
	},
	{"TE CL", "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n", 400},
	{"chunked unsupported", "POST / HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n", 501},
	{"negative length", "POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: -1\r\n\r\n", 400},
	{
		"overflow length",
		"POST / HTTP/1.1\r\nHost: example.com\r\nContent-Length: 9999999999999999999999999999\r\n\r\n",
		400,
	},
	{"folded header", "GET / HTTP/1.1\r\nHost: example.com\r\n folded\r\n\r\n", 400},
	{"space before colon", "GET / HTTP/1.1\r\nHost : example.com\r\n\r\n", 400},
	{"bad field value", "GET / HTTP/1.1\r\nHost: example.com\r\nX-Value: bad\x01value\r\n\r\n", 400},
	{"expect unsupported", "POST / HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n\r\n", 417},
	{"partial head", "GET / HTTP/1.1\r\nHost: example.com\r\n", 400},
	{"wrong version", "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n", 400},
	{"fragment target", "GET /#bad HTTP/1.1\r\nHost: example.com\r\n\r\n", 400},
}
