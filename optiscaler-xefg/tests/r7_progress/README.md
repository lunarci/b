# R7 GPU progress regression boundaries

This suite compiles production GPU progress code against controlled D3D12 queue,
fence, device, and clock boundaries. The fixtures verify the code's decisions;
they do not emulate GPU execution or prove game performance.

The actual `TrackLifetimeQueue`, `ObserveSubmittedQueue`, `PollGpuProgress`,
`PollGpuProgressLocked`, `PublishGpuProgressLocked`, and `ReleaseObjects` bodies
are extracted on every run. The production queue-entry definition, admission
gate, timing counters, and progress diagnostics are included directly.

Cases cover an idle queue without a marker, a submitted marker remaining
incomplete, later completion, the device-removed fence sentinel, failed Signal,
three failed fence-creation attempts, the eight-queue bound, 100,000 rapid
callbacks, a slow CreateFence crossing the sampling deadline, diagnostic lock
contention, shutdown admission, successful cleanup, and queue-entry recreation.
The fake COM methods expose call counts, reference balances, and controlled
blocking. Event waits fail immediately if the observation path calls them.

The real `ReleaseObjects` preconditions are checked with and without a separate
completed lifecycle drain. The harness explicitly supplies that drain result;
it does not claim that a diagnostic marker proves safe GPU cleanup. A blocked
fake Signal establishes that the real admission gate cannot close until its
callback finishes. Driver calls themselves can still block in the real system.

`r6_pending_baseline.json` pins the deployed R6 function bodies and source SHA.
An actual Reset/new-recording/late-After sequence must fail the specific pending
recording invariant under R6, with exit 42; a compiler failure cannot pass.
Suite 11 runs the corresponding R7 methods, including an empty submission ticket
and overlapping two-list/one-list batches with different generation watermarks.

The separate installed-hook suite verifies that queue observation occurs after
the original ExecuteCommandLists call. Earlier R1–R6 regression suites remain
enabled, including failure controls and the Intel DLL patch checks.

Windows fixtures avoid defining compiler intrinsics, preserve assertions with
`/UNDEBUG`, and forward variadic log arguments as one `__VA_ARGS__` list. Test
source identity checks normalize checkout CRLF before hashing. A successful CPU
test does not establish actual GPU progress, safe driver behavior, recovered FPS,
visual quality, or successful long gameplay through Night City and Dogtown.
