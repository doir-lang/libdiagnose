#include <diagnose/diagnostics.hpp>
#include <string>

int main() {
	diagnose::enable_ansi_colors();
	diagnose::manager manager;

	// Example: Multi-line block with missing return
	std::string complex_example =
R"(my_function : (x : i32, y : i32) -> i32 = {
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
})";

	manager.register_source("complex.doir", complex_example);

	// Error 1: Missing return in function
	diagnose::diagnostic diag1;
	diag1.kind = diagnose::diagnostic::error;
	diag1.code = 601;
	diag1.message = "Function body must end with a terminator";
	diag1.location.file = "complex.doir";
	diag1.location.start = {1, 43};  // Start of block
	diag1.location.end = {5, 0};      // End of block

	diagnose::diagnostic::annotation term_ann;
	term_ann.position = {5, 0};  // End of line 5
	term_ann.message = std::string("Expected ") + diagnose::ansi::blue + "return" + diagnose::ansi::reset + " or " + diagnose::ansi::blue + "halt" + diagnose::ansi::reset +" here";
	diag1.annotations.push_back(term_ann);

	diagnose::diagnostic::annotation ret_type_ann;
	ret_type_ann.position = {1, 38};  // The return type
	ret_type_ann.message = std::string("Function declared to return ") + diagnose::ansi::magenta + "i32" + diagnose::ansi::reset;
	ret_type_ann.color = diagnose::ansi::cyan;  // Cyan for info
	diag1.annotations.push_back(ret_type_ann);

	diag1.context_message = std::string("This function block requires a ") + diagnose::ansi::blue + "return" + diagnose::ansi::reset + " statement";
	diag1.additional_note = std::string("Add ") + diagnose::ansi::blue + "_ : _ = return(%3)" + diagnose::ansi::reset + " to return the computed value";

	manager.push(diag1);

	// Example 2: Namespace resolution error
	std::string namespace_example =
R"(math : namespace = {
    vec2 : type = { x : f32 y : f32 }
}

physics : namespace = {
    vec2 : type = { x : f64 y : f64 z : f64 }
}

%1 : f32 = 1.0
%2 : f32 = 2.0
%3 : vec2 = vec2(%1, %2)
)";

	manager.register_source("namespaces.doir", namespace_example);

	diagnose::diagnostic diag2;
	diag2.kind = diagnose::diagnostic::error;
	diag2.code = 602;
	diag2.message = "Ambiguous type reference";
	diag2.location.file = "namespaces.doir";
	diag2.location.start = {11, 6};
	diag2.location.end = {11, 10};

	diagnose::diagnostic::annotation math_def;
	math_def.position = {2, 6};
	math_def.message = std::string("Could refer to ") + diagnose::ansi::bright_magenta + diagnose::ansi::bold + "math.vec2" + diagnose::ansi::reset + " defined here";
	math_def.color = diagnose::ansi::cyan;
	diag2.annotations.push_back(math_def);

	diagnose::diagnostic::annotation physics_def;
	physics_def.position = {6, 6};
	physics_def.message = std::string("Could refer to ") + diagnose::ansi::bright_magenta + diagnose::ansi::bold + "physics.vec2" + diagnose::ansi::reset + " defined here";
	physics_def.color = diagnose::ansi::cyan;
	diag2.annotations.push_back(physics_def);

	diag2.context_message = std::string("Multiple definitions of ") + diagnose::ansi::bright_blue + "vec2" + diagnose::ansi::reset + " are visible in this scope";
	diag2.additional_note = std::string("Use a fully qualified name like ") + diagnose::ansi::bright_blue + "math.vec2" + diagnose::ansi::reset + " or " + diagnose::ansi::bright_blue + "physics.vec2" + diagnose::ansi::reset + "";

	manager.push(diag2);

	// Example 3: Comptime constraint violation
	std::string comptime_example =
R"(comp_pow : (mantissa : type.comptime(i32), base : i32) -> i32 = {
	%1 : i32 = multiply(base, mantissa)
	%2 : i32 = multiply(%1, %1)
	_ : _ = return(%2)
}

runtime_value : i32 = 5
result : i32 = comp_pow(runtime_value, 2)
)";

	manager.register_source("comptime.doir", comptime_example);

	diagnose::diagnostic diag3;
	diag3.kind = diagnose::diagnostic::error;
	diag3.code = 603;
	diag3.message = "Comptime parameter requires compile-time constant";
	diag3.location.file = "comptime.doir";
	diag3.location.start = {8, 25};
	diag3.location.end = {8, 38};

	diagnose::diagnostic::annotation runtime_ann;
	runtime_ann.position = {8, 26};
	runtime_ann.message = std::string("This value is computed at ") + diagnose::ansi::bright_magenta + diagnose::ansi::bold + "runtime" + diagnose::ansi::reset;
	diag3.annotations.push_back(runtime_ann);

	diagnose::diagnostic::annotation param_ann;
	param_ann.position = {1, 14};
	param_ann.message = std::string("Parameter requires ") + diagnose::ansi::bright_magenta + diagnose::ansi::bold + "compile-time" + diagnose::ansi::reset + " value";
	param_ann.color = diagnose::ansi::cyan;
	diag3.annotations.push_back(param_ann);

	diag3.context_message = std::string("The ") + diagnose::ansi::bright_blue + "mantissa" + diagnose::ansi::reset + " parameter is marked as " + diagnose::ansi::bright_blue + "comptime" + diagnose::ansi::reset + "";
	diag3.additional_note = "Only compile-time constants can be passed to comptime parameters";

	manager.push(diag3);

	// Example 4: Note about optimization opportunity
	std::string optimization_example =
R"(%1 : i32 = 100
%2 : i32 = 0

loop_body : block = {
	%3 : i32 = add(%2, %1)
	_ : _ = yield(%3)
}

%4 : i1 = is_less(%2, %1)
result : type.pointer(i32) = while(%4, loop_body)
)";

	manager.register_source("optimization.doir", optimization_example);

	diagnose::diagnostic diag4;
	diag4.kind =  diagnose::diagnostic::note;
	diag4.message = "Loop condition uses constant values";
	diag4.location.file = "optimization.doir";
	diag4.location.start = {9, 10};
	diag4.location.end = {9, 26};

	diagnose::diagnostic::annotation const1;
	const1.position = {9, 20};
	const1.message = std::string("This is constant: ") + diagnose::ansi::bright_magenta + diagnose::ansi::bold + "0" + diagnose::ansi::reset + "";
	const1.color = diagnose::ansi::blue;  // Blue for note
	diag4.annotations.push_back(const1);

	diagnose::diagnostic::annotation const2;
	const2.position = {9, 24};
	const2.message = std::string("This is constant: ") + diagnose::ansi::bright_magenta + diagnose::ansi::bold + "100" + diagnose::ansi::reset + "";
	const2.color = diagnose::ansi::blue;
	diag4.annotations.push_back(const2);

	diagnose::diagnostic::annotation const3;
	const3.position = {9, 12};
	const3.message = std::string("This is function: ") + diagnose::ansi::blue + diagnose::ansi::bold + "is_less" + diagnose::ansi::reset + "";
	const3.color = diagnose::ansi::blue;
	diag4.annotations.push_back(const3);

	diag4.additional_note = "Consider computing this at compile-time or using variables that change";

	manager.push(diag4);

	// Print all diagnostics
	nowide::cout << "\n=== Complex DOIR Diagnostics ===\n\n";
	manager.print_all();

	return manager.has_errors() ? 1 : 0;
}
