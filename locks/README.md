# Dependency lock checkpoint

The first successful workflow run emits `xmake-requires.lock` in its audit
artifact. To make later runs use exactly that resolved dependency graph, copy
the file to this directory as:

```text
locks/xmake-requires.lock
```

The build fails if Xmake changes a committed lock. The first run is still an
A/B-safe build because the control and patched DLLs use the same generated lock
inside one job, but it cannot predict the dependency versions before resolution.
