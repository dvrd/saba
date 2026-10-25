package server

HTTP_Status :: enum i32 {
	None                            = 0,
	Switching_Protocols             = 101,
	OK                              = 200,
	Created                         = 201,
	Accepted                        = 202,
	No_Content                      = 204,
	Found                           = 302,
	Not_Modified                    = 304,
	Bad_Request                     = 400,
	Unauthorized                    = 401,
	Forbidden                       = 403,
	Not_Found                       = 404,
	Request_Timeout                 = 408,
	Conflict                        = 409,
	Length_Required                 = 411,
	Content_Too_Large               = 413,
	Unsupported_Media_Type          = 415,
	Expectation_Failed              = 417,
	Too_Many_Requests               = 429,
	Request_Header_Fields_Too_Large = 431,
	Internal_Server_Error           = 500,
	Not_Implemented                 = 501,
	Service_Unavailable             = 503,
}

status_text :: proc(status: HTTP_Status) -> string {
	switch status {
	case .None:
		return ""
	case .Switching_Protocols:
		return "101 Switching Protocols"
	case .OK:
		return "200 OK"
	case .Created:
		return "201 Created"
	case .Accepted:
		return "202 Accepted"
	case .No_Content:
		return "204 No Content"
	case .Found:
		return "302 Found"
	case .Not_Modified:
		return "304 Not Modified"
	case .Bad_Request:
		return "400 Bad Request"
	case .Unauthorized:
		return "401 Unauthorized"
	case .Forbidden:
		return "403 Forbidden"
	case .Not_Found:
		return "404 Not Found"
	case .Request_Timeout:
		return "408 Request Timeout"
	case .Conflict:
		return "409 Conflict"
	case .Length_Required:
		return "411 Length Required"
	case .Content_Too_Large:
		return "413 Content Too Large"
	case .Unsupported_Media_Type:
		return "415 Unsupported Media Type"
	case .Expectation_Failed:
		return "417 Expectation Failed"
	case .Too_Many_Requests:
		return "429 Too Many Requests"
	case .Request_Header_Fields_Too_Large:
		return "431 Request Header Fields Too Large"
	case .Internal_Server_Error:
		return "500 Internal Server Error"
	case .Not_Implemented:
		return "501 Not Implemented"
	case .Service_Unavailable:
		return "503 Service Unavailable"
	}

	return ""
}
