/// Manual unittest runner for -betterC: druntime's automatic test runner
/// (`core.runtime.runModuleUnitTests`) isn't available, so this discovers
/// and runs every `unittest {}` block in the `diagnose` package modules.
module runner;

import std.meta : AliasSeq;
import diagnose.source_location;
import diagnose.diagnostics;

private alias ModuleList = AliasSeq!(
	diagnose.source_location, diagnose.diagnostics
);

extern (C) void main() {
	import core.stdc.stdio : printf;

	size_t count = 0;
	static foreach (m; ModuleList) {
		static foreach (u; __traits(getUnitTests, m)) {
			u();
			count++;
		}
	}
	printf("libdiagnose: %zu unittests passed\n", count);
}
