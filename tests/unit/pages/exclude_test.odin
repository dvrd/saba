package saba_pages_test

import "core:testing"
import modules "shared:saba/modules"

@(test)
module_exclusions_ignore_case :: proc(t: ^testing.T) {
	exclude := []string{"server", "/tools/build.jsx"}
	for path in ([]string{
		"server",
		"server/secret.js",
		"Server/secret.js",
		"SERVER/SECRET.js",
		"tools/build.jsx",
		"tools/build.js",
		"Tools/Build.JS",
		"tools/BUILD.JSX",
	}) {
		testing.expectf(t, modules.module_excluded(exclude, path), "%s is excluded", path)
	}
	for path in ([]string{"servers/a.js", "server.js", "tools/build.mjs", "tools/builder.js", "client/server/a.js"}) {
		testing.expectf(t, !modules.module_excluded(exclude, path), "%s is served", path)
	}
}
