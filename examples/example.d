import diagnose;
import fp.string : promoteLiteral, createFromConcatenation;
import fp.dynarray : pushBack;

import core.stdc.stdio : fputs, stdout;

extern (C) int main() {
	enableAnsiColors();
	Manager manager;
	scope (exit) free(manager);

	// Example: Multi-line block with missing return
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

	manager.registerSource("complex.doir", complexExample);

	// Error 1: Missing return in function
	Diagnostic diag1;
	diag1.kind = Kind.error;
	diag1.hasCode = true;
	diag1.code = 601;
	diag1.message = promoteLiteral("Function body must end with a terminator");
	diag1.location.file = "complex.doir";
	diag1.location.start = Pair(1, 43); // Start of block
	diag1.location.end = Pair(6, 0); // End of block

	Diagnostic.Annotation termAnn;
	termAnn.position = Pair(6, 0); // End of line 6
	termAnn.message = createFromConcatenation("Expected ", Ansi.blue, "return", Ansi.reset, " or ", Ansi.blue, "halt", Ansi.reset, " here");
	pushBack(diag1.annotations, termAnn);

	Diagnostic.Annotation retTypeAnn;
	retTypeAnn.position = Pair(1, 37); // The return type
	retTypeAnn.message = createFromConcatenation("Function declared to return ", Ansi.magenta, "i32", Ansi.reset);
	retTypeAnn.color = Ansi.cyan; // Cyan for info
	pushBack(diag1.annotations, retTypeAnn);

	diag1.contextMessage = createFromConcatenation("This function block requires a ", Ansi.blue, "return", Ansi.reset, " statement");
	diag1.additionalNote = createFromConcatenation(
		"Add ", Ansi.blue, "_ : _ = return(%3)", Ansi.reset, " to return the computed value"
	);

	manager.push(diag1);

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

	manager.registerSource("namespaces.doir", namespaceExample);

	Diagnostic diag2;
	diag2.kind = Kind.error;
	diag2.hasCode = true;
	diag2.code = 602;
	diag2.message = promoteLiteral("Ambiguous type reference");
	diag2.location.file = "namespaces.doir";
	diag2.location.start = Pair(11, 6);
	diag2.location.end = Pair(11, 10);

	Diagnostic.Annotation mathDef;
	mathDef.position = Pair(2, 5);
	mathDef.message = createFromConcatenation("Could refer to ", Ansi.brightMagenta, Ansi.bold, "math.vec2", Ansi.reset, " defined here");
	mathDef.color = Ansi.cyan;
	pushBack(diag2.annotations, mathDef);

	Diagnostic.Annotation physicsDef;
	physicsDef.position = Pair(6, 5);
	physicsDef.message = createFromConcatenation(
		"Could refer to ", Ansi.brightMagenta, Ansi.bold, "physics.vec2", Ansi.reset, " defined here"
	);
	physicsDef.color = Ansi.cyan;
	pushBack(diag2.annotations, physicsDef);

	diag2.contextMessage = createFromConcatenation("Multiple definitions of ", Ansi.brightBlue, "vec2", Ansi.reset, " are visible in this scope");
	diag2.additionalNote = createFromConcatenation(
		"Use a fully qualified name like ", Ansi.brightBlue, "math.vec2", Ansi.reset,
		" or ", Ansi.brightBlue, "physics.vec2", Ansi.reset
	);

	manager.push(diag2);

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

	manager.registerSource("comptime.doir", comptimeExample);

	Diagnostic diag3;
	diag3.kind = Kind.error;
	diag3.hasCode = true;
	diag3.code = 603;
	diag3.message = promoteLiteral("Comptime parameter requires compile-time constant");
	diag3.location.file = "comptime.doir";
	diag3.location.start = Pair(8, 25);
	diag3.location.end = Pair(8, 38);

	Diagnostic.Annotation runtimeAnn;
	runtimeAnn.position = Pair(8, 25);
	runtimeAnn.message = createFromConcatenation("This value is computed at ", Ansi.brightMagenta, Ansi.bold, "runtime", Ansi.reset);
	pushBack(diag3.annotations, runtimeAnn);

	Diagnostic.Annotation paramAnn;
	paramAnn.position = Pair(1, 13);
	paramAnn.message = createFromConcatenation("Parameter requires ", Ansi.brightMagenta, Ansi.bold, "compile-time", Ansi.reset, " value");
	paramAnn.color = Ansi.cyan;
	pushBack(diag3.annotations, paramAnn);

	diag3.contextMessage = createFromConcatenation(
		"The ", Ansi.brightBlue, "mantissa", Ansi.reset, " parameter is marked as ", Ansi.brightBlue, "comptime", Ansi.reset
	);
	diag3.additionalNote = promoteLiteral("Only compile-time constants can be passed to comptime parameters");

	manager.push(diag3);

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

	manager.registerSource("optimization.doir", optimizationExample);

	Diagnostic diag4;
	diag4.kind = Kind.note;
	diag4.message = promoteLiteral("Loop condition uses constant values");
	diag4.location.file = "optimization.doir";
	diag4.location.start = Pair(9, 11);
	diag4.location.end = Pair(9, 26);

	Diagnostic.Annotation const1;
	const1.position = Pair(9, 19);
	const1.message = createFromConcatenation("This is constant: ", Ansi.brightMagenta, Ansi.bold, "0", Ansi.reset);
	const1.color = Ansi.blue; // Blue for note
	pushBack(diag4.annotations, const1);

	Diagnostic.Annotation const2;
	const2.position = Pair(9, 23);
	const2.message = createFromConcatenation("This is constant: ", Ansi.brightMagenta, Ansi.bold, "100", Ansi.reset);
	const2.color = Ansi.blue;
	pushBack(diag4.annotations, const2);

	Diagnostic.Annotation const3;
	const3.position = Pair(9, 11);
	const3.message = createFromConcatenation("This is function: ", Ansi.blue, Ansi.bold, "is_less", Ansi.reset);
	const3.color = Ansi.blue;
	pushBack(diag4.annotations, const3);

	diag4.additionalNote = promoteLiteral("Consider computing this at compile-time or using variables that change");

	manager.push(diag4);

	// Example 5: Cross-file type mismatch (annotation points into a different file)
	const(char)[] shapesExample =
`circle : type = { radius : f32 }

area : (shape : circle) -> f32 = {
	%1 : f32 = multiply(shape.radius, shape.radius)
	%2 : f32 = multiply(%1, 3.14159)
	_ : _ = return(%2)
}
`;

	manager.registerSource("shapes.doir", shapesExample);

	const(char)[] mainExample =
`import : _ = shapes

square : type = { side : f32 }

my_square : square = { side = 2.0 }
result : f32 = shapes.area(my_square)
`;

	manager.registerSource("main.doir", mainExample);

	Diagnostic diag5;
	diag5.kind = Kind.error;
	diag5.hasCode = true;
	diag5.code = 604;
	diag5.message = promoteLiteral("Argument type does not match parameter type");
	diag5.location.file = "main.doir";
	diag5.location.start = Pair(6, 28);
	diag5.location.end = Pair(6, 37);

	Diagnostic.Annotation argAnn;
	argAnn.position = Pair(6, 28); // "my_square" argument in main.doir
	argAnn.message = createFromConcatenation("Argument has type ", Ansi.brightMagenta, Ansi.bold, "square", Ansi.reset);
	pushBack(diag5.annotations, argAnn);

	Diagnostic.Annotation paramAnn2;
	paramAnn2.position = Pair(3, 17);
	paramAnn2.file = "shapes.doir"; // Points into a different file than the diagnostic itself
	paramAnn2.message = createFromConcatenation(
		"Parameter ", Ansi.brightBlue, "shape", Ansi.reset, " declared to require ",
		Ansi.brightMagenta, Ansi.bold, "circle", Ansi.reset, " here"
	);
	paramAnn2.color = Ansi.cyan;
	pushBack(diag5.annotations, paramAnn2);

	diag5.contextMessage = createFromConcatenation("Call to ", Ansi.brightBlue, "shapes.area", Ansi.reset, " defined in another file");
	diag5.additionalNote = createFromConcatenation("Pass a value of type ", Ansi.blue, "circle", Ansi.reset, " instead");

	manager.push(diag5);

	// Example 6: Unicode in source text and diagnostic messages. Note that
	// `Pair.column` is a *byte* offset into the UTF-8 source, not a character
	// count — spans must land on character boundaries (never split a
	// multi-byte sequence) for the source-line slicing in printSourceContext
	// to produce valid UTF-8. Terminal alignment of the "└─" connectors is
	// still computed one byte per column, so multi-byte characters *before*
	// an annotation on the same line will shift it slightly out of visual
	// alignment on a real terminal — a known limitation, not something this
	// example works around.
	const(char)[] unicodeExample =
		"café : (naïve : i32) -> i32 = {\n" ~
		"\t%1 : i32 = add(naïve, 1)\n" ~
		"\t_ : _ = return(%1)\n" ~
		"}\n" ~
		"\n" ~
		"result : i32 = café(\"\U0001F600\")\n";

	manager.registerSource("unicode.doir", unicodeExample);

	Diagnostic diag6;
	diag6.kind = Kind.error;
	diag6.hasCode = true;
	diag6.code = 605;
	diag6.message = promoteLiteral("String literal cannot be converted to i32");
	diag6.location.file = "unicode.doir";
	diag6.location.start = Pair(6, 22); // Start of the "😀" string literal (including quotes)
	diag6.location.end = Pair(6, 28); // End of the string literal

	Diagnostic.Annotation emojiAnn;
	emojiAnn.position = Pair(6, 22);
	emojiAnn.message = createFromConcatenation(
		"Expected a numeric ", Ansi.blue, "i32", Ansi.reset, " value here, found ",
		Ansi.brightMagenta, Ansi.bold, "\"\U0001F600\"", Ansi.reset
	);
	pushBack(diag6.annotations, emojiAnn);

	Diagnostic.Annotation paramAnn3;
	paramAnn3.position = Pair(1, 19); // The "i32" parameter type
	paramAnn3.message = createFromConcatenation(
		"Parameter ", Ansi.brightBlue, "naïve", Ansi.reset, " declared as ", Ansi.brightMagenta, Ansi.bold, "i32", Ansi.reset, " here"
	);
	paramAnn3.color = Ansi.cyan;
	pushBack(diag6.annotations, paramAnn3);

	diag6.contextMessage = createFromConcatenation("Call to ", Ansi.brightBlue, "café", Ansi.reset, " with a non-numeric argument");
	diag6.additionalNote = promoteLiteral(
		"Emoji and other Unicode text can't be implicitly converted to i32 — pass a numeric literal instead"
	);

	manager.push(diag6);

	// Print all diagnostics
	fputs("\n=== Complex DOIR Diagnostics ===\n\n".ptr, stdout);
	manager.printAll();

	return manager.hasErrors() ? 1 : 0;
}
