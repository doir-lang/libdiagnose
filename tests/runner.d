/// Runs every module's unittests, since `-betterC` has no runner of its own. Progress goes to the unbuffered `stderr`, so a test that hangs or aborts still shows how far the run got.
module runner;

private alias modules = imported!"std.meta".AliasSeq!(
	"diagnose.source_location",
	"diagnose.diagnostics",
);

private int runEveryTest() {
	cast(void) imported!"fp.testing".runTests!modules("libdiagnose");
	return 0;
}

// `tools/coverage.py` builds plain D, since `-cov` registers its counters through druntime, which needs druntime's own `main`.
version(DiagnoseCoverage) {
	// Stops druntime running every test itself before `main`, which would run them twice.
	shared static this() {
		static import core.runtime;
		core.runtime.Runtime.extendedModuleUnitTester = () => core.runtime.UnitTestResult(0, 0, true, false);
	}

	int main() { return runEveryTest(); }
} else
	extern(C) int main() { return runEveryTest(); }
