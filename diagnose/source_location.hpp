#pragma once
#include "string_helpers.hpp"

#include <cassert>
#include <string_view>
#include <ostream>

namespace diagnose {
	struct source_location {
		struct pair {
			size_t line = 1, column = 1;

			size_t to_byte(std::string_view source) {
			    size_t line = 1;
			    size_t column = 1;

			    for (size_t i = 0; i < source.size(); ++i) {
			        if (line == this->line && column == this->column)
			            return i;

			        if (source[i] == '\n') {
			            ++line;
			            column = 1;
			        } else
			            ++column;
			    }

			    // Allow pointing one-past-the-end (e.g. EOF)
			    if (line == this->line && column == this->column)
			        return source.size();

			    assert(false && "pair out of range for source");
			    return source.size();
			}
		};

		struct detailed {
			std::string_view file;
			pair start, end;

			source_location to_bytes(std::string_view source) {
				return {file, start.to_byte(source), end.to_byte(source)};
			}

			friend std::ostream& operator<<(std::ostream& out, const diagnose::source_location::detailed& loc) {
				out << " <\"" << loc.file << "\":";
				if(loc.start.line == loc.end.line)
					out << loc.start.line << ":";
				else out << loc.start.line << "-" << loc.end.line << ":";
				if(loc.start.column == loc.end.column)
					out << loc.start.column << ">";
				else out << loc.start.column << "-" << loc.end.column << ">";
				return out;
			}
		};

		std::string_view file;
		size_t start_byte, end_byte;

		static source_location from_substring(std::string_view source, std::string_view substring, std::string_view file = "<unknown>") {
			size_t start_byte = substring.data() - source.data();
			size_t end_byte = start_byte + substring.size();
			return {file, start_byte, end_byte};
		}

	 	pair find_pair(std::string_view source, size_t target_byte) const {
			assert(target_byte <= source.size());

			pair out = {1, 1};
			size_t line_start = 0;

			for (size_t i = 0; i < target_byte; ++i) {
				if (source[i] == '\n') {
					++out.line;
					out.column = 1;
					line_start = i + 1;
				} else {
					++out.column;
				}
			}

			return out;
		}

		pair start(std::string_view source) const { return find_pair(source, start_byte); }
		size_t start_line(std::string_view source) const { return start(source).line; }
		size_t start_column(std::string_view source) const { return start(source).column; }

		pair end(std::string_view source) const { return find_pair(source, end_byte); }
		size_t end_line(std::string_view source) const { return end(source).line; }
		size_t end_column(std::string_view source) const { return end(source).column; }

		detailed to_detailed(std::string_view source) const {
			return {file, start(source), end(source)};
		}
	};
}
