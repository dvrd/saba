# Saba bounded offload validation — OKAMI-91

This records the Saba portion of the isolated candidate. It does not mark the
cross-library issue complete or claim application migration. All sockets, FIFO
paths, processes and payloads are owned by the tests. Evidence is Darwin arm64
with the matching Odin `dev-2026-11:c826157de` and LLVM 22.1.8.

| Check | Result |
| --- | --- |
| Core package | 36 tests pass under ASan and TSan |
| Compatibility facade | 9 tests pass under ASan |
| Owned offload wire fixture | 10 groups pass under ASan and TSan |
| Existing keep-alive corpus | 19 groups pass through core and the same 19 through facade under ASan |
| Existing streaming corpus | 9 groups pass under ASan |
| Existing cancellation corpus | 5 groups pass under ASan |
| Existing upgrade corpus | 9 checks, 8 owned sessions pass under ASan |
| Existing facade async server | 25 groups pass under ASan |
| Physical clean consumers | Empty executable plus `saba`, `saba/core`, `saba/offload` build and run |

The ten offload groups cover two running/two queued jobs, fifth-request 503 and
cheap-route progress with one network worker; pre-header status/body delivery;
prefetched and later-arriving pipeline bytes; no early response head; bounded
pipeline overflow retirement; peer close and deadline retirement while independent
work remains blocked; shutdown and drain before releasing late work; failed-result
nonexposure; and real blocking FIFO open/read on a separate one-worker/one-slot
filesystem lane. The FIFO test waits for observed lane occupancy, not a scheduling
sleep. Payload and FIFO path allocations use a real heap tracking allocator and
must return to zero after pool retirement, with no invalid frees.

Core regressions cover copy-before-dispose, late-status rejection, detached wake,
blocking send rejection, incompatible response modes with every transferred owner
dropped once, and setup failure after continuation transfer. The initial wire
pipeline check failed with EOF because ordinary reuse required the Dispatch phase;
ready deferred responses now rejoin that phase before queueing. Negative evidence
is preserved by the parent continuation's evidence directory.

These are functional/lifetime checks, not performance, production, Linux or Windows
certification. Auth-specific KDF/provider/database validation and Mesa integration
are recorded separately by their owning streams. Existing baseline strict `-vet`
diagnostics in benchmark/upgrade imports and HTTP shadowing remain outside this
change; no unrelated cleanup is included.

## Reproduction

Set `ODIN` to the matching compiler and `SHARED` to a collection containing the
candidate Saba and async modules plus their declared dependencies. ASan/TSan need
the matching LLVM runtime on PATH. Keep binaries and generated reports outside the
repository.

```sh
odin test "$SHARED/saba/core" -collection:shared="$SHARED" -sanitize:address -warnings-as-errors -thread-count:1 -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -out:/tmp/saba-core-tests
odin test "$SHARED/saba/core" -collection:shared="$SHARED" -sanitize:thread -warnings-as-errors -thread-count:1 -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -out:/tmp/saba-core-tsan
odin test "$SHARED/saba" -collection:shared="$SHARED" -sanitize:address -warnings-as-errors -thread-count:1 -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -out:/tmp/saba-facade-tests
python3 "$SHARED/saba/tests/offload.py" --odin "$ODIN" --shared "$SHARED" --sanitize address
python3 "$SHARED/saba/tests/offload.py" --odin "$ODIN" --shared "$SHARED" --sanitize thread
```

The existing keep-alive/streaming scripts use a compiler command that selects the
same shared collection. The clean consumer gate uses regular physical source
copies, with an exact source manifest; symlinked worktrees alone do not establish
physical closure. Layout measurements on the same compiler: Response 128→160
bytes; Connection_Task 1720→1808; Server_Runtime unchanged at 5800. These describe
the current baseline-to-candidate change, not the earlier extraction table or RSS.
