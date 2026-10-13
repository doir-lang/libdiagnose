/// Positions within source text, as 1-based line/column pairs or as byte offsets, and conversions between them.
module diagnose.source_location;

static import fp.string;

@nogc nothrow:


/// A 1-based line and byte column within some source text.
struct Pair {
	size_t line = 1; /// The 1-based line.
	size_t column = 1; /// The 1-based byte column within `line`.
}

/// A file and a byte range within its source text, resolvable to line/column pairs against that text.
struct SourceLocation {
	const(char)[] file; /// The file's name, as registered with a `diagnose.diagnostics.Manager`.
	size_t startByte; /// The byte offset where the range starts.
	size_t endByte; /// The byte offset one past where the range ends.
}

/// A file and a line/column range within it, ready to display.
struct Detailed {
	const(char)[] file; /// The file's name, as registered with a `diagnose.diagnostics.Manager`.
	Pair start; /// Where the range starts.
	Pair end; /// Where the range ends.
}


/// The byte offset `pair` refers to in `source`, which may be one past the end. `pair` must lie within `source`.
///
/// Examples:
/// ---
/// assert(toByte(Pair(2, 1), "abc\ndef") == 4);
/// assert(toByte(Pair(2, 4), "abc\ndef") == 7);
/// ---
size_t toByte(Pair pair, const(char)[] source) {
	size_t line = 1;
	size_t column = 1;
	foreach (i; 0 .. source.length) {
		if (line == pair.line && column == pair.column)
			return i;
		if (source[i] == '\n') {
			++line;
			column = 1;
		} else ++column;
	}
	assert(line == pair.line && column == pair.column, "diagnose.source_location: pair out of range for source");
	return source.length;
}

/// The line/column pair byte offset `targetByte` of `source` lies at, which must be at most `source.length`.
///
/// Examples:
/// ---
/// assert(findPair("abc\ndef", 5) == Pair(2, 2));
/// ---
Pair findPair(const(char)[] source, size_t targetByte) {
	assert(targetByte <= source.length, "diagnose.source_location: byte out of range for source");
	Pair result;
	foreach (i; 0 .. targetByte) {
		if (source[i] == '\n') {
			++result.line;
			result.column = 1;
		} else ++result.column;
	}
	return result;
}


/// The location of `substring`, which must be a slice of `source`, within it.
///
/// Examples:
/// ---
/// static immutable source = "one two";
/// SourceLocation loc = fromSubstring(source, source[4 .. 7], "a.c");
/// assert(loc == SourceLocation("a.c", 4, 7));
/// ---
SourceLocation fromSubstring(const(char)[] source, const(char)[] substring, const(char)[] file = "<unknown>") @trusted {
	assert(substring.ptr >= source.ptr && substring.ptr + substring.length <= source.ptr + source.length, "diagnose.source_location: substring is not a slice of source");
	immutable start = cast(size_t)(substring.ptr - source.ptr);
	return SourceLocation(file, start, start + substring.length);
}

/// Where `loc` starts in `source`, the text it was cut from.
///
/// Examples:
/// ---
/// assert(start(SourceLocation("a.c", 4, 6), "abc\ndef") == Pair(2, 1));
/// ---
Pair start(SourceLocation loc, const(char)[] source) { return findPair(source, loc.startByte); }

/// The line `loc` starts on in `source`.
///
/// Examples:
/// ---
/// assert(startLine(SourceLocation("a.c", 4, 6), "abc\ndef") == 2);
/// ---
size_t startLine(SourceLocation loc, const(char)[] source) { return start(loc, source).line; }

/// The column `loc` starts at in `source`.
///
/// Examples:
/// ---
/// assert(startColumn(SourceLocation("a.c", 5, 6), "abc\ndef") == 2);
/// ---
size_t startColumn(SourceLocation loc, const(char)[] source) { return start(loc, source).column; }

/// Where `loc` ends in `source`, the text it was cut from.
///
/// Examples:
/// ---
/// assert(end(SourceLocation("a.c", 0, 6), "abc\ndef") == Pair(2, 3));
/// ---
Pair end(SourceLocation loc, const(char)[] source) { return findPair(source, loc.endByte); }

/// The line `loc` ends on in `source`.
///
/// Examples:
/// ---
/// assert(endLine(SourceLocation("a.c", 0, 6), "abc\ndef") == 2);
/// ---
size_t endLine(SourceLocation loc, const(char)[] source) { return end(loc, source).line; }

/// The column `loc` ends at in `source`.
///
/// Examples:
/// ---
/// assert(endColumn(SourceLocation("a.c", 0, 6), "abc\ndef") == 3);
/// ---
size_t endColumn(SourceLocation loc, const(char)[] source) { return end(loc, source).column; }


/// `loc` resolved to line/column pairs against `source`.
///
/// Examples:
/// ---
/// assert(toDetailed(SourceLocation("a.c", 4, 6), "abc\ndef") == Detailed("a.c", Pair(2, 1), Pair(2, 3)));
/// ---
Detailed toDetailed(SourceLocation loc, const(char)[] source) {
	return Detailed(loc.file, start(loc, source), end(loc, source));
}

/// `location` resolved to byte offsets against `source`, which its pairs must lie within.
///
/// Examples:
/// ---
/// assert(toBytes(Detailed("a.c", Pair(2, 1), Pair(2, 3)), "abc\ndef") == SourceLocation("a.c", 4, 6));
/// ---
SourceLocation toBytes(Detailed location, const(char)[] source) {
	return SourceLocation(location.file, toByte(location.start, source), toByte(location.end, source));
}

/// `location` as a new fp string ` <"file":line:column>`, giving a range for the line or column where start and end differ. The caller frees it with `fp.string.free`.
///
/// Returns null if an allocation was refused.
///
/// Examples:
/// ---
/// char* text = toDisplayString(Detailed("a.c", Pair(2, 3), Pair(4, 3)));
/// scope(exit) fp.string.free(text);
/// assert(fp.string.equal(text, ` <"a.c":2-4:3>`));
/// ---
char* toDisplayString(Detailed location) {
	char* out_ = null;
	bool ok = fp.string.concatenateMultiple(out_, " <\"", location.file, "\":", location.start.line) !is null;
	if (ok && location.start.line != location.end.line) ok = fp.string.concatenateMultiple(out_, "-", location.end.line) !is null;
	if (ok) ok = fp.string.concatenateMultiple(out_, ":", location.start.column) !is null;
	if (ok && location.start.column != location.end.column) ok = fp.string.concatenateMultiple(out_, "-", location.end.column) !is null;
	if (ok) ok = fp.string.concatenate(out_, ">") !is null;
	if (!ok) fp.string.free(out_);
	return out_;
}


version(unittest) {
	static import fp.pointer;

	// Thread-local, like `fp.pointer.allocFunction`, which it wraps.
	private size_t allocationsLeft;
	private fp.pointer.AllocFunction realAllocFunction;

	private void* failingAllocFunction(void* p, size_t size) {
		// A size of 0 is a free, which must neither fail nor count.
		if (size == 0 || allocationsLeft-- > 0) return realAllocFunction(p, size);
		stopFailing();
		return null;
	}

	/// Lets the next `n` allocations through `fp.pointer` succeed and refuses the one after, then lets later ones succeed. It exists only in unittest builds.
	///
	/// Examples:
	/// ---
	/// failAfter(0);
	/// assert(fp.string.makeDynamic("x") is null);
	/// char* s = fp.string.makeDynamic("x");
	/// assert(s !is null);
	/// fp.string.free(s);
	/// ---
	package void failAfter(size_t n) {
		// Re-arming must not save the failing allocator as the real one, or every allocation would recurse forever.
		if (fp.pointer.allocFunction !is &failingAllocFunction) realAllocFunction = fp.pointer.allocFunction;
		allocationsLeft = n;
		fp.pointer.allocFunction = &failingAllocFunction;
	}

	/// Cancels a failure `failAfter` arranged that has not happened yet. It exists only in unittest builds.
	///
	/// Examples:
	/// ---
	/// failAfter(5);
	/// stopFailing();
	/// ---
	package void stopFailing() {
		if (fp.pointer.allocFunction is &failingAllocFunction) fp.pointer.allocFunction = realAllocFunction;
	}
}


unittest {
	static immutable source = "abc\ndef\ngh";

	assert(toByte(Pair(1, 1), source) == 0);
	assert(toByte(Pair(2, 1), source) == 4);
	assert(toByte(Pair(3, 2), source) == 9);
	assert(toByte(Pair(3, 3), source) == source.length);
	assert(findPair(source, 0) == Pair(1, 1));
	assert(findPair(source, source.length) == Pair(3, 3));

	SourceLocation loc = SourceLocation("f", 4, 9);
	assert(start(loc, source) == Pair(2, 1));
	assert(end(loc, source) == Pair(3, 2));
	assert(startLine(loc, source) == 2);
	assert(startColumn(loc, source) == 1);
	assert(endLine(loc, source) == 3);
	assert(endColumn(loc, source) == 2);

	static immutable words = "one two three";
	SourceLocation unnamed = fromSubstring(words, words[4 .. 7]);
	assert(unnamed == SourceLocation("<unknown>", 4, 7));
	assert(fromSubstring(words, words[4 .. 7], "custom.c").file == "custom.c");

	Detailed detailed = toDetailed(loc, source);
	assert(detailed == Detailed("f", Pair(2, 1), Pair(3, 2)));
	assert(toBytes(detailed, source) == loc);

	char* same = toDisplayString(Detailed("f", Pair(2, 3), Pair(2, 3)));
	scope(exit) fp.string.free(same);
	assert(fp.string.equal(same, ` <"f":2:3>`));

	char* range = toDisplayString(Detailed("f", Pair(2, 3), Pair(4, 5)));
	scope(exit) fp.string.free(range);
	assert(fp.string.equal(range, ` <"f":2-4:3-5>`));

	// Each allocation in turn is refused, until there are enough for the whole string.
	for (size_t n = 0;; ++n) {
		failAfter(n);
		char* text = toDisplayString(Detailed("f", Pair(2, 3), Pair(4, 5)));
		stopFailing();
		if (text is null) continue;
		assert(fp.string.equal(text, ` <"f":2-4:3-5>`));
		fp.string.free(text);
		break;
	}
}
