/// Positions within source text, as 1-based line/column pairs or as byte offsets, and conversions between them.
module diagnose.source_location;

static import std.typecons;

static import fp.pointer;
static import fp.rope;
static import fp.string;
static import fp.string.ascii;
static import fp.string.numbers;

@nogc nothrow:


/// A 1-based line and byte column within some source text.
struct LineColumn {
	size_t line = 1; /// The 1-based line.
	size_t column = 1; /// The 1-based byte column within `line`.
}

/// A file and a byte range within its source text, resolvable to line/column pairs against that text.
struct ByteRange {
	const(char)[] file; /// The file's name, as registered with a `diagnose.diagnostics.Manager`.
	size_t startByte; /// The byte offset where the range starts.
	size_t endByte; /// The byte offset one past where the range ends.
}

/// A file and a line/column range within it, ready to display.
struct LineColumnRange {
	const(char)[] file; /// The file's name, as registered with a `diagnose.diagnostics.Manager`.
	LineColumn start; /// Where the range starts.
	LineColumn end; /// Where the range ends.
}


/// The byte offset `pair` refers to in `source`, which may be one past the end. `pair` must lie within `source`.
///
/// Examples:
/// ---
/// assert(byteOffset(LineColumn(2, 1), "abc\ndef") == 4);
/// assert(byteOffset(LineColumn(2, 4), "abc\ndef") == 7);
/// ---
size_t byteOffset(LineColumn pair, const(char)[] source) {
	immutable lineStart = pair.line <= 1 ? 0 : fp.string.lineStart(source, pair.line - 1);
	assert(lineStart != fp.pointer.notFound && lineStart + pair.column - 1 <= source.length, "diagnose.source_location: pair out of range for source");
	return lineStart + pair.column - 1;
}

/// The line and column byte offset `at` of `source` lies at, which must be at most `source.length`.
///
/// Examples:
/// ---
/// assert(lineColumn("abc\ndef", 5) == LineColumn(2, 2));
/// ---
LineColumn lineColumn(const(char)[] source, size_t at) {
	assert(at <= source.length, "diagnose.source_location: byte out of range for source");
	immutable line = fp.string.lineOf(source, at);
	return LineColumn(LineColumn.init.line + line, at - fp.string.lineStart(source, line) + 1);
}

/// The line and column byte offset `at` of `text` lies at, which must be at most its length. A rope keeps its line starts, so this costs O(log n) rather than a scan.
///
/// Examples:
/// ---
/// static import fp.rope;
/// auto text = fp.rope.create("abc\ndef").get;
/// scope(exit) fp.rope.free(text);
/// assert(lineColumn(text, 5) == LineColumn(2, 2));
/// ---
LineColumn lineColumn(const fp.rope.Rope text, size_t at) {
	immutable line = fp.rope.lineOf(text, at);
	return LineColumn(line + 1, at - fp.rope.lineStart(text, line) + 1);
}


/// The location of `substring`, which must be a slice of `source`, within it.
///
/// Examples:
/// ---
/// static immutable source = "one two";
/// ByteRange location = fromSubstring(source, source[4 .. 7], "a.c");
/// assert(location == ByteRange("a.c", 4, 7));
/// ---
ByteRange fromSubstring(const(char)[] source, const(char)[] substring, const(char)[] file = "<unknown>") @trusted {
	assert(substring.ptr >= source.ptr && substring.ptr + substring.length <= source.ptr + source.length, "diagnose.source_location: substring is not a slice of source");
	immutable start = cast(size_t)(substring.ptr - source.ptr);
	return ByteRange(file, start, start + substring.length);
}


/// `location` resolved to lines and columns against `source`, the text it was cut from.
///
/// Examples:
/// ---
/// assert(resolve(ByteRange("a.c", 4, 6), "abc\ndef") == LineColumnRange("a.c", LineColumn(2, 1), LineColumn(2, 3)));
/// ---
LineColumnRange resolve(ByteRange location, const(char)[] source) {
	return LineColumnRange(location.file, lineColumn(source, location.startByte), lineColumn(source, location.endByte));
}

/// `location` resolved to lines and columns against `text`, the rope it was cut from, in O(log n).
///
/// Examples:
/// ---
/// static import fp.rope;
/// auto text = fp.rope.create("abc\ndef").get;
/// scope(exit) fp.rope.free(text);
/// assert(resolve(ByteRange("a.c", 4, 6), text) == LineColumnRange("a.c", LineColumn(2, 1), LineColumn(2, 3)));
/// ---
LineColumnRange resolve(ByteRange location, const fp.rope.Rope text) {
	return LineColumnRange(location.file, lineColumn(text, location.startByte), lineColumn(text, location.endByte));
}

/// `location` resolved to byte offsets against `source`, which its lines and columns must lie within.
///
/// Examples:
/// ---
/// assert(byteRange(LineColumnRange("a.c", LineColumn(2, 1), LineColumn(2, 3)), "abc\ndef") == ByteRange("a.c", 4, 6));
/// ---
ByteRange byteRange(LineColumnRange location, const(char)[] source) {
	return ByteRange(location.file, byteOffset(location.start, source), byteOffset(location.end, source));
}


/// `location` as a new fp string `<"file":line:column>`, giving a range for the line or column where start and end differ; `parseDisplay` reads it back. The caller frees it with `fp.string.free`.
///
/// Returns null if an allocation was refused.
///
/// Examples:
/// ---
/// char* text = display(LineColumnRange("a.c", LineColumn(2, 3), LineColumn(4, 3)));
/// scope(exit) fp.string.free(text);
/// assert(fp.string.equal(text, `<"a.c":2-4:3>`));
/// ---
char* display(LineColumnRange location) {
	char* out_ = null;
	bool ok = fp.string.append(out_, "<\"", location.file, "\":", location.start.line);
	if (ok && location.start.line != location.end.line) ok = fp.string.append(out_, "-", location.end.line);
	if (ok) ok = fp.string.append(out_, ":", location.start.column);
	if (ok && location.start.column != location.end.column) ok = fp.string.append(out_, "-", location.end.column);
	if (ok) ok = fp.string.append(out_, ">");
	if (!ok) fp.string.free(out_);
	return out_;
}

// Reads a run of decimal digits at `text[at]` into `value`, advancing `at`. False if there is none or it overflows.
private bool readNumber(const(char)[] text, ref size_t at, out size_t value) {
	immutable start = at;
	while (at < text.length && fp.string.ascii.isDigit(text[at])) ++at;
	auto parsed = fp.string.numbers.parseUnsigned(text[start .. at]);
	if (parsed.isNull || parsed.get.value > size_t.max) return false;
	value = cast(size_t) parsed.get.value;
	return true;
}

// Reads `number` or `number-number` at `text[at]`, the second defaulting to the first.
private bool readSpan(const(char)[] text, ref size_t at, out size_t first, out size_t last) {
	if (!readNumber(text, at, first)) return false;
	last = first;
	if (at < text.length && text[at] == '-') {
		++at;
		return readNumber(text, at, last);
	}
	return true;
}

/// Reads `text`, a location as `display` writes it, back into a range whose `file` is a slice of `text`: `<"file":line:column>`, the line and column each a number or a `first-last` range. Returns null if `text` is not entirely such a location, or a number overflows.
///
/// Examples:
/// ---
/// auto read = parseDisplay(`<"a.c":2-4:3>`);
/// assert(read.get == LineColumnRange("a.c", LineColumn(2, 3), LineColumn(4, 3)));
/// assert(parseDisplay(`<"a.c":2>`).isNull && parseDisplay(`<a.c:2:3>`).isNull);
/// ---
std.typecons.Nullable!LineColumnRange parseDisplay(const(char)[] text) {
	if (!fp.string.startsWith(text, "<\"")) return typeof(return).init;
	immutable close = fp.string.find(text, "\"", 2);
	if (close == fp.pointer.notFound || !fp.string.startsWith(text, "\":", close)) return typeof(return).init;
	LineColumnRange out_;
	out_.file = text[2 .. close];
	size_t at = close + 2;
	if (!readSpan(text, at, out_.start.line, out_.end.line)) return typeof(return).init;
	if (at >= text.length || text[at++] != ':') return typeof(return).init;
	if (!readSpan(text, at, out_.start.column, out_.end.column)) return typeof(return).init;
	if (at + 1 != text.length || text[at] != '>') return typeof(return).init;
	return typeof(return)(out_);
}


version(unittest) static import fp.testing;


unittest {
	static immutable source = "abc\ndef\ngh";

	assert(byteOffset(LineColumn(1, 1), source) == 0);
	assert(byteOffset(LineColumn(2, 1), source) == 4);
	assert(byteOffset(LineColumn(3, 2), source) == 9);
	assert(byteOffset(LineColumn(3, 3), source) == source.length);
	assert(lineColumn(source, 0) == LineColumn(1, 1));
	assert(lineColumn(source, 3) == LineColumn(1, 4)); // the newline itself ends line 1
	assert(lineColumn(source, source.length) == LineColumn(3, 3));

	// A rope answers as the flat text does, at every offset.
	auto rope = fp.rope.create(source).get;
	scope(exit) fp.rope.free(rope);
	foreach (at; 0 .. source.length + 1) assert(lineColumn(rope, at) == lineColumn(source, at));

	ByteRange location = ByteRange("f", 4, 9);
	static immutable words = "one two three";
	ByteRange unnamed = fromSubstring(words, words[4 .. 7]);
	assert(unnamed == ByteRange("<unknown>", 4, 7));
	assert(fromSubstring(words, words[4 .. 7], "custom.c").file == "custom.c");

	LineColumnRange detailed = resolve(location, source);
	assert(detailed == LineColumnRange("f", LineColumn(2, 1), LineColumn(3, 2)));
	assert(resolve(location, rope) == detailed);
	assert(byteRange(detailed, source) == location);
	assert(lineColumn("a\rb\rc", 4) == LineColumn(3, 1));
	assert(byteOffset(LineColumn(3, 1), "a\rb\rc") == 4);
	assert(lineColumn("a\r\nb\r\nc", 6) == LineColumn(3, 1));
	assert(byteOffset(LineColumn(3, 1), "a\r\nb\r\nc") == 6);

	char* same = display(LineColumnRange("f", LineColumn(2, 3), LineColumn(2, 3)));
	scope(exit) fp.string.free(same);
	assert(fp.string.equal(same, `<"f":2:3>`));

	char* range = display(LineColumnRange("f", LineColumn(2, 3), LineColumn(4, 5)));
	scope(exit) fp.string.free(range);
	assert(fp.string.equal(range, `<"f":2-4:3-5>`));

	// Whatever display writes, parseDisplay reads back; anything else is refused.
	assert(parseDisplay(fp.string.slice(same)).get == LineColumnRange("f", LineColumn(2, 3), LineColumn(2, 3)));
	assert(parseDisplay(fp.string.slice(range)).get == LineColumnRange("f", LineColumn(2, 3), LineColumn(4, 5)));
	assert(parseDisplay(`<"a b:c":10:1-2>`).get.file == "a b:c");
	static immutable string[7] malformed = [``, `<"f":2:3`, `<"f":2:3> `, `<"f":2:-3>`, `<"f":2-:3>`, `<"f:2:3>`, `<"f":99999999999999999999:1>`];
	foreach (bad; malformed) assert(parseDisplay(bad).isNull);

	// Each allocation in turn is refused, until there are enough for the whole string.
	for (size_t n = 0;; ++n) {
		auto previous = fp.testing.limitAllocations(n);
		char* text = display(LineColumnRange("f", LineColumn(2, 3), LineColumn(4, 5)));
		fp.testing.restoreAllocator(previous);
		if (text is null) continue;
		assert(fp.string.equal(text, `<"f":2-4:3-5>`));
		fp.string.free(text);
		break;
	}
}
