# R6 production regression coverage

`python optiscaler-xefg/tests/r6_recovery/run.py <source>` runs this suite. The top-level runner also retains all twelve previous suites and adds the independent FFX registry suite.

The resource pipeline compiles complete current production `SetResource`, `Dispatch`, `GetDispatchIndex`, activation, recovery preparation and status-consumption functions. SDK calls, COM resources, camera math and the clock are deterministic external fakes. A disabled fake provider deliberately retains no resource tags. The tests verify enable-before-tag, one-frame evidence, expected HUDless input, multi-slot frame evidence, retries under 10,000 callbacks, OOM and terminal control results, rejected entries, changed-format convergence, SDK-reported output and lifecycle admission. They do not mirror the recovery algorithm in test code.

The separate frame-boundary harness combines actual Streamline 1 `CheckForFrame`, base and XeFG frame setters/increments, actual dispatch-slot selection and the production recovery helper. It reproduces duplicate frame bookkeeping and frame-ahead selection that a current-frame-only fake would miss.

Production headers verify warning/error separation, last-status ambiguity during overlapping TEST/normal Presents, input accounting, retry limits, stale tokens and concurrent trial admission. Complete native `FGPresent`/`Present1` hookup, callback order, inactive progress and TEST exclusions remain tested by suite 11.

The actual residency hook is tested for exactly one native call, preserving original OOM/device errors, the narrow known-AMD invalid-priority workaround and bounded logging. The allocation-observer adapter tests compile actual callback registration and transactional installation/removal functions against fake COM and Detours. These cover immediate/late callbacks, balanced references, pool exhaustion, stale generations and rollback; placed allocations are not counted again as committed allocations.

`r5_baseline.json` contains exact R5 production functions with source hashes. Its LF-normalized SHA-256 is verified before two runtime negative controls. Each must fail its specific assertion with exit 42: 100 repeated changed-format frames cannot converge, and a failed SDK Depth tag leaves a poisoned slot. Compile failures and unrelated assertions cannot pass these controls. No Git tag or network access is required.

These tests check CPU control flow and fixed interfaces, not real GPU execution. Passing does not establish driver behavior, actual Intel interpolation quality, gameplay FPS, successful Night City–Dogtown recovery or long-session stability. Those require the Windows build and gameplay validation.
