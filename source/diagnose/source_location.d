module diagnose.source_location;

import fp.string : concatenateSlice, concatenate, format, free, equal;

@nogc nothrow:

/// A line/column position within some source text.
struct Pair {
	size_t line = 1;
	size_t column = 1;

	@nogc nothrow:

	/// Converts this line/column position to a byte offset into `source`.
	/// Allows pointing one-past-the-end (e.g. EOF).
	size_t toByte(const(char)[] source) const @trusted {
		size_t curLine = 1;
		size_t curColumn = 1;

		foreach (i; 0 .. source.length) {
			if (curLine == line && curColumn == column)
				return i;

			if (source[i] == '\n') {
				++curLine;
				curColumn = 1;
			} else ++curColumn;
		}

		if (curLine == line && curColumn == column)
			return source.length;

		assert(false); // pair out of range for source
	}
}

/// A resolved (file, line/column range) location, ready to display.
struct Detailed {
	const(char)[] file;
	Pair start, end;

	@nogc nothrow:

	SourceLocation toBytes(const(char)[] source) const {
		return SourceLocation(file, start.toByte(source), end.toByte(source));
	}

	/// Renders this location as ` <"file":line:col>` (or a line/column range
	/// when start and end differ). Returns a newly heap-allocated fp string;
	/// the caller must free it.
	char* toDisplayString() const @trusted {
		char* out_ = null;
		concatenateSlice(out_, " <\"");
		concatenateSlice(out_, file);
		concatenateSlice(out_, "\":");
		appendSize(out_, start.line);
		if (start.line != end.line) {
			concatenateSlice(out_, "-");
			appendSize(out_, end.line);
		}
		concatenateSlice(out_, ":");
		appendSize(out_, start.column);
		if (start.column != end.column) {
			concatenateSlice(out_, "-");
			appendSize(out_, end.column);
		}
		concatenateSlice(out_, ">");
		return out_;
	}
}

/// A (file, byte range) location, resolvable to line/column pairs against
/// the source text it was cut from.
struct SourceLocation {
	const(char)[] file;
	size_t startByte, endByte;

	@nogc nothrow:

	static SourceLocation fromSubstring(
		const(char)[] source, const(char)[] substring, const(char)[] file = "<unknown>"
	) @trusted {
		immutable start = cast(size_t)(substring.ptr - source.ptr);
		return SourceLocation(file, start, start + substring.length);
	}

	Pair findPair(const(char)[] source, size_t targetByte) const @trusted {
		assert(targetByte <= source.length);

		Pair result = Pair(1, 1);
		foreach (i; 0 .. targetByte) {
			if (source[i] == '\n') {
				++result.line;
				result.column = 1;
			} else ++result.column;
		}
		return result;
	}

	Pair start(const(char)[] source) const { return findPair(source, startByte); }
	size_t startLine(const(char)[] source) const { return start(source).line; }
	size_t startColumn(const(char)[] source) const { return start(source).column; }

	Pair end(const(char)[] source) const { return findPair(source, endByte); }
	size_t endLine(const(char)[] source) const { return end(source).line; }
	size_t endColumn(const(char)[] source) const { return end(source).column; }

	Detailed toDetailed(const(char)[] source) const {
		return Detailed(file, start(source), end(source));
	}
}

/// Appends the decimal representation of `value` to the fp string `buf`.
package void appendSize(ref char* buf, size_t value) @trusted {
	char* rendered = format("%zu".ptr, value);
	scope(exit) free(rendered);
	concatenate(buf, rendered);
}

unittest {
	static immutable(char)[] source = "abc\ndef\ngh";

	// "abc\ndef\ngh": byte 0 is (1,1); byte 4 ('d') is (2,1); byte 9 ('h', the
	// last char) is (3,2); (3,3) is one-past-the-end (== source.length).
	assert(Pair(1, 1).toByte(source) == 0);
	assert(Pair(2, 1).toByte(source) == 4);
	assert(Pair(3, 2).toByte(source) == 9);
	assert(Pair(3, 3).toByte(source) == source.length); // one-past-the-end

	SourceLocation loc = SourceLocation("f", 4, 9);
	assert(loc.start(source) == Pair(2, 1));
	assert(loc.end(source) == Pair(3, 2));
	assert(loc.startLine(source) == 2);
	assert(loc.endColumn(source) == 2);
}

unittest {
	Detailed same = Detailed("f", Pair(2, 3), Pair(2, 3));
	char* rendered = same.toDisplayString();
	scope (exit) free(rendered);
	assert(equal(rendered, ` <"f":2:3>`.ptr));
}

unittest {
	Detailed range = Detailed("f", Pair(2, 3), Pair(4, 5));
	char* rendered = range.toDisplayString();
	scope (exit) free(rendered);
	assert(equal(rendered, ` <"f":2-4:3-5>`.ptr));
}

unittest {
	static immutable(char)[] source = "abc\ndef\ngh";

	SourceLocation loc = SourceLocation("f", 4, 9);
	assert(loc.startColumn(source) == 1);
	assert(loc.endLine(source) == 3);

	Detailed detailed = loc.toDetailed(source);
	assert(detailed.file == "f");
	assert(detailed.start == Pair(2, 1));
	assert(detailed.end == Pair(3, 2));

	SourceLocation roundTrip = detailed.toBytes(source);
	assert(roundTrip.startByte == 4);
	assert(roundTrip.endByte == 9);
}

unittest {
	static immutable(char)[] source = "one two three";
	const(char)[] substring = source[4 .. 7]; // "two"

	SourceLocation loc = SourceLocation.fromSubstring(source, substring);
	assert(loc.file == "<unknown>");
	assert(loc.startByte == 4);
	assert(loc.endByte == 7);

	SourceLocation named = SourceLocation.fromSubstring(source, substring, "custom.c");
	assert(named.file == "custom.c");
}
