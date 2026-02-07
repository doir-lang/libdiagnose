#pragma once

#include "source_location.hpp"
#include <optional>
#include <set>
#include <unordered_map>
#include <vector>
#include <iostream>
#include <algorithm>
#include <map>
#include <iomanip>
#include <numeric>
#include <nowide/iostream.hpp>

#ifdef _WIN32
#include <windows.h>
#endif

namespace diagnose {

	inline void enable_ansi_colors() {
	#ifdef _WIN32
		HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
		if (hOut == INVALID_HANDLE_VALUE) return;

		DWORD dwMode = 0;
		if (!GetConsoleMode(hOut, &dwMode)) return;

		dwMode |= ENABLE_VIRTUAL_TERMINAL_PROCESSING;
		SetConsoleMode(hOut, dwMode);
	#endif
	}

	// ANSI color codes for terminal output
	struct ansi {
		// reset / styles
		static constexpr const char* reset = "\033[0m";
		static constexpr const char* bold = "\033[1m";
		static constexpr const char* dim = "\033[2m";
		static constexpr const char* underline = "\033[4m";

		// standard foreground colors
		static constexpr const char* black = "\033[30m";
		static constexpr const char* red = "\033[31m";
		static constexpr const char* green = "\033[32m";
		static constexpr const char* yellow = "\033[33m";
		static constexpr const char* blue = "\033[34m";
		static constexpr const char* magenta = "\033[35m";
		static constexpr const char* cyan = "\033[36m";
		static constexpr const char* white = "\033[37m";

		// bright foreground colors
		static constexpr const char* bright_black = "\033[90m";
		static constexpr const char* bright_red = "\033[91m";
		static constexpr const char* bright_green = "\033[92m";
		static constexpr const char* bright_yellow = "\033[93m";
		static constexpr const char* bright_blue = "\033[94m";
		static constexpr const char* bright_magenta = "\033[95m";
		static constexpr const char* bright_cyan = "\033[96m";
		static constexpr const char* bright_white = "\033[97m";

		// background colors
		static constexpr const char* bg_black = "\033[40m";
		static constexpr const char* bg_red = "\033[41m";
		static constexpr const char* bg_green = "\033[42m";
		static constexpr const char* bg_yellow = "\033[43m";
		static constexpr const char* bg_blue = "\033[44m";
		static constexpr const char* bg_magenta = "\033[45m";
		static constexpr const char* bg_cyan = "\033[46m";
		static constexpr const char* bg_white = "\033[47m";

		// bright background colors
		static constexpr const char* bg_bright_black = "\033[100m";
		static constexpr const char* bg_bright_red = "\033[101m";
		static constexpr const char* bg_bright_green = "\033[102m";
		static constexpr const char* bg_bright_yellow = "\033[103m";
		static constexpr const char* bg_bright_blue = "\033[104m";
		static constexpr const char* bg_bright_magenta = "\033[105m";
		static constexpr const char* bg_bright_cyan = "\033[106m";
		static constexpr const char* bg_bright_white = "\033[107m";

		// cycle through foreground colors
		static const char* next_color() {
			static constexpr const char* fg_colors[] = {
				black, red, green, yellow, blue, magenta, cyan, white,
				bright_black, bright_red, bright_green, bright_yellow,
				bright_blue, bright_magenta, bright_cyan, bright_white
			};

			static std::size_t index = 0;
			const char* color = fg_colors[index];
			index = (index + 1) % (sizeof(fg_colors) / sizeof(fg_colors[0]));
			return color;
		}

		// cycle through background colors
		static const char* next_bg() {
			static constexpr const char* bg_colors[] = {
				bg_black, bg_red, bg_green, bg_yellow,
				bg_blue, bg_magenta, bg_cyan, bg_white,
				bg_bright_black, bg_bright_red, bg_bright_green, bg_bright_yellow,
				bg_bright_blue, bg_bright_magenta, bg_bright_cyan, bg_bright_white
			};

			static std::size_t index = 0;
			const char* color = bg_colors[index];
			index = (index + 1) % (sizeof(bg_colors) / sizeof(bg_colors[0]));
			return color;
		}
	};

	// Extended diagnostic with support for generic annotations and additional context
	struct diagnostic {
		struct annotation {
			source_location::pair position;
			std::string message; // The annotation message to display
			std::string color = ansi::magenta;; // Optional color override (defaults to magenta if empty)
		};

		enum Kind {
			info,
			note,
			warning,
			error
		} kind;
		std::optional<size_t> code = {};
		std::string message;
		diagnose::source_location::detailed location;

		std::vector<annotation> annotations;
		std::string context_message; // e.g., "The values are outputs of this match expression"
		std::string additional_note; // e.g., "Outputs of match expressions must coerce to the same type"

		diagnostic& push_annotation(annotation a) {
			annotations.push_back(std::move(a));
			return *this;
		}

		diagnostic& push_annotation_at_start(annotation a) {
			a.position = location.start;
			return push_annotation(std::move(a));
		}

		diagnostic& push_annotation_at_end(annotation a) {
			a.position = location.end;
			return push_annotation(std::move(a));
		}
	};

	struct manager {
		std::vector<diagnostic> diagnostics;
		std::unordered_map<std::string_view, std::string_view> source_files;

		std::string get_kind_prefix(diagnostic::Kind kind) const {
			switch (kind) {
				case diagnostic::info: return std::string(ansi::cyan) + ansi::bold + "Info" + ansi::reset;
				case diagnostic::note: return std::string(ansi::blue) + ansi::bold + "Note" + ansi::reset;
				case diagnostic::warning: return std::string(ansi::yellow) + ansi::bold + "Warning" + ansi::reset;
				case diagnostic::error: return std::string(ansi::red) + ansi::bold + "Error" + ansi::reset;
				default: return "Unknown";
			}
		}

		constexpr static const char* get_kind_color(diagnostic::Kind kind) {
			switch (kind) {
				case diagnostic::info: return ansi::cyan;
				case diagnostic::note: return ansi::blue;
				case diagnostic::warning: return ansi::yellow;
				case diagnostic::error: return ansi::red;
				default: return ansi::reset;
			}
		}

		void print_diagnostic_header(const diagnostic& diag, std::ostream& out) const {
			if(diag.code)
				out << get_kind_color(diag.kind) << ansi::bold << "[E" << std::setfill('0') << std::setw(3) << *diag.code << "] ";

			out << get_kind_prefix(diag.kind) << ": " << ansi::reset << ansi::bold
				<< diag.message << ansi::reset << "\n";

			out << " " << ansi::cyan << ansi::bold << "┌─" << diag.location << ansi::reset << "\n";
		}

		void print_source_context(const diagnostic& diag, std::string_view source, std::ostream& out) const {
			size_t start_line = diag.location.start.line;
			size_t end_line = diag.location.end.line;
			std::vector<size_t> lines_to_print; lines_to_print.resize(end_line - start_line + 1);
			std::iota(lines_to_print.begin(), lines_to_print.end(), start_line);

			std::set<size_t> line_set(lines_to_print.begin(), lines_to_print.end());
			for(auto& annotation: diag.annotations)
				line_set.insert(annotation.position.line);
			lines_to_print = std::vector<size_t>(line_set.begin(), line_set.end());
			std::sort(lines_to_print.begin(), lines_to_print.end());

			auto lines = split(source, '\n');
			size_t line_num_width = std::to_string(end_line).length();

			auto kind_color = get_kind_color(diag.kind);

			// Print source lines
			for (size_t line_num: lines_to_print) {
				if (line_num > lines.size()) break;

				std::string line_str = std::string(lines[line_num - 1]);

				// Line number prefix with arrow
				out << " " << ansi::cyan << ansi::bold
					<< std::setw(line_num_width) << line_num
					<< " │ " << ansi::reset << kind_color << "➤ " << ansi::reset;

				// Print the line content with highlighting
				// Column 0 means end of line
				size_t start_col = (line_num == start_line) ?
					(diag.location.start.column == 0 ? line_str.length() + 1 : diag.location.start.column) : 1;
				size_t end_col = (line_num == end_line) ?
					(diag.location.end.column == 0 ? line_str.length() + 1 : diag.location.end.column) : line_str.length() + 1;

				// Print text before highlight
				if (start_col > 1)
					out << line_str.substr(0, start_col - 1);

				// Print highlighted text
				size_t highlight_start = start_col - 1;
				size_t highlight_len = std::min(end_col - start_col, line_str.length() - highlight_start);
				if (highlight_len > 0)
					out << kind_color << ansi::bold << line_str.substr(highlight_start, highlight_len) << ansi::reset;

				// Print text after highlight
				if (end_col - 1 < line_str.length())
					out << line_str.substr(end_col - 1);

				out << "\n";

				// Collect and sort annotations for this line by column
				std::vector<const diagnostic::annotation*> line_annotations;
				for (const auto& annotation : diag.annotations)
					if (annotation.position.line == line_num)
						line_annotations.push_back(&annotation);

				// Sort by column (treating 0 as end of line)
				std::sort(line_annotations.begin(), line_annotations.end(),
					[&line_str](const diagnostic::annotation* a, const diagnostic::annotation* b) {
						size_t col_a = a->position.column == 0 ? line_str.length() + 1 : a->position.column;
						size_t col_b = b->position.column == 0 ? line_str.length() + 1 : b->position.column;
						return col_a > col_b;
					});

				// Print annotations for this line
				if (!line_annotations.empty())
					print_annotations_for_line(line_annotations, line_num_width, line_str, out);
			}

			// Print continuation dots
			out << " " << ansi::cyan << ansi::bold;
			out << std::string(line_num_width, ' ') << " ·" << ansi::reset << "\n";

			out << " " << ansi::cyan << ansi::bold;
			out << std::string(line_num_width, ' ') << " ·" << ansi::reset << "\n";

			// Print context message and additional notes
			auto context_message = diag.context_message;
			if (!context_message.empty()) {
				out << " " << ansi::cyan << ansi::bold;
				out << std::string(line_num_width, ' ') << " └─" << ansi::reset << " ";
				out << context_message << "\n";
			}

			auto additional_note = diag.additional_note;
			if (!additional_note.empty()) {
				out << " " << ansi::cyan << ansi::bold;
				out << std::string(line_num_width, ' ') << " ·" << ansi::reset << "\n";

				out << " " << ansi::cyan << ansi::bold;
				out << std::string(line_num_width, ' ') << " " << ansi::reset;
				out << ansi::blue << ansi::bold << "Note:" << ansi::reset << " ";
				out << additional_note << "\n";
			}
		}

		void print_annotations_for_line(
			const std::vector<const diagnostic::annotation*>& sorted_annotations,
			size_t line_num_width, const std::string& line_str, std::ostream& out
		) const {
			// Build a list of column positions for all annotations
			std::vector<size_t> annotation_columns;
			for (const auto* ann : sorted_annotations) {
				size_t actual_column = ann->position.column == 0 ? line_str.length() + 1 : ann->position.column;
				annotation_columns.push_back(actual_column);
			}

			// Print each annotation line
			for (size_t i = 0; i < sorted_annotations.size(); ++i) {
				const auto& annotation = *sorted_annotations[i];
				size_t actual_column = annotation_columns[i];

				out << "  " << ansi::cyan << ansi::bold;
				out << std::string(line_num_width, ' ') << "│ " << ansi::reset << "  ";

				// For each position, either print a space, vertical bar, or connector
				for (size_t col = 1; col < actual_column; ++col) {
					bool has_later_annotation = false;
					// Check if any later annotation has a bar at this column
					for (size_t j = i + 1; j < sorted_annotations.size(); ++j) {
						if (annotation_columns[j] == col) {
							// Use the color of that annotation
							auto later_color = sorted_annotations[j]->color;
							out << later_color << "│" << ansi::reset;
							has_later_annotation = true;
							break;
						}
					}
					if (!has_later_annotation)
						out << " ";
				}

				// Print the connector and message
				out << annotation.color << "└─ " << ansi::reset << annotation.message << "\n";
			}
		}

		// Add an enhanced diagnostic with type annotations
		diagnostic& push(diagnostic diag) {
			return diagnostics.emplace_back(std::move(diag));
		}

		// Register source code for a file
		void register_source(std::string_view filename, std::string_view source) {
			source_files[filename] = source;
		}

		// Print all diagnostics in Ariadne style
		void print_all(std::ostream& out = nowide::cerr) const {
			for (const auto& diag : diagnostics) {
				print_diagnostic_header(diag, out);

				auto it = source_files.find(diag.location.file);
				if (it != source_files.end())
					print_source_context(diag, it->second, out);
				else out << " " << ansi::yellow << "(source not available)" << ansi::reset << "\n";

				out << " " << ansi::cyan << ansi::bold << "└─" << ansi::reset << "\n";
				out << "\n";
			}

			// Print summary
			if (!diagnostics.empty()) {
				size_t error_count = std::count_if(diagnostics.begin(), diagnostics.end(), [](const diagnostic& d) { return d.kind == diagnostic::error; });
				size_t warning_count = std::count_if(diagnostics.begin(), diagnostics.end(), [](const diagnostic& d) { return d.kind == diagnostic::warning; });

				if (error_count > 0 || warning_count > 0) {
					out << ansi::bold;
					if (error_count > 0)
						out << ansi::red << error_count << " error" << (error_count != 1 ? "s" : "") << ansi::reset;

					if (error_count > 0 && warning_count > 0)
						out << ansi::bold << ", " << ansi::reset;

					if (warning_count > 0)
						out << ansi::bold << ansi::yellow << warning_count << " warning"
							<< (warning_count != 1 ? "s" : "") << ansi::reset;

					out << ansi::bold << " generated." << ansi::reset << "\n";
				}
			}
		}

		// Check if there are any errors
		bool has_errors() const {
			return std::any_of(diagnostics.begin(), diagnostics.end(), [](const diagnostic& d) { return d.kind == diagnostic::error; });
		}

		// Get diagnostic count
		size_t count() const {
			return diagnostics.size();
		}

		// Clear all diagnostics
		void clear() {
			diagnostics.clear();
		}

		// Get all diagnostics
		const std::vector<diagnostic>& get_diagnostics() const {
			return diagnostics;
		}
	};

} // namespace diagnose
