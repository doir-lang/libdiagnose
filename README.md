# libdiagnose

## Testing

`-betterC` has no unittest runner of its own, so
[tests/runner.d](tests/runner.d) walks each `diagnose` module with
`__traits(getUnitTests)` and calls the tests itself. It reports each module
and test index to `stderr` as it goes — `stderr` is unbuffered, so a test
that hangs or aborts still leaves a record of how far the run got — and
prints the total at the end.

```sh
dub test                 # build and run the unittests
```

The `unittest` configuration is the default for `dub test`, so a bare
`dub test` picks up the runner. Note that `dub test -c` with a *non-default*
configuration substitutes dub's own druntime-based `main`, which registers
nothing under `-betterC` and then reports success having run no tests; build
and run such a configuration directly instead.

## Coverage

```sh
tools/coverage.sh        # per-module summary
tools/coverage.sh -v     # ... and every uncovered line
DC=dmd tools/coverage.sh # measure with DMD instead of the default LDC
```

`-cov` records its line counts through druntime, which `-betterC` does not
have, so the script builds the same sources and the same tests as ordinary D
— [tests/runner.d](tests/runner.d) supplies a druntime `main` when
`DiagnoseCoverage` is set, and disables druntime's own test pass so the tests
still run exactly once. It asks `dub describe` where the sources and import
paths are rather than repeating `dub.json`, compiles libfp in alongside
(`-I` alone would leave its symbols undefined at link time), and then drops
libfp's `.lst` files from the report so the numbers cover `diagnose` only.
