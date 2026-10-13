/// Runs every module's unittests, since `-betterC` has no runner of its own. Progress goes to the unbuffered `stderr`, so a test that hangs or aborts still shows how far the run got.
module runner;

import core.stdc.stdio : fprintf, printf, stderr;

private enum modules = [
	"diagnose.source_location",
	"diagnose.diagnostics",
];

private int runEveryTest() {
	size_t total = 0;

	static foreach (name; modules) {{
		alias mod = mixin("imported!\"" ~ name ~ "\"");
		alias tests = __traits(getUnitTests, mod);
		fprintf(stderr, "%s (%d tests)\n", name.ptr, cast(int) tests.length);
		static foreach (i, test; tests) {
			fprintf(stderr, "  [%d] ", cast(int) i);
			test();
			fprintf(stderr, "ok\n");
			++total;
		}
	}}

	printf("libdiagnose: all %d tests passed.\n", cast(int) total);
	return 0;
}

// `tools/coverage.py` builds plain D, since `-cov` registers its counters through druntime, which needs druntime's own `main`.
version(DiagnoseCoverage) {
	// Stops druntime running every test itself before `main`, which would run them twice.
	shared static this() {
		import core.runtime : Runtime, UnitTestResult;
		Runtime.extendedModuleUnitTester = () => UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }
