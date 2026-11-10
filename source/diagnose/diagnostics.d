/// Ariadne-style compiler diagnostics: a `Manager` collects `Diagnostic`s against registered source files and renders them with the source lines they point at.
module diagnose.diagnostics;

public import diagnose.source_location : LineColumn, LineColumnRange;
static import diagnose.source_location;

static import fp.dynarray;
static import fp.io;
static import fp.lifecycle;
static import fp.pointer;
static import fp.algorithms;
static import fp.string;
static import fp.string.utf;

static import std.algorithm.comparison;
static import std.algorithm.sorting;

@nogc nothrow:


/// ANSI escape codes for text styles, and for foreground and background colors.
struct Ansi {
	enum string reset = "\033[0m";
	enum string bold = "\033[1m";
	enum string dim = "\033[2m";
	enum string underline = "\033[4m";

	enum string black = "\033[30m";
	enum string red = "\033[31m";
	enum string green = "\033[32m";
	enum string yellow = "\033[33m";
	enum string blue = "\033[34m";
	enum string magenta = "\033[35m";
	enum string cyan = "\033[36m";
	enum string white = "\033[37m";

	enum string brightBlack = "\033[90m";
	enum string brightRed = "\033[91m";
	enum string brightGreen = "\033[92m";
	enum string brightYellow = "\033[93m";
	enum string brightBlue = "\033[94m";
	enum string brightMagenta = "\033[95m";
	enum string brightCyan = "\033[96m";
	enum string brightWhite = "\033[97m";

	enum string bgBlack = "\033[40m";
	enum string bgRed = "\033[41m";
	enum string bgGreen = "\033[42m";
	enum string bgYellow = "\033[43m";
	enum string bgBlue = "\033[44m";
	enum string bgMagenta = "\033[45m";
	enum string bgCyan = "\033[46m";
	enum string bgWhite = "\033[47m";

	enum string bgBrightBlack = "\033[100m";
	enum string bgBrightRed = "\033[101m";
	enum string bgBrightGreen = "\033[102m";
	enum string bgBrightYellow = "\033[103m";
	enum string bgBrightBlue = "\033[104m";
	enum string bgBrightMagenta = "\033[105m";
	enum string bgBrightCyan = "\033[106m";
	enum string bgBrightWhite = "\033[107m";
}

/// The next of the 16 foreground colors in `Ansi`, from `black` to `brightWhite` and back. Each thread cycles separately.
///
/// Examples:
/// ---
/// const(char)[] first = nextColor();
/// assert(nextColor() != first);
/// ---
const(char)[] nextColor() {
	static immutable string[16] colors = [
		Ansi.black, Ansi.red, Ansi.green, Ansi.yellow, Ansi.blue, Ansi.magenta, Ansi.cyan, Ansi.white,
		Ansi.brightBlack, Ansi.brightRed, Ansi.brightGreen, Ansi.brightYellow,
		Ansi.brightBlue, Ansi.brightMagenta, Ansi.brightCyan, Ansi.brightWhite
	];
	static size_t index = 0;
	immutable color = colors[index];
	index = (index + 1) % colors.length;
	return color;
}

/// The next of the 16 background colors in `Ansi`, from `bgBlack` to `bgBrightWhite` and back. Each thread cycles separately.
///
/// Examples:
/// ---
/// const(char)[] first = nextBg();
/// assert(nextBg() != first);
/// ---
const(char)[] nextBg() {
	static immutable string[16] colors = [
		Ansi.bgBlack, Ansi.bgRed, Ansi.bgGreen, Ansi.bgYellow, Ansi.bgBlue, Ansi.bgMagenta, Ansi.bgCyan, Ansi.bgWhite,
		Ansi.bgBrightBlack, Ansi.bgBrightRed, Ansi.bgBrightGreen, Ansi.bgBrightYellow,
		Ansi.bgBrightBlue, Ansi.bgBrightMagenta, Ansi.bgBrightCyan, Ansi.bgBrightWhite
	];
	static size_t index = 0;
	immutable color = colors[index];
	index = (index + 1) % colors.length;
	return color;
}


/// How severe a diagnostic is.
enum Kind {
	info, /// Information that needs no action.
	note, /// A remark worth knowing.
	warning, /// A likely problem.
	error, /// A problem; `hasErrors` reports whether any were pushed.
}

/// A message about a range of source, with annotations pointing at other positions, an optional context line, and an optional closing note. It owns its fp strings and annotations; release them with `free`.
struct Diagnostic {
	/// A message pointing at one position, drawn under its source line with a connector.
	struct Annotation {
		LineColumn position; /// Where it points; a column of 0 means the end of the line.
		const(char)[] file; /// The file it points into; empty means the diagnostic's own file.
		char* message; /// An owned fp string.
		const(char)[] color = Ansi.magenta; /// The ANSI color its connector is drawn in.
	}

	/// An edit that resolves the diagnostic, for an editor to offer as a quick fix: `replacement` written over `range`. An empty range inserts, and an empty replacement deletes. `render` does not draw it; say the same in a hint annotation.
	struct Fix {
		char* title; /// An owned fp string naming the edit for a menu, such as "Insert `)`".
		LineColumnRange range; /// What it replaces; an empty `file` means the diagnostic's own file.
		char* replacement; /// An owned fp string written over `range`, or null to delete it.
		bool preferred = false; /// Whether an editor may apply it without asking, because it is the one fix that fits.
	}

	Kind kind; /// How severe it is.
	bool hasCode = false; /// Whether the header shows `code`, as `[E001]`.
	size_t code = 0; /// The code the header shows when `hasCode` is set.
	char* message; /// An owned fp string, the headline.
	LineColumnRange location; /// The range it highlights; a column of 0 means the end of the line. An empty `file` means it has no location, such as a file that cannot be read, and renders without source.
	Annotation* annotations; /// An owned fp dynarray.
	char* contextMessage; /// An owned fp string summarizing what the location is, such as "The values are outputs of this match expression", or null.
	char* note; /// An owned fp string giving a closing note, such as "Outputs of match expressions must coerce to the same type", or null.
	Fix* fixes; /// An owned fp dynarray of the edits that resolve it, offered in order.
}

/// Appends `annotation` to `diagnostic`, as `fp.dynarray.pushBack` onto its `annotations` does, pointing at the start of `diagnostic.location`.
///
/// Returns false if an allocation was refused, leaving `diagnostic` unchanged and the message still the caller's.
///
/// Examples:
/// ---
/// Diagnostic diagnostic;
/// scope(exit) free(diagnostic);
/// diagnostic.location = LineColumnRange("a.c", LineColumn(2, 5), LineColumn(2, 9));
/// assert(pushAnnotationAtStart(diagnostic, Diagnostic.Annotation(LineColumn.init, "", fp.string.clone("here").get)));
/// assert(diagnostic.annotations[0].position == LineColumn(2, 5));
/// ---
bool pushAnnotationAtStart(ref Diagnostic diagnostic, Diagnostic.Annotation annotation) {
	annotation.position = diagnostic.location.start;
	return fp.dynarray.pushBack(diagnostic.annotations, annotation);
}

/// Appends `annotation` to `diagnostic`, as `fp.dynarray.pushBack` onto its `annotations` does, pointing at the end of `diagnostic.location`.
///
/// Returns false if an allocation was refused, leaving `diagnostic` unchanged and the message still the caller's.
///
/// Examples:
/// ---
/// Diagnostic diagnostic;
/// scope(exit) free(diagnostic);
/// diagnostic.location = LineColumnRange("a.c", LineColumn(2, 5), LineColumn(2, 9));
/// assert(pushAnnotationAtEnd(diagnostic, Diagnostic.Annotation(LineColumn.init, "", fp.string.clone("there").get)));
/// assert(diagnostic.annotations[0].position == LineColumn(2, 9));
/// ---
bool pushAnnotationAtEnd(ref Diagnostic diagnostic, Diagnostic.Annotation annotation) {
	annotation.position = diagnostic.location.end;
	return fp.dynarray.pushBack(diagnostic.annotations, annotation);
}

/// Frees everything `diagnostic` owns: its messages, its annotations and fixes with their strings, nulling its pointers to them.
///
/// Examples:
/// ---
/// Diagnostic diagnostic;
/// diagnostic.message = fp.string.clone("unused variable").get;
/// assert(fp.dynarray.pushBack(diagnostic.fixes, Diagnostic.Fix(fp.string.clone("Remove it").get)));
/// free(diagnostic);
/// assert(diagnostic.message is null && diagnostic.fixes is null);
/// ---
void free(ref Diagnostic diagnostic) @trusted {
	fp.string.free(diagnostic.message);
	fp.string.free(diagnostic.contextMessage);
	fp.string.free(diagnostic.note);
	foreach (i; 0 .. fp.dynarray.length(diagnostic.annotations))
		fp.string.free(diagnostic.annotations[i].message);
	fp.dynarray.free(diagnostic.annotations);
	foreach (ref fix; fp.dynarray.slice(diagnostic.fixes)) {
		fp.string.free(fix.title);
		fp.string.free(fix.replacement);
	}
	fp.dynarray.free(diagnostic.fixes);
}


/// A registered source file: views of its name and text, which whoever registered it keeps alive, and where each of its lines starts, which it owns.
struct SourceFile {
	const(char)[] filename; /// The name diagnostics refer to it by.
	const(char)[] source; /// Its full text.
	fp.lifecycle.Owned!size_t lineStarts; /// The byte offset each line starts at, so rendering finds a line without rescanning the text; a trailing newline starts an empty last line.
}

private size_t indexOfFile(const SourceFile* files, const(char)[] filename) @trusted {
	foreach (i; 0 .. fp.dynarray.length(files))
		if (files[i].filename == filename) return i;
	return fp.pointer.notFound;
}

private const(SourceFile)* fileNamed(const SourceFile* files, const(char)[] filename) @trusted {
	immutable i = indexOfFile(files, filename);
	return i == fp.pointer.notFound ? null : &files[i];
}

// Where each line of `source` starts, or null if an allocation was refused.
private size_t* indexLines(const(char)[] source) @trusted {
	size_t* starts = null;
	if (!fp.dynarray.pushBack(starts, size_t(0))) return null;
	for (size_t at = 0; at < source.length; ++at) {
		if (fp.string.breaksLine(source, at)) {
			if (!fp.dynarray.pushBack(starts, at + 1)) {
				fp.dynarray.free(starts);
				return null;
			}
		}
	}
	return starts;
}

// Whether `file` has a 1-based line `number`.
private bool hasLine(ref const SourceFile file, size_t number) {
	return number != 0 && number <= fp.dynarray.length(file.lineStarts.p);
}

// The text of 1-based line `number` of `file`, which `hasLine` must accept, without its newline.
private const(char)[] lineText(ref const SourceFile file, size_t number) @trusted {
	assert(hasLine(file, number));
	immutable start = file.lineStarts.p[number - 1];
	return file.source[start .. fp.string.lineEnd(file.source, start)];
}

/// Collects diagnostics and the source files they point into, and renders them. Release it with `free`.
struct Manager {
	Diagnostic* diagnostics; /// An owned fp dynarray of the diagnostics pushed.
	SourceFile* sourceFiles; /// An fp dynarray of the registered files, whose names and text it borrows and whose line indices it owns.
}


/// Registers `source` as the text of `filename`, replacing any earlier registration of `filename`. Both are borrowed, not copied, so end the registration with `removeSource` or `clear` before freeing either; a later registration compares against every registered name.
///
/// Returns false if an allocation was refused, leaving the registrations as they were.
///
/// Examples:
/// ---
/// Manager manager;
/// scope(exit) free(manager);
/// assert(addSource(manager, "a.c", "int x;\n"));
/// assert(addSource(manager, "a.c", "int y;\n"));
/// assert(fp.dynarray.length(manager.sourceFiles) == 1);
/// ---
bool addSource(ref Manager manager, const(char)[] filename, const(char)[] source) @trusted {
	auto starts = fp.lifecycle.Owned!size_t(indexLines(source));
	if (starts.p is null) return false;
	immutable i = indexOfFile(manager.sourceFiles, filename);
	if (i == fp.pointer.notFound) return fp.dynarray.pushBack(manager.sourceFiles, SourceFile(filename, source, starts));
	manager.sourceFiles[i].source = source;
	fp.lifecycle.moveInto(manager.sourceFiles[i].lineStarts, starts);
	return true;
}

/// Ends the registration of `filename`, if there is one, and returns whether there was. Diagnostics already pushed against it still render, noting that its source is unavailable.
///
/// Examples:
/// ---
/// Manager manager;
/// scope(exit) free(manager);
/// assert(addSource(manager, "a.c", "int x;\n"));
/// assert(removeSource(manager, "a.c"));
/// assert(!removeSource(manager, "a.c"));
/// ---
bool removeSource(ref Manager manager, const(char)[] filename) @trusted {
	immutable i = indexOfFile(manager.sourceFiles, filename);
	if (i == fp.pointer.notFound) return false;
	cast(void) fp.dynarray.removeAt(manager.sourceFiles, i);
	return true;
}

/// Appends `diagnostic` to `manager`, which takes over everything it owns. Returns the stored copy, valid until the next `push`, `clear` or `free`.
///
/// Returns null if an allocation was refused, leaving `manager` unchanged and what `diagnostic` owns still the caller's.
///
/// Examples:
/// ---
/// Manager manager;
/// scope(exit) free(manager);
/// Diagnostic diagnostic;
/// diagnostic.message = fp.string.clone("unused variable").get;
/// Diagnostic* stored = push(manager, diagnostic);
/// assert(stored !is null && stored.message is diagnostic.message);
/// ---
Diagnostic* push(ref Manager manager, Diagnostic diagnostic) @trusted {
	if (!fp.dynarray.pushBack(manager.diagnostics, diagnostic)) return null;
	return &manager.diagnostics[fp.dynarray.length(manager.diagnostics) - 1];
}


/// Whether any diagnostic pushed to `manager` is an error.
///
/// Examples:
/// ---
/// Manager manager;
/// scope(exit) free(manager);
/// Diagnostic diagnostic;
/// diagnostic.kind = Kind.error;
/// assert(push(manager, diagnostic) !is null);
/// assert(hasErrors(manager));
/// ---
bool hasErrors(const ref Manager manager) @trusted {
	foreach (i; 0 .. fp.dynarray.length(manager.diagnostics))
		if (manager.diagnostics[i].kind == Kind.error) return true;
	return false;
}

/// Frees every diagnostic pushed to `manager` and ends every registration, keeping `manager` usable. Registrations end too because `manager` cannot know whether the text they borrow outlives the diagnostics; re-register any that should.
///
/// Examples:
/// ---
/// Manager manager;
/// scope(exit) free(manager);
/// assert(addSource(manager, "a.c", "int x;\n"));
/// assert(push(manager, Diagnostic.init) !is null);
/// clear(manager);
/// assert(fp.dynarray.length(manager.diagnostics) == 0 && !removeSource(manager, "a.c"));
/// ---
void clear(ref Manager manager) @trusted {
	foreach (i; 0 .. fp.dynarray.length(manager.diagnostics))
		free(manager.diagnostics[i]);
	fp.dynarray.clear(manager.diagnostics);
	fp.dynarray.clear(manager.sourceFiles);
}

/// Frees `manager`'s diagnostics, everything they own, and its list of registrations, nulling its pointers to them.
///
/// Examples:
/// ---
/// Manager manager;
/// assert(push(manager, Diagnostic.init) !is null);
/// free(manager);
/// assert(manager.diagnostics is null);
/// ---
void free(ref Manager manager) @trusted {
	clear(manager);
	fp.dynarray.free(manager.diagnostics);
	fp.dynarray.free(manager.sourceFiles);
}


// Rendered text, and whether an allocation was refused while writing it; once one is, later writes are skipped.
private struct Output {
	char* text;
	bool failed;
}

private void put(Args...)(ref Output output, Args pieces) {
	if (!output.failed) output.failed = !fp.string.append(output.text, pieces);
}

private void pushOrFail(T)(ref Output output, ref T* array, T value) {
	if (!fp.dynarray.pushBack(array, value)) output.failed = true;
}

private struct KindStyle {
	const(char)[] color;
	const(char)[] name;
}

// Indexed by `Kind`, so the order follows its declaration.
private immutable KindStyle[4] kindStyles = [
	KindStyle(Ansi.cyan, "Info"),
	KindStyle(Ansi.blue, "Note"),
	KindStyle(Ansi.yellow, "Warning"),
	KindStyle(Ansi.red, "Error"),
];

private size_t digitCount(size_t value) {
	size_t count = 1;
	while (value >= 10) {
		value /= 10;
		++count;
	}
	return count;
}

private void appendSpaces(ref Output output, size_t n) {
	foreach (i; 0 .. n) put(output, " ");
}

private void appendPadded(ref Output output, size_t value, size_t width) {
	immutable digits = digitCount(value);
	if (width > digits) appendSpaces(output, width - digits);
	put(output, value);
}

// Opens a row of the cyan left margin: a space, `width` blanks in place of a line number, then `marker`, leaving the style reset.
private void appendGutter(ref Output output, size_t width, const(char)[] marker) {
	put(output, " ", Ansi.cyan, Ansi.bold);
	appendSpaces(output, width);
	put(output, marker, Ansi.reset);
}

private void appendContinuationRow(ref Output output, size_t width) {
	appendGutter(output, width, " ·");
	put(output, "\n");
}


// Zero-width codepoints as [low, high] pairs: combining marks, joiners and variation selectors likely in source text, not the full Unicode table.
private immutable uint[2][] zeroWidthRanges = [
	[0x0300, 0x036F], // Combining Diacritical Marks
	[0x0483, 0x0489], // Cyrillic combining marks
	[0x0591, 0x05BD], [0x05BF, 0x05BF], [0x05C1, 0x05C2], [0x05C4, 0x05C5], [0x05C7, 0x05C7], // Hebrew points
	[0x0610, 0x061A], [0x064B, 0x065F], [0x0670, 0x0670], [0x06D6, 0x06DC], [0x06DF, 0x06E4], [0x06E7, 0x06E8],
	[0x06EA, 0x06ED], // Arabic marks
	[0x1AB0, 0x1AFF], // Combining Diacritical Marks Extended
	[0x1DC0, 0x1DFF], // Combining Diacritical Marks Supplement
	[0x200B, 0x200F], // Zero-width space, joiners and marks
	[0x202A, 0x202E], // Directional formatting
	[0x2060, 0x2064], // Word joiner and invisible operators
	[0x20D0, 0x20FF], // Combining Diacritical Marks for Symbols
	[0xFE00, 0xFE0F], // Variation selectors
	[0xFE20, 0xFE2F], // Combining half marks
	[0xFEFF, 0xFEFF], // Zero-width no-break space (BOM)
	[0xE0100, 0xE01EF], // Variation selectors supplement
];

// Double-width codepoints as [low, high] pairs, approximating East Asian Width Wide and Fullwidth, plus most emoji, as Rust's `unicode-width` does.
private immutable uint[2][] wideRanges = [
	[0x1100, 0x115F], // Hangul Jamo
	[0x2329, 0x232A], // Angle brackets
	[0x2E80, 0x303E], // CJK Radicals, Kangxi, CJK Symbols and Punctuation
	[0x3041, 0x33FF], // Hiragana to CJK Compatibility
	[0x3400, 0x4DBF], // CJK Extension A
	[0x4E00, 0x9FFF], // CJK Unified Ideographs
	[0xA000, 0xA4CF], // Yi Syllables and Radicals
	[0xAC00, 0xD7A3], // Hangul Syllables
	[0xF900, 0xFAFF], // CJK Compatibility Ideographs
	[0xFE30, 0xFE4F], // CJK Compatibility Forms
	[0xFF00, 0xFF60], [0xFFE0, 0xFFE6], // Fullwidth Forms
	[0x16FE0, 0x16FE4], [0x17000, 0x18CFF], [0x1B000, 0x1B2FF], // CJK Extensions and scripts
	[0x1F004, 0x1F004], [0x1F0CF, 0x1F0CF], // Mahjong and playing-card symbols used in emoji sets
	[0x1F300, 0x1FAFF], // Misc symbols, emoji, and pictographs
	[0x20000, 0x3FFFD], // CJK Extension B onwards
];

private size_t codepointDisplayWidth(uint codepoint) {
	if (codepoint == 0 || fp.string.utf.inRanges(zeroWidthRanges, codepoint)) return 0;
	if (fp.string.utf.inRanges(wideRanges, codepoint)) return 2;
	return 1;
}

// The terminal column 1-based `byteColumn` of the UTF-8 `line` displays at, counting double- and zero-width codepoints.
private size_t byteColumnToDisplayColumn(const(char)[] line, size_t byteColumn) {
	immutable target = byteColumn - 1;
	size_t i = 0;
	size_t column = 1;
	while (i < target && i < line.length) {
		bool valid;
		immutable codepoint = fp.string.utf.decode(line, i, valid);
		if (!valid) return byteColumn;
		column += codepointDisplayWidth(codepoint);
	}
	return column;
}


// An annotation and the display column it points at.
private struct AnnotatedColumn {
	const(Diagnostic.Annotation)* annotation;
	size_t column;
}

private bool descByColumn(in AnnotatedColumn a, in AnnotatedColumn b) {
	return a.column > b.column;
}

// A column of 0 means the end of the line.
private size_t effectiveColumn(size_t column, size_t lineLength) {
	return column == 0 ? lineLength + 1 : column;
}

private void pushResolved(ref Output output, ref AnnotatedColumn* result, const(Diagnostic.Annotation)* annotation, const(char)[] line) {
	immutable byteColumn = effectiveColumn(annotation.position.column, line.length);
	pushOrFail(output, result, AnnotatedColumn(annotation, byteColumnToDisplayColumn(line, byteColumn)));
}

// The diagnostic's own-file annotations on `lineNumber`, rightmost first, the order their connectors are drawn in.
private AnnotatedColumn* collectMainLineAnnotations(ref Output output, ref const Diagnostic diagnostic, size_t lineNumber, const(char)[] line) @trusted {
	AnnotatedColumn* result = null;
	foreach (i; 0 .. fp.dynarray.length(diagnostic.annotations)) {
		const annotation = &diagnostic.annotations[i];
		if ((annotation.file.length == 0 || annotation.file == diagnostic.location.file) && annotation.position.line == lineNumber)
			pushResolved(output, result, annotation, line);
	}
	std.algorithm.sorting.sort!descByColumn(fp.dynarray.slice(result));
	return result;
}

// One foreign file's annotations, drawn as a block of their own.
private struct ForeignGroup {
	const(char)[] file;
	const(Diagnostic.Annotation)** annotations;
}

private AnnotatedColumn* collectForeignLineAnnotations(ref Output output, const(Diagnostic.Annotation)** group, size_t lineNumber, const(char)[] line) @trusted {
	AnnotatedColumn* result = null;
	foreach (i; 0 .. fp.dynarray.length(group))
		if (group[i].position.line == lineNumber)
			pushResolved(output, result, group[i], line);
	std.algorithm.sorting.sort!descByColumn(fp.dynarray.slice(result));
	return result;
}

private bool byFileAscending(in ForeignGroup a, in ForeignGroup b) {
	return a.file < b.file;
}

private ForeignGroup* collectForeignGroups(ref Output output, ref const Diagnostic diagnostic) @trusted {
	ForeignGroup* groups = null;
	foreach (i; 0 .. fp.dynarray.length(diagnostic.annotations)) {
		const annotation = &diagnostic.annotations[i];
		if (annotation.file.length == 0 || annotation.file == diagnostic.location.file) continue;

		size_t g = 0;
		while (g < fp.dynarray.length(groups) && groups[g].file != annotation.file) ++g;
		if (g < fp.dynarray.length(groups)) {
			pushOrFail(output, groups[g].annotations, annotation);
			continue;
		}
		ForeignGroup group = ForeignGroup(annotation.file);
		pushOrFail(output, group.annotations, annotation);
		if (!fp.dynarray.pushBack(groups, group)) {
			fp.dynarray.free(group.annotations);
			output.failed = true;
		}
	}
	std.algorithm.sorting.sort!byFileAscending(fp.dynarray.slice(groups));
	return groups;
}

private void freeForeignGroups(ForeignGroup* groups) @trusted {
	foreach (g; 0 .. fp.dynarray.length(groups))
		fp.dynarray.free(groups[g].annotations);
	fp.dynarray.free(groups);
}

private void appendAnnotations(ref Output output, const AnnotatedColumn* sorted, size_t width) @trusted {
	immutable n = fp.dynarray.length(sorted);
	foreach (i; 0 .. n) {
		put(output, " ");
		appendGutter(output, width, "│");
		put(output, "   "); // Lines up with the " ➤ " source rows carry after their gutter.

		// Draws the connectors of the annotations still to come, which sit further left.
		foreach (column; 1 .. sorted[i].column) {
			size_t j = i + 1;
			while (j < n && sorted[j].column != column) ++j;
			if (j < n) put(output, sorted[j].annotation.color, "│", Ansi.reset);
			else put(output, " ");
		}

		const annotation = sorted[i].annotation;
		put(output, annotation.color, "└─ ", Ansi.reset, fp.string.slice(annotation.message), "\n");
	}
}

private void appendSourceLine(ref Output output, size_t lineNumber, size_t width, const(char)[] kindColor) {
	put(output, " ", Ansi.cyan, Ansi.bold);
	appendPadded(output, lineNumber, width);
	put(output, " │ ", Ansi.reset, kindColor, "➤ ", Ansi.reset);
}

private void appendSourceContext(ref Output output, ref const Diagnostic diagnostic, ref const SourceFile file, const SourceFile* sourceFiles) @trusted {
	immutable startLine = diagnostic.location.start.line;
	immutable endLine = diagnostic.location.end.line;

	size_t* lineNumbers = null;
	scope(exit) fp.dynarray.free(lineNumbers);
	foreach (line; startLine .. endLine + 1)
		pushOrFail(output, lineNumbers, line);
	foreach (i; 0 .. fp.dynarray.length(diagnostic.annotations)) {
		const annotation = &diagnostic.annotations[i];
		if (annotation.file.length == 0 || annotation.file == diagnostic.location.file)
			pushOrFail(output, lineNumbers, annotation.position.line);
	}
	fp.algorithms.sortUnique(lineNumbers);

	ForeignGroup* groups = collectForeignGroups(output, diagnostic);
	scope(exit) freeForeignGroups(groups);

	size_t widest = endLine;
	if (fp.dynarray.length(lineNumbers) > 0) widest = std.algorithm.comparison.max(widest, lineNumbers[fp.dynarray.length(lineNumbers) - 1]);
	foreach (g; 0 .. fp.dynarray.length(groups))
		foreach (a; 0 .. fp.dynarray.length(groups[g].annotations))
			widest = std.algorithm.comparison.max(widest, groups[g].annotations[a].position.line);
	immutable width = digitCount(widest);
	immutable kindColor = kindStyles[diagnostic.kind].color;

	foreach (i; 0 .. fp.dynarray.length(lineNumbers)) {
		immutable lineNumber = lineNumbers[i];
		if (!hasLine(file, lineNumber)) continue;
		const(char)[] line = lineText(file, lineNumber);
		appendSourceLine(output, lineNumber, width, kindColor);

		// A line shown only for its annotations lies outside the location, so nothing on it is highlighted.
		size_t startColumn = line.length + 1;
		size_t endColumn = line.length + 1;
		if (lineNumber >= startLine && lineNumber <= endLine) {
			if (lineNumber == startLine) startColumn = std.algorithm.comparison.min(effectiveColumn(diagnostic.location.start.column, line.length), line.length + 1);
			else startColumn = 1;
			if (lineNumber == endLine) endColumn = std.algorithm.comparison.max(startColumn, std.algorithm.comparison.min(effectiveColumn(diagnostic.location.end.column, line.length), line.length + 1));
		}
		put(output, line[0 .. startColumn - 1]);
		if (endColumn > startColumn) put(output, kindColor, Ansi.bold, line[startColumn - 1 .. endColumn - 1], Ansi.reset);
		put(output, line[endColumn - 1 .. $], "\n");

		AnnotatedColumn* annotations = collectMainLineAnnotations(output, diagnostic, lineNumber, line);
		scope(exit) fp.dynarray.free(annotations);
		appendAnnotations(output, annotations, width);
	}

	foreach (g; 0 .. fp.dynarray.length(groups)) {
		appendContinuationRow(output, width);
		put(output, " ", Ansi.cyan, Ansi.bold, "┌─ <\"", groups[g].file, "\">", Ansi.reset, "\n");

		const foreign = fileNamed(sourceFiles, groups[g].file);
		if (foreign is null) {
			put(output, " ", Ansi.yellow, Ansi.bold, "(source not available)", Ansi.reset, "\n");
			continue;
		}

		size_t* foreignLineNumbers = null;
		scope(exit) fp.dynarray.free(foreignLineNumbers);
		foreach (a; 0 .. fp.dynarray.length(groups[g].annotations))
			pushOrFail(output, foreignLineNumbers, groups[g].annotations[a].position.line);
		fp.algorithms.sortUnique(foreignLineNumbers);

		foreach (i; 0 .. fp.dynarray.length(foreignLineNumbers)) {
			immutable lineNumber = foreignLineNumbers[i];
			if (!hasLine(*foreign, lineNumber)) continue;
			const(char)[] line = lineText(*foreign, lineNumber);
			appendSourceLine(output, lineNumber, width, kindColor);
			put(output, line, "\n");

			AnnotatedColumn* annotations = collectForeignLineAnnotations(output, groups[g].annotations, lineNumber, line);
			scope(exit) fp.dynarray.free(annotations);
			appendAnnotations(output, annotations, width);
		}
	}

	appendContinuationRow(output, width);
	appendContinuationRow(output, width);

	if (fp.string.length(diagnostic.contextMessage) > 0) {
		appendGutter(output, width, " └─");
		put(output, " ", fp.string.slice(diagnostic.contextMessage), "\n");
	}
	if (fp.string.length(diagnostic.note) > 0) {
		appendContinuationRow(output, width);
		appendGutter(output, width, " ");
		put(output, Ansi.blue, Ansi.bold, "Note:", Ansi.reset, " ", fp.string.slice(diagnostic.note), "\n");
	}
}

private void appendHeader(ref Output output, ref const Diagnostic diagnostic) @trusted {
	immutable style = kindStyles[diagnostic.kind];
	if (diagnostic.hasCode) {
		put(output, Ansi.bold, style.color, "[E");
		foreach (i; digitCount(diagnostic.code) .. 3) put(output, '0');
		put(output, diagnostic.code, "] ");
	}
	put(output, style.color, Ansi.bold, style.name, Ansi.reset);
	put(output, ": ", Ansi.reset, Ansi.bold, fp.string.slice(diagnostic.message), Ansi.reset, "\n");
	if (diagnostic.location.file.length == 0) return;

	char* location = diagnose.source_location.display(diagnostic.location);
	scope(exit) fp.string.free(location);
	if (location is null) output.failed = true;
	put(output, " ", Ansi.cyan, Ansi.bold, "┌─ ", location, Ansi.reset, "\n");
}

private void appendCount(ref Output output, size_t n, const(char)[] color, const(char)[] singular, const(char)[] plural) {
	put(output, color, Ansi.bold, n, n != 1 ? plural : singular, Ansi.reset);
}

private void appendSummary(ref Output output, const ref Manager manager) @trusted {
	size_t errors = 0, warnings = 0;
	foreach (i; 0 .. fp.dynarray.length(manager.diagnostics)) {
		if (manager.diagnostics[i].kind == Kind.error) ++errors;
		else if (manager.diagnostics[i].kind == Kind.warning) ++warnings;
	}
	if (errors == 0 && warnings == 0) return;

	put(output, Ansi.bold);
	if (errors > 0) appendCount(output, errors, Ansi.red, " error", " errors");
	if (errors > 0 && warnings > 0) put(output, Ansi.bold, ", ", Ansi.reset);
	if (warnings > 0) appendCount(output, warnings, Ansi.yellow, " warning", " warnings");
	put(output, Ansi.bold, " generated.", Ansi.reset, "\n");
}


/// Renders every diagnostic pushed to `manager` into a new fp string: each one's header, the source lines it points at with its annotations, then a count of errors and warnings. A diagnostic with no location shows only its header and closing note. The caller frees it with `fp.string.free`.
///
/// Returns null if nothing was pushed, or if an allocation was refused.
///
/// Examples:
/// ---
/// Manager manager;
/// scope(exit) free(manager);
/// assert(addSource(manager, "a.c", "int x = y;\n"));
/// Diagnostic diagnostic;
/// diagnostic.kind = Kind.error;
/// diagnostic.message = fp.string.clone("undefined identifier").get;
/// diagnostic.location = LineColumnRange("a.c", LineColumn(1, 9), LineColumn(1, 10));
/// assert(push(manager, diagnostic) !is null);
/// char* text = render(manager);
/// scope(exit) fp.string.free(text);
/// assert(fp.string.contains(text, "undefined identifier", 0));
/// ---
char* render(const ref Manager manager) @trusted {
	Output output;
	foreach (i; 0 .. fp.dynarray.length(manager.diagnostics)) {
		const diagnostic = &manager.diagnostics[i];
		appendHeader(output, *diagnostic);
		if (diagnostic.location.file.length == 0) {
			if (fp.string.length(diagnostic.note) > 0) put(output, " ", Ansi.blue, Ansi.bold, "Note:", Ansi.reset, " ", fp.string.slice(diagnostic.note), "\n");
			put(output, "\n");
			continue;
		}
		if (auto file = fileNamed(manager.sourceFiles, diagnostic.location.file))
			appendSourceContext(output, *diagnostic, *file, manager.sourceFiles);
		else put(output, " ", Ansi.yellow, Ansi.bold, "(source not available)", Ansi.reset, "\n");
		put(output, " ", Ansi.cyan, Ansi.bold, "└─", Ansi.reset, "\n\n");
	}
	appendSummary(output, manager);
	if (output.failed) fp.string.free(output.text);
	return output.text;
}

/// Renders every diagnostic pushed to `manager`, as `render` does, and writes the UTF-8 result to the open descriptor `descriptor`, standard error by default, through `fp.io.writeAll`.
///
/// Returns false, having written nothing, if an allocation was refused, or if the write failed, perhaps after part of the text was written.
///
/// Examples:
/// ---
/// Manager manager;
/// scope(exit) free(manager);
/// assert(printAll(manager));
/// ---
bool printAll(const ref Manager manager, int descriptor = fp.io.Console.error) {
	char* rendered = render(manager);
	scope(exit) fp.string.free(rendered);
	if (rendered is null) return fp.dynarray.length(manager.diagnostics) == 0;
	return fp.io.writeAll(descriptor, fp.string.slice(rendered));
}


version(unittest) {
	static import fp.testing;

	private Diagnostic makeDiagnostic(Kind kind, const(char)[] message, LineColumnRange location) {
		Diagnostic diagnostic;
		diagnostic.kind = kind;
		auto cloned = fp.string.clone(message);
		assert(!cloned.isNull);
		diagnostic.message = cloned.get;
		diagnostic.location = location;
		return diagnostic;
	}

	private Diagnostic.Annotation makeAnnotation(LineColumn position, const(char)[] file, const(char)[] message, const(char)[] color = Ansi.magenta) {
		auto cloned = fp.string.clone(message);
		assert(!cloned.isNull);
		char* text = cloned.get;
		return Diagnostic.Annotation(position, file, text, color);
	}

	private void pushTo(ref Manager manager, Diagnostic diagnostic) {
		assert(push(manager, diagnostic) !is null);
	}

	// A temporary file to print into, through `descriptor`; `fp.testing.free` closes and removes it.
	private fp.testing.ScratchFile openScratch() {
		auto scratch = fp.testing.openScratchFile();
		assert(!scratch.isNull);
		return scratch.get;
	}

	// How many bytes have been printed into `scratch`.
	private size_t printedLength(ref const fp.testing.ScratchFile scratch) {
		auto read = fp.io.readFile(fp.string.slice(scratch.path));
		assert(!read.isNull);
		scope(exit) fp.string.free(read.get);
		return fp.string.length(read.get);
	}


	// Whether rendering `manager` gives text containing `needle`.
	private bool renders(const ref Manager manager, const(char)[] needle) {
		char* rendered = render(manager);
		scope(exit) fp.string.free(rendered);
		return fp.string.contains(rendered, needle, 0);
	}
}


unittest {

	assert(nextColor() == Ansi.black);
	foreach (i; 0 .. 15)
		cast(void) nextColor();
	assert(nextColor() == Ansi.black);

	assert(nextBg() == Ansi.bgBlack);
	foreach (i; 0 .. 15)
		cast(void) nextBg();
	assert(nextBg() == Ansi.bgBlack);
}

unittest {
	Diagnostic diagnostic = makeDiagnostic(Kind.error, "boom", LineColumnRange("a.c", LineColumn(3, 2), LineColumn(3, 9)));
	scope(exit) free(diagnostic);

	assert(diagnostic.pushAnnotationAtStart(makeAnnotation(LineColumn.init, "", "here", Ansi.green)));
	assert(diagnostic.pushAnnotationAtEnd(makeAnnotation(LineColumn.init, "", "there", Ansi.red)));
	assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(1, 1), "b.c", "elsewhere", Ansi.blue)));
	assert(fp.dynarray.length(diagnostic.annotations) == 3);
	assert(diagnostic.annotations[0].position == LineColumn(3, 2));
	assert(diagnostic.annotations[1].position == LineColumn(3, 9));
	assert(diagnostic.annotations[2].position == LineColumn(1, 1) && diagnostic.annotations[2].file == "b.c");
	// Fixes are owned like annotations, so `free` releases them; one deleting text has no replacement.
	assert(fp.dynarray.pushBack(diagnostic.fixes, Diagnostic.Fix(fp.string.clone("Insert `;`").get, LineColumnRange("", LineColumn(3, 9), LineColumn(3, 9)), fp.string.clone(";").get, true)));
	assert(fp.dynarray.pushBack(diagnostic.fixes, Diagnostic.Fix(fp.string.clone("Remove it").get, LineColumnRange("", LineColumn(3, 2), LineColumn(3, 9)))));
	assert(fp.dynarray.length(diagnostic.fixes) == 2 && diagnostic.fixes[0].preferred && diagnostic.fixes[1].replacement is null);

	// A refused allocation leaves the diagnostic as it was, and the message the caller's.
	Diagnostic empty;
	Diagnostic.Annotation refused = makeAnnotation(LineColumn(1, 1), "", "refused");
	auto previous = fp.testing.limitAllocations(0);
	assert(!fp.dynarray.pushBack(empty.annotations, refused));
	fp.testing.restoreAllocator(previous);
	assert(empty.annotations is null);
	fp.string.free(refused.message);
}

unittest {
	Manager manager;
	scope(exit) free(manager);

	assert(addSource(manager, "a.c", "one\n"));
	assert(addSource(manager, "a.c", "one\ntwo\n"));
	assert(addSource(manager, "b.c", "three\n"));
	assert(fp.dynarray.length(manager.sourceFiles) == 2);

	assert(fp.dynarray.length(manager.diagnostics) == 0 && !hasErrors(manager));
	pushTo(manager, makeDiagnostic(Kind.note, "fyi", LineColumnRange("a.c", LineColumn(1, 1), LineColumn(1, 4))));
	assert(fp.dynarray.length(manager.diagnostics) == 1 && !hasErrors(manager));
	Diagnostic* stored = push(manager, makeDiagnostic(Kind.error, "bad", LineColumnRange("a.c", LineColumn(1, 1), LineColumn(1, 4))));
	assert(stored is &manager.diagnostics[1]);
	assert(fp.dynarray.length(manager.diagnostics) == 2 && hasErrors(manager));

	// Refused allocations leave the manager as it was, and the diagnostic the caller's.
	Manager empty;
	Diagnostic refused = makeDiagnostic(Kind.error, "refused", LineColumnRange.init);
	auto previous = fp.testing.limitAllocations(0);
	assert(!addSource(empty, "c.c", "four\n"));
	assert(push(empty, refused) is null);
	fp.testing.restoreAllocator(previous);
	assert(empty.sourceFiles is null && fp.dynarray.length(empty.diagnostics) == 0);
	free(refused);
	// However far indexing the lines got before a refusal, nothing is registered.
	static immutable string manyLines = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn\no\np\nq\nr\ns\nt\n";
	for (size_t n = 0;; ++n) {
		previous = fp.testing.limitAllocations(n);
		immutable added = addSource(empty, "d.c", manyLines);
		fp.testing.restoreAllocator(previous);
		if (added) break;
		assert(empty.sourceFiles is null || fp.dynarray.length(empty.sourceFiles) == 0);
	}
	assert(removeSource(empty, "d.c"));

	clear(manager);
	assert(fp.dynarray.length(manager.diagnostics) == 0 && !hasErrors(manager));
	assert(render(manager) is null);
	assert(!removeSource(manager, "a.c"));
	assert(!removeSource(manager, "b.c"));

	auto scratch = openScratch();
	scope(exit) fp.testing.free(scratch);
	assert(printAll(manager, scratch.descriptor) && printedLength(scratch) == 0);
}

unittest { // a registration is a borrow, and both ways of ending it work
	// Heap filenames, freed while the manager is still in use, make a dangling registration a use-after-free under -fsanitize=address.
	Manager manager;
	scope(exit) free(manager);

	enum aName = "a.c";
	enum bName = "b.c";
	char* a = fp.pointer.allocate!char(aName.length);
	char* b = fp.pointer.allocate!char(bName.length);
	assert(a !is null && b !is null);
	fp.pointer.copy(a[0 .. aName.length], aName);
	fp.pointer.copy(b[0 .. bName.length], bName);

	assert(addSource(manager, a[0 .. aName.length], "alpha\n"));
	assert(addSource(manager, b[0 .. bName.length], "beta\n"));
	assert(fileNamed(manager.sourceFiles, "a.c").source == "alpha\n");
	assert(lineText(*fileNamed(manager.sourceFiles, "a.c"), 1) == "alpha" && lineText(*fileNamed(manager.sourceFiles, "a.c"), 2) == "");
	assert(!hasLine(*fileNamed(manager.sourceFiles, "a.c"), 3));

	assert(removeSource(manager, a[0 .. aName.length]));
	fp.pointer.free(a);
	assert(!removeSource(manager, "a.c"));
	assert(!removeSource(manager, "never-registered.c"));
	assert(fileNamed(manager.sourceFiles, "a.c") is null);
	assert(fileNamed(manager.sourceFiles, "b.c").source == "beta\n");

	// Compares against every surviving name, which would read `a` had deregistering not dropped it.
	assert(addSource(manager, "c.c", "gamma\n"));

	pushTo(manager, makeDiagnostic(Kind.error, "file is gone", LineColumnRange("a.c", LineColumn(1, 1), LineColumn(1, 2))));
	assert(renders(manager, "(source not available)"));

	clear(manager);
	fp.pointer.free(b);
	assert(!removeSource(manager, "b.c"));
	assert(fileNamed(manager.sourceFiles, "b.c") is null);
	assert(addSource(manager, "d.c", "delta\n"));
	assert(fileNamed(manager.sourceFiles, "d.c").source == "delta\n");
	// Re-registering a name replaces its line index along with its text.
	assert(addSource(manager, "d.c", "x\ny\nz"));
	assert(lineText(*fileNamed(manager.sourceFiles, "d.c"), 3) == "z" && !hasLine(*fileNamed(manager.sourceFiles, "d.c"), 4));
}

unittest {
	assert(digitCount(0) == 1);
	assert(digitCount(9) == 1);
	assert(digitCount(10) == 2);
	assert(digitCount(999) == 3);
	assert(digitCount(1000) == 4);

	assert(byteColumnToDisplayColumn("abc", 1) == 1);
	assert(byteColumnToDisplayColumn("abc", 3) == 3);
	// Narrow codepoints take one column however many bytes encode them.
	assert(byteColumnToDisplayColumn("éx", 3) == 2);
	assert(byteColumnToDisplayColumn("€x", 4) == 2);
	assert(byteColumnToDisplayColumn("\U0001F600x", 5) == 3);
	assert(byteColumnToDisplayColumn("中x", 4) == 3);
	assert(byteColumnToDisplayColumn("中中x", 7) == 5);
	assert(byteColumnToDisplayColumn("éx", 4) == 2);
	// Past the end of the line, the column stops at its last codepoint.
	assert(byteColumnToDisplayColumn("é", 3) == 2);
	// Invalid UTF-8 has no display columns, so byte columns stand in for them.
	assert(byteColumnToDisplayColumn("\xFF\xFEx", 3) == 3);
}

unittest {
	{
		// Every kind, each with a code.
		Manager manager;
		scope(exit) free(manager);
		assert(addSource(manager, "k.c", "line one\nline two\n"));
		static immutable Kind[4] kinds = [Kind.info, Kind.note, Kind.warning, Kind.error];
		foreach (i, kind; kinds) {
			Diagnostic diagnostic = makeDiagnostic(kind, "msg", LineColumnRange("k.c", LineColumn(1, 1), LineColumn(1, 5)));
			diagnostic.hasCode = true;
			diagnostic.code = i == 3 ? 1234 : i + 1;
			pushTo(manager, diagnostic);
		}
		static immutable string[9] needles = ["[E001]", "[E1234]", "Info", "Note", "Warning", "Error", "1 error", "1 warning", ", "];
		foreach (needle; needles)
			assert(renders(manager, needle));
	}
	{
		// Plural errors with no warnings, against an unregistered file.
		Manager manager;
		scope(exit) free(manager);
		foreach (i; 0 .. 2)
			pushTo(manager, makeDiagnostic(Kind.error, "bad", LineColumnRange("missing.c", LineColumn(1, 1), LineColumn(1, 1))));
		assert(renders(manager, "2 errors"));
		assert(!renders(manager, "warning"));
		assert(renders(manager, "(source not available)"));
	}
	{
		// No location: only the headline and closing note, with no source box.
		Manager manager;
		scope(exit) free(manager);
		Diagnostic diagnostic = makeDiagnostic(Kind.error, "cannot read missing.c", LineColumnRange.init);
		diagnostic.note = fp.string.clone("check the path").get;
		assert(diagnostic.note !is null);
		pushTo(manager, diagnostic);
		static immutable string[4] needles = ["cannot read missing.c", "Note:", "check the path", "1 error"];
		foreach (needle; needles)
			assert(renders(manager, needle));
		assert(!renders(manager, "┌─") && !renders(manager, "└─") && !renders(manager, "(source not available)"));
	}
	{
		// Plural warnings with no errors.
		Manager manager;
		scope(exit) free(manager);
		foreach (i; 0 .. 3)
			pushTo(manager, makeDiagnostic(Kind.warning, "careful", LineColumnRange("missing.c", LineColumn(1, 1), LineColumn(1, 1))));
		assert(renders(manager, "3 warnings"));
		assert(!renders(manager, "error"));
	}
	{
		// Several annotations on one line, one at its end, and one on a later line that widens the gutter.
		Manager manager;
		scope(exit) free(manager);
		assert(addSource(manager, "m.c", "int main() {\n    return 0;\n\n\n\n\n\n\n\n}"));
		Diagnostic diagnostic = makeDiagnostic(Kind.error, "bad name", LineColumnRange("m.c", LineColumn(1, 5), LineColumn(1, 9)));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(1, 1), "", "start", Ansi.green)));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(1, 5), "m.c", "here")));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(1, 0), "", "eol", Ansi.cyan)));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(2, 5), "", "returns")));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(10, 1), "", "closing")));
		pushTo(manager, diagnostic);
		static immutable string[6] needles = ["start", "here", "eol", "closing", Ansi.bold ~ " 1 │", Ansi.bold ~ "10 │"];
		foreach (needle; needles)
			assert(renders(manager, needle));
		assert(!renders(manager, Ansi.bold ~ "    return 0;"));
	}
	{
		// Locations pointing past the end of their line, or reversed, and an annotation on line 0.
		Manager manager;
		scope(exit) free(manager);
		assert(addSource(manager, "z.c", "abc"));
		pushTo(manager, makeDiagnostic(Kind.note, "at eof", LineColumnRange("z.c", LineColumn(1, 4), LineColumn(1, 4))));
		pushTo(manager, makeDiagnostic(Kind.note, "past eol", LineColumnRange("z.c", LineColumn(1, 9), LineColumn(1, 12))));
		Diagnostic reversed = makeDiagnostic(Kind.note, "reversed", LineColumnRange("z.c", LineColumn(1, 3), LineColumn(1, 2)));
		assert(fp.dynarray.pushBack(reversed.annotations, makeAnnotation(LineColumn(0, 1), "", "nowhere")));
		pushTo(manager, reversed);
		assert(renders(manager, "abc"));
		assert(renders(manager, "past eol"));
		assert(!renders(manager, "nowhere"));
	}
	{
		// A location running past the end of its file.
		Manager manager;
		scope(exit) free(manager);
		assert(addSource(manager, "big.c", "a\nb\nc"));
		pushTo(manager, makeDiagnostic(Kind.warning, "out of range", LineColumnRange("big.c", LineColumn(1, 1), LineColumn(10, 1))));
		assert(renders(manager, "c" ~ Ansi.reset ~ "\n"));
	}
	{
		// Files with lone \r and \r\n line breaks.
		Manager manager;
		scope(exit) free(manager);
		assert(addSource(manager, "cr.c", "first\rsecond\rthird"));
		pushTo(manager, makeDiagnostic(Kind.error, "cr error", LineColumnRange("cr.c", LineColumn(2, 1), LineColumn(2, 7))));
		assert(renders(manager, "second"));
		assert(!renders(manager, "first"));
	}
	{
		// Foreign files: two annotations in one, an unregistered one, a line past the end, and groups needing sorting.
		Manager manager;
		scope(exit) free(manager);
		assert(addSource(manager, "main.c", "main line\n"));
		assert(addSource(manager, "other.c", "other line one\nother line two\n"));
		Diagnostic diagnostic = makeDiagnostic(Kind.error, "cross-file", LineColumnRange("main.c", LineColumn(1, 1), LineColumn(1, 5)));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(1, 1), "other.c", "first", Ansi.blue)));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(2, 1), "other.c", "second", Ansi.blue)));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(1, 1), "missing.c", "third", Ansi.blue)));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(99, 1), "other.c", "fourth", Ansi.blue)));
		pushTo(manager, diagnostic);
		static immutable string[5] needles = ["other.c", "missing.c", "first", "second", "(source not available)"];
		foreach (needle; needles)
			assert(renders(manager, needle));
		assert(!renders(manager, "fourth"));
	}
	{
		// A context message and closing note, and a diagnostic with neither.
		Manager manager;
		scope(exit) free(manager);
		assert(addSource(manager, "ctx.c", "x = 1\n"));
		Diagnostic diagnostic = makeDiagnostic(Kind.error, "type mismatch", LineColumnRange("ctx.c", LineColumn(1, 1), LineColumn(1, 2)));
		diagnostic.contextMessage = fp.string.clone("in this expression").get;
		diagnostic.note = fp.string.clone("try casting instead").get;
		pushTo(manager, diagnostic);
		pushTo(manager, makeDiagnostic(Kind.info, "fyi", LineColumnRange("ctx.c", LineColumn(1, 1), LineColumn(1, 2))));
		static immutable string[3] needles = ["in this expression", "try casting instead", "Note:"];
		foreach (needle; needles)
			assert(renders(manager, needle));
	}
	{
		// Each allocation in turn is refused: rendering returns null and prints nothing, until it can finish.
		Manager manager;
		scope(exit) free(manager);
		assert(addSource(manager, "main.c", "int x = y;\n"));
		assert(addSource(manager, "other.c", "int y;\n"));
		Diagnostic diagnostic = makeDiagnostic(Kind.error, "mismatch", LineColumnRange("main.c", LineColumn(1, 9), LineColumn(1, 10)));
		diagnostic.hasCode = true;
		diagnostic.contextMessage = fp.string.clone("in this declaration").get;
		diagnostic.note = fp.string.clone("declare it first").get;
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(1, 5), "", "declared here")));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(1, 5), "other.c", "and here")));
		assert(fp.dynarray.pushBack(diagnostic.annotations, makeAnnotation(LineColumn(1, 1), "third.c", "and there")));
		pushTo(manager, diagnostic);

		char* expected = render(manager);
		scope(exit) fp.string.free(expected);
		assert(expected !is null);

		auto scratch = openScratch();
		scope(exit) fp.testing.free(scratch);
		for (size_t n = 0;; ++n) {
			auto previous = fp.testing.limitAllocations(n);
			char* rendered = render(manager);
			fp.testing.restoreAllocator(previous);
			if (rendered !is null) {
				assert(fp.string.equal(rendered, expected));
				fp.string.free(rendered);
				break;
			}
			previous = fp.testing.limitAllocations(n);
			assert(!printAll(manager, scratch.descriptor));
			fp.testing.restoreAllocator(previous);
			assert(printedLength(scratch) == 0);
		}
		assert(!printAll(manager, -1)); // a write that fails
		assert(printAll(manager, scratch.descriptor));
		assert(printedLength(scratch) == fp.string.length(expected));
	}
}
