package saba_core

import "core:strings"

route_parameter_name :: proc(name: string) -> bool {
	if name == "" do return false

	for character, index in name {
		if character >= 'a' && character <= 'z' do continue
		if character >= 'A' && character <= 'Z' do continue
		if character == '_' do continue
		if index > 0 && character >= '0' && character <= '9' do continue

		return false
	}

	return true
}

match_route :: proc(request: ^Request, method, pattern: string) -> bool {
	request.path_parameters = {}
	request.path_parameter_count = 0

	if request.method != method do return false
	if !strings.has_prefix(pattern, "/") do return false
	if !strings.has_prefix(request.path, "/") do return false
	if strings.has_suffix(pattern, "/") != strings.has_suffix(request.path, "/") do return false

	parameters: [MAX_PATH_PARAMETERS]Path_Parameter
	count := 0
	pattern_remaining := pattern[1:]
	path_remaining := request.path[1:]

	for {
		pattern_segment, has_pattern := strings.split_iterator(&pattern_remaining, "/")
		path_segment, has_path := strings.split_iterator(&path_remaining, "/")

		if !has_pattern || !has_path {
			if has_pattern != has_path do return false

			// Publish captures only after the whole route matches.
			request.path_parameters = parameters
			request.path_parameter_count = count
			if request._observe && len(pattern) <= MAX_EVENT_ROUTE_BYTES do request.route = pattern

			return true
		}

		if strings.has_prefix(pattern_segment, ":") {
			name := pattern_segment[1:]
			if !route_parameter_name(name) || path_segment == "" do return false
			if count == len(parameters) do return false

			for parameter in parameters[:count] {
				if parameter.name == name do return false
			}

			parameters[count] = {name, path_segment}
			count += 1
		} else if pattern_segment != path_segment {
			return false
		}
	}
}

path_value :: proc(request: ^Request, name: string) -> string {
	for parameter in request.path_parameters[:request.path_parameter_count] {
		if parameter.name == name do return parameter.value
	}

	return ""
}
