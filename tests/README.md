# Tests

Every suite is Odin, except where the thing under test is JavaScript: the
browser runtime (`browser/`, driven through Playwright) and its Node tests
(`javascript/`). A suite is a directory that holds `*_test.odin` files.

## Kinds

A suite's kind is what it touches, and it lives under that kind's directory.

| Directory | Kind | What it touches |
| --- | --- | --- |
| `unit/<area>` | Unit | One package, in-process. No sockets, no child programs. |
| `integration/<area>` | Integration | Saba in-process with real loopback sockets, usually a server and a client in one test binary. |
| `e2e/<scenario>` | End to end | A built Saba program, started as its own process and driven from outside over sockets by Saba's own ecosystem (raw bytes, surf, async). |
| `interop/<protocol>` | Interoperability | A built Saba program against an independent implementation (libcurl, OpenSSL, ngtcp2 and nghttp3), so Saba is never only checked against code that shares its assumptions. |
| `browser/` | Browser | Compiled pages and the DOM runtime in Chromium, Firefox and WebKit. |
| `javascript/` | JavaScript | The runtime modules under Node. |

Benchmarks are not tests: they live in `../benchmarks` (`load/`, `mesa/`,
`frameworks/`).

A unit or integration suite that declares the package of the source it tests
(`unit/core` declares `saba_core`) is white-box: the runner copies its files
into `src/core` for the run, so it can reach private declarations.
`unit/saba` and `integration/saba` are the root package. Any other suite is
black-box and imports `shared:saba/...` like an application.

## Shared code and inputs

- `fixtures/` holds every static input: `tls/` certificates, `ui/` and
  `ui_template/` pages, and `apps/`, programs that more than one suite builds.
  A program that one suite owns lives in that suite's directory (for example
  `e2e/<scenario>/server/`).
- `support/harness` builds a program against the test collection, starts it,
  waits for its `READY <port>` line and stops it.
- `support/peer` (TCP or OpenSSL connections that write hand-made bytes) and
  `support/fetch` (a libcurl client) are the independent peers of
  `interop/http2`, `interop/https` and `interop/websocket`;
  `interop/http3/peer` is the ngtcp2 and nghttp3 client of the HTTP/3 suites.
- `support/c/` holds the Odin bindings to the C libraries the interop suites
  use. A suite that needs them lists their pkg-config names in a `LIBRARIES`
  file; the runner links them and skips the suite where one is missing.

## Running

```sh
task test                                # every suite
task test -- unit                        # one kind
task test -- integration/core e2e        # suites and kinds
task test -- unit/core -- -define:ODIN_TEST_NAMES=saba_core.<test>
task test -- --shared ~/odin/shared      # linked dependencies instead of the lock
```

`task test` copies the checkout to a temporary directory and runs every
selected suite from there, so a run never writes into the working tree. By
default it installs `.krs/packages.json` with `krs install --frozen` into a
private root; `--shared` (or `WEBTOOLS_SHARED`) uses an existing collection.
It runs every suite and ends with a summary of the ones that failed or were
skipped.

Optional tools, each skipped with a notice when missing:

- Node (`SABA_NODE`) and Chrome or Chromium (`SABA_CHROME`) for `browser/` and
  `javascript/`; Firefox and WebKit through the Playwright package in
  `browser/driver`, which `task test` installs with `npm ci`.
- pkg-config with libcurl, OpenSSL, ngtcp2 and nghttp3 for `interop/`. On
  macOS: `brew install curl openssl@4 libngtcp2 libnghttp3`. Elsewhere,
  the distribution's development packages for libcurl, OpenSSL 3.5 or later,
  ngtcp2 with its OpenSSL crypto library (`libngtcp2_crypto_ossl`) and
  nghttp3.
