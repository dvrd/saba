# OKAMI-85 — cooperative request lifetime

Added handler contexts with explicit retain/release, monotonic optional handler
budgets, first-observed terminal reasons, shared server stop/drain cancellation,
observable peer/I/O failure propagation and late-response continuation disposal.
Retained nodes contain no arena/runtime/socket pointers. The facade forwards the
new optional timeout and exports the context helpers. Existing synchronous API
and separate I/O budgets remain supported; no forced preemption or offload pool.

Validation: Darwin arm64, Odin dev-2026-11:c826157de, 2026-11-07.

- Saba core: 26 ASan tests pass, including independently retained allocation
  tracking to zero, allocation failure without parent retention, stable reasons/deadlines, late response drop exactly once,
  I/O failures without observability and 8-thread retain/release/shutdown.
- Concurrent context test also passes ThreadSanitizer.
- Cancellation loopback: 5 groups pass under both ASan and TSan. Retained context
  survives repeated arena resets and runtime destruction; late handler yields408
  and exactly one drop; immediate stop and drain expiry reach a running handler
  with one worker; peer failure cancels without an observer.
- Existing facade: 9 tests pass. Existing keep_alive.py wire regressions pass.
- Isolated empty executable, Saba and Auth consumers build/run successfully.

Reproduction (from Odin root):

```
./odin test shared/saba/core -warnings-as-errors -sanitize:address -out:/tmp/lifetime-tests
./odin test shared/saba/core -warnings-as-errors -sanitize:thread -define:ODIN_TEST_NAMES=saba_core.context_retains_and_shutdown_are_thread_safe -out:/tmp/lifetime-races
python3 shared/saba/tests/cancellation.py --odin ./odin --sanitize address
python3 shared/saba/tests/cancellation.py --odin ./odin --sanitize thread
ODIN="$PWD/odin" python3 shared/saba/tests/keep_alive.py
python3 ci/webtools_consumer_gate.py --odin ./odin --packages saba auth --report /tmp/lifetime-consumers.json
```

All sockets/processes and state belong to the fixtures. No non-Darwin runtime,
Mesa adaptation update, performance result or bounded offload implementation is
claimed. Host jobs still need separately owned inputs/results and admission.
