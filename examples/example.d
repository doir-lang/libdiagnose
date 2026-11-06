import diagnose;
static import fp.dynarray;
static import fp.file;
static import fp.string;

static import core.stdc.stdio;

extern (C) int main() {
	cast(void) fp.file.enableAnsiColorsAndUTF8();
	Manager manager;
	scope (exit) free(manager);

	// Example 1: Multi-line block with missing return
	const(char)[] complexExample =
`my_function : (x : i32, y : i32) -> i32 = {
	%1 : i32 = add(x, y)
	%2 : i32 = multiply(%1, x)
	%3 : i32 = subtract(%2, y)
	// Missing return statement!
}

caller : () = {
	%10 : i32 = 5
	%11 : i32 = 10
	%12 : i32 = my_function(%10, %11)
	_ : _ = return()
}`;

	if (!manager.addSource("complex.doir", complexExample)) return 2;

	// Error 1: Missing return in function
	Diagnostic missingReturn;
	missingReturn.kind = Kind.error;
	missingReturn.hasCode = true;
	missingReturn.code = 601;
	missingReturn.message = fp.string.clone("Function body must end with a terminator").get;
	missingReturn.location.file = "complex.doir";
	missingReturn.location.start = LineColumn(1, 43); // Start of block
	missingReturn.location.end = LineColumn(6, 0); // End of block

	Diagnostic.Annotation terminator;
	terminator.position = LineColumn(6, 0); // End of line 6
	terminator.message = fp.string.joined("Expected ", Ansi.blue, "return", Ansi.reset, " or ", Ansi.blue, "halt", Ansi.reset, " here").get;
	if (!fp.dynarray.pushBack(missingReturn.annotations, terminator)) return 2;

	Diagnostic.Annotation returnType;
	returnType.position = LineColumn(1, 37); // The return type
	returnType.message = fp.string.joined("Function declared to return ", Ansi.magenta, "i32", Ansi.reset).get;
	returnType.color = Ansi.cyan;
	if (!fp.dynarray.pushBack(missingReturn.annotations, returnType)) return 2;

	missingReturn.contextMessage = fp.string.joined("This function block requires a ", Ansi.blue, "return", Ansi.reset, " statement").get;
	missingReturn.note = fp.string.joined(
		"Add ", Ansi.blue, "_ : _ = return(%3)", Ansi.reset, " to return the computed value"
	).get;

	if (manager.push(missingReturn) is null) return 2;

	// Example 2: Namespace resolution error
	const(char)[] namespaceExample =
`math : namespace = {
    vec2 : type = { x : f32 y : f32 }
}

physics : namespace = {
    vec2 : type = { x : f64 y : f64 z : f64 }
}

%1 : f32 = 1.0
%2 : f32 = 2.0
%3 : vec2 = vec2(%1, %2)
`;

	if (!manager.addSource("namespaces.doir", namespaceExample)) return 2;

	Diagnostic ambiguousType;
	ambiguousType.kind = Kind.error;
	ambiguousType.hasCode = true;
	ambiguousType.code = 602;
	ambiguousType.message = fp.string.clone("Ambiguous type reference").get;
	ambiguousType.location.file = "namespaces.doir";
	ambiguousType.location.start = LineColumn(11, 6);
	ambiguousType.location.end = LineColumn(11, 10);

	Diagnostic.Annotation mathDefinition;
	mathDefinition.position = LineColumn(2, 5);
	mathDefinition.message = fp.string.joined("Could refer to ", Ansi.brightMagenta, Ansi.bold, "math.vec2", Ansi.reset, " defined here").get;
	mathDefinition.color = Ansi.cyan;
	if (!fp.dynarray.pushBack(ambiguousType.annotations, mathDefinition)) return 2;

	Diagnostic.Annotation physicsDefinition;
	physicsDefinition.position = LineColumn(6, 5);
	physicsDefinition.message = fp.string.joined(
		"Could refer to ", Ansi.brightMagenta, Ansi.bold, "physics.vec2", Ansi.reset, " defined here"
	).get;
	physicsDefinition.color = Ansi.cyan;
	if (!fp.dynarray.pushBack(ambiguousType.annotations, physicsDefinition)) return 2;

	ambiguousType.contextMessage = fp.string.joined("Multiple definitions of ", Ansi.brightBlue, "vec2", Ansi.reset, " are visible in this scope").get;
	ambiguousType.note = fp.string.joined(
		"Use a fully qualified name like ", Ansi.brightBlue, "math.vec2", Ansi.reset,
		" or ", Ansi.brightBlue, "physics.vec2", Ansi.reset
	).get;

	if (manager.push(ambiguousType) is null) return 2;

	// Example 3: Comptime constraint violation
	const(char)[] comptimeExample =
`comp_pow : (mantissa : type.comptime(i32), base : i32) -> i32 = {
	%1 : i32 = multiply(base, mantissa)
	%2 : i32 = multiply(%1, %1)
	_ : _ = return(%2)
}

runtime_value : i32 = 5
result : i32 = comp_pow(runtime_value, 2)
`;

	if (!manager.addSource("comptime.doir", comptimeExample)) return 2;

	Diagnostic comptimeViolation;
	comptimeViolation.kind = Kind.error;
	comptimeViolation.hasCode = true;
	comptimeViolation.code = 603;
	comptimeViolation.message = fp.string.clone("Comptime parameter requires compile-time constant").get;
	comptimeViolation.location.file = "comptime.doir";
	comptimeViolation.location.start = LineColumn(8, 25);
	comptimeViolation.location.end = LineColumn(8, 38);

	Diagnostic.Annotation runtimeValue;
	runtimeValue.position = LineColumn(8, 25);
	runtimeValue.message = fp.string.joined("This value is computed at ", Ansi.brightMagenta, Ansi.bold, "runtime", Ansi.reset).get;
	if (!fp.dynarray.pushBack(comptimeViolation.annotations, runtimeValue)) return 2;

	Diagnostic.Annotation comptimeParameter;
	comptimeParameter.position = LineColumn(1, 13);
	comptimeParameter.message = fp.string.joined("Parameter requires ", Ansi.brightMagenta, Ansi.bold, "compile-time", Ansi.reset, " value").get;
	comptimeParameter.color = Ansi.cyan;
	if (!fp.dynarray.pushBack(comptimeViolation.annotations, comptimeParameter)) return 2;

	comptimeViolation.contextMessage = fp.string.joined(
		"The ", Ansi.brightBlue, "mantissa", Ansi.reset, " parameter is marked as ", Ansi.brightBlue, "comptime", Ansi.reset
	).get;
	comptimeViolation.note = fp.string.clone("Only compile-time constants can be passed to comptime parameters").get;

	if (manager.push(comptimeViolation) is null) return 2;

	// Example 4: Note about optimization opportunity
	const(char)[] optimizationExample =
`%1 : i32 = 100
%2 : i32 = 0

loop_body : block = {
	%3 : i32 = add(%2, %1)
	_ : _ = yield(%3)
}

%4 : i1 = is_less(%2, %1)
result : type.pointer(i32) = while(%4, loop_body)
`;

	if (!manager.addSource("optimization.doir", optimizationExample)) return 2;

	Diagnostic constantLoop;
	constantLoop.kind = Kind.note;
	constantLoop.message = fp.string.clone("Loop condition uses constant values").get;
	constantLoop.location.file = "optimization.doir";
	constantLoop.location.start = LineColumn(9, 11);
	constantLoop.location.end = LineColumn(9, 26);

	Diagnostic.Annotation constantZero;
	constantZero.position = LineColumn(9, 19);
	constantZero.message = fp.string.joined("This is constant: ", Ansi.brightMagenta, Ansi.bold, "0", Ansi.reset).get;
	constantZero.color = Ansi.blue;
	if (!fp.dynarray.pushBack(constantLoop.annotations, constantZero)) return 2;

	Diagnostic.Annotation constantHundred;
	constantHundred.position = LineColumn(9, 23);
	constantHundred.message = fp.string.joined("This is constant: ", Ansi.brightMagenta, Ansi.bold, "100", Ansi.reset).get;
	constantHundred.color = Ansi.blue;
	if (!fp.dynarray.pushBack(constantLoop.annotations, constantHundred)) return 2;

	Diagnostic.Annotation predicateFunction;
	predicateFunction.position = LineColumn(9, 11);
	predicateFunction.message = fp.string.joined("This is function: ", Ansi.blue, Ansi.bold, "is_less", Ansi.reset).get;
	predicateFunction.color = Ansi.blue;
	if (!fp.dynarray.pushBack(constantLoop.annotations, predicateFunction)) return 2;

	constantLoop.note = fp.string.clone("Consider computing this at compile-time or using variables that change").get;

	if (manager.push(constantLoop) is null) return 2;

	// Example 5: Cross-file type mismatch (annotation points into a different file)
	const(char)[] shapesExample =
`circle : type = { radius : f32 }

area : (shape : circle) -> f32 = {
	%1 : f32 = multiply(shape.radius, shape.radius)
	%2 : f32 = multiply(%1, 3.14159)
	_ : _ = return(%2)
}
`;

	if (!manager.addSource("shapes.doir", shapesExample)) return 2;

	const(char)[] mainExample =
`import : _ = shapes

square : type = { side : f32 }

my_square : square = { side = 2.0 }
result : f32 = shapes.area(my_square)
`;

	if (!manager.addSource("main.doir", mainExample)) return 2;

	Diagnostic argumentType;
	argumentType.kind = Kind.error;
	argumentType.hasCode = true;
	argumentType.code = 604;
	argumentType.message = fp.string.clone("Argument type does not match parameter type").get;
	argumentType.location.file = "main.doir";
	argumentType.location.start = LineColumn(6, 28);
	argumentType.location.end = LineColumn(6, 37);

	Diagnostic.Annotation argument;
	argument.position = LineColumn(6, 28); // "my_square" argument in main.doir
	argument.message = fp.string.joined("Argument has type ", Ansi.brightMagenta, Ansi.bold, "square", Ansi.reset).get;
	if (!fp.dynarray.pushBack(argumentType.annotations, argument)) return 2;

	Diagnostic.Annotation parameter;
	parameter.position = LineColumn(3, 17);
	parameter.file = "shapes.doir"; // Points into a different file than the diagnostic itself
	parameter.message = fp.string.joined(
		"Parameter ", Ansi.brightBlue, "shape", Ansi.reset, " declared to require ",
		Ansi.brightMagenta, Ansi.bold, "circle", Ansi.reset, " here"
	).get;
	parameter.color = Ansi.cyan;
	if (!fp.dynarray.pushBack(argumentType.annotations, parameter)) return 2;

	argumentType.contextMessage = fp.string.joined("Call to ", Ansi.brightBlue, "shapes.area", Ansi.reset, " defined in another file").get;
	argumentType.note = fp.string.joined("Pass a value of type ", Ansi.blue, "circle", Ansi.reset, " instead").get;

	if (manager.push(argumentType) is null) return 2;

	// Example 6: Unicode text. Columns are byte offsets, so spans must not split a multi-byte sequence.
	const(char)[] unicodeExample =
		"café : (naïve : i32) -> i32 = {\n" ~
		"\t%1 : i32 = add(naïve, 1)\n" ~
		"\t_ : _ = return(%1)\n" ~
		"}\n" ~
		"\n" ~
		"result : i32 = café(\"\U0001F600\")\n";

	if (!manager.addSource("unicode.doir", unicodeExample)) return 2;

	Diagnostic unicodeArgument;
	unicodeArgument.kind = Kind.error;
	unicodeArgument.hasCode = true;
	unicodeArgument.code = 605;
	unicodeArgument.message = fp.string.clone("String literal cannot be converted to i32").get;
	unicodeArgument.location.file = "unicode.doir";
	unicodeArgument.location.start = LineColumn(6, 22); // Start of the "😀" string literal (including quotes)
	unicodeArgument.location.end = LineColumn(6, 28); // End of the string literal

	Diagnostic.Annotation emojiArgument;
	emojiArgument.position = LineColumn(6, 22);
	emojiArgument.message = fp.string.joined(
		"Expected a numeric ", Ansi.blue, "i32", Ansi.reset, " value here, found ",
		Ansi.brightMagenta, Ansi.bold, "\"\U0001F600\"", Ansi.reset
	).get;
	if (!fp.dynarray.pushBack(unicodeArgument.annotations, emojiArgument)) return 2;

	Diagnostic.Annotation unicodeParameter;
	unicodeParameter.position = LineColumn(1, 19); // The "i32" parameter type
	unicodeParameter.message = fp.string.joined(
		"Parameter ", Ansi.brightBlue, "naïve", Ansi.reset, " declared as ", Ansi.brightMagenta, Ansi.bold, "i32", Ansi.reset, " here"
	).get;
	unicodeParameter.color = Ansi.cyan;
	if (!fp.dynarray.pushBack(unicodeArgument.annotations, unicodeParameter)) return 2;

	unicodeArgument.contextMessage = fp.string.joined("Call to ", Ansi.brightBlue, "café", Ansi.reset, " with a non-numeric argument").get;
	unicodeArgument.note = fp.string.clone(
		"Emoji and other Unicode text can't be implicitly converted to i32 — pass a numeric literal instead"
	).get;

	if (manager.push(unicodeArgument) is null) return 2;

	cast(void) core.stdc.stdio.fputs("\n=== Complex DOIR Diagnostics ===\n\n".ptr, core.stdc.stdio.stdout);
	if (!manager.printAll()) return 2;

	return manager.hasErrors() ? 1 : 0;
}
