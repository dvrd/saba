# Saba hierarchical resource validation — OKAMI-122

Saba candidate evidence only; full cross-library/Surf/Auth/application acceptance
is coordinated by the parent issue. Darwin arm64, matching Odin executable and
isolated modified standard library via ODIN_ROOT, LLVM22.1.8. No push or external
endpoints. Existing unrelated work and91 worktrees remain unchanged.

| Check | Result |
| --- | --- |
| Core package | 47 tests pass ASan/TSan |
| Offload legacy procedure value | 1 selected-package strict ASan test passes |
| Assets package | 11 ASan tests pass |
| Compatibility facade | 9 ASan tests pass through physical candidate closure |
| Resource wire fixture | 6 ASan/TSan groups pass |
| Existing offload/FIFO fixture | 10 ASan/TSan groups pass on final source |
| Existing keep-alive | 19 core and same19 facade groups pass ASan |
| Existing streaming/SSE | 9 ASan groups pass |
| Existing file/range serving | 8 ASan groups pass |
| Existing cancellation | 5 ASan groups pass on final source |
| Existing upgrade | 9 ASan checks,8 owned sessions pass |
| Physical consumers | Empty plus saba/core/offload/assets/facade build and run |

The six resource groups exercise operation512KiB and connection512KiB denial
independently with global256MiB available and snapshots at all three levels; two
partially uploaded1MiB bodies consuming actual backing before payload arrival;
slow buffered readers holding real copied backing; sole active streaming exchange
admission and recovery; metadata growth2→32 with unchanged resource limits; and
simultaneous4MiB partial upload,4MiB slow response, two charged blocked jobs and
two streaming exchanges under one20MiB/two-stream/two-job application Scope.
Excess jobs, streams and large response backing reject while cheap routes proceed.
The real server/runtime then retires before the two late jobs are released. Their
bytes/jobs remain charged; final disposal requires all usage zero, one remaining
application Scope node and zero actual tracked job backing/invalid frees.

Independent review produced four red ASan regressions and corresponding fixes:
HEAD no longer copies an unsent64KiB host body into a32KiB operation; chunk decoder
allocation denial now emits fixed503; a valid keep-alive prefetch losing global
capacity to another real charged allocation emits503; and early new-operation
metadata OOM resets observation before starting the rejected request, recovering
started/completed/active counters. All four regressions are retained in core tests; the independent reviewer reran
the four probes successfully under ASan/TSan and verified the production freeze.
Known408/413 statuses and deferred Build copy OOM also use fixed-buffer rejection.

File serving's host allocator fixture now bounds one configured16KiB payload plus
the publicly computed accounting header/alignment. The previous assertion limited
all backing to the payload alone and aborted after managed wrapping; the corrected
bound remains explicit rather than removing the allocation bound. Producer buffers
remain charged between custom chunk releases until actual producer storage free.

Exact legacy stream_submit and offload response procedure signatures remain
assignable; new provenance/unmanaged-byte entry points have separate names. The
full strict-vet diagnostic set remains exactly the seven baseline unused-import/
HTTP-shadowing diagnostics; selected new adapter tests pass strict checks. Source
layout additions and managed versus host-owned accounting boundaries are described
in [RESOURCES.md](RESOURCES.md). Requested backing is not RSS, kernel buffering or
arbitrary application cache memory; metadata is separately observable/bounded by
its own capacity policy and host ownership.

Final exact commands, compiler/standard-library/source hashes and evidence are
collected in the parent continuation's budgets122 evidence directory. Unsupported
platforms, full application migration, production throughput and future multiplexed
protocol support are not claimed by these functional gates.
