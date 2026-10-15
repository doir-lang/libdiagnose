/// Ariadne-style compiler diagnostics: a `Manager` collects `Diagnostic`s against registered source files and renders them with the source lines they point at.
module diagnose.diagnostics;

public import diagnose.source_location : Pair, Detailed;
static import diagnose.source_location;
static import fp.dynarray;
static import fp.pointer;
static import fp.string;

import core.stdc.stdio : FILE, fwrite, stderr;
import std.algorithm.comparison : max, min;
import std.algorithm.iteration : uniq;
import std.algorithm.sorting : sort;

version(Windows) import core.sys.windows.windows;

@nogc nothrow:


/// Switches the Windows console to UTF-8 output and ANSI escape processing; terminals elsewhere already handle both, so there it does nothing.
///
/// Returns false on Windows if standard output is not a console, such as when it is redirected, or the console refused either setting.
///
/// Examples:
/// ---
/// cast(void) enableAnsiColorsAndUTF8();
/// ---
bool enableAnsiColorsAndUTF8() {
	version(Windows) {
		if (!SetConsoleOutputCP(CP_UTF8)) return false;
		HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
		DWORD mode = 0;
		if (output == INVALID_HANDLE_VALUE || !GetConsoleMode(output, &mode)) return false;
		return SetConsoleMode(output, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0;
	} else return true;
}

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
		Pair position; /// Where it points; a column of 0 means the end of the line.
		const(char)[] file; /// The file it points into; empty means the diagnostic's own file.
		char* message; /// An owned fp string.
		const(char)[] color = Ansi.magenta; /// The ANSI color its connector is drawn in.
	}

	Kind kind; /// How severe it is.
	bool hasCode = false; /// Whether the header shows `code`, as `[E001]`.
	size_t code = 0; /// The code the header shows when `hasCode` is set.
	char* message; /// An owned fp string, the headline.
	Detailed location; /// The range it highlights; a column of 0 means the end of the line.
	Annotation* annotations; /// An owned fp dynarray.
	char* contextMessage; /// An owned fp string summarizing what the location is, such as "The values are outputs of this match expression", or null.
	char* additionalNote; /// An owned fp string giving a closing note, such as "Outputs of match expressions must coerce to the same type", or null.
}

/// Appends `annotation` to `diag`, which takes over its message.
///
/// Returns false if an allocation was refused, leaving `diag` unchanged and the message still the caller's.
///
/// Examples:
/// ---
/// Diagnostic diag;
/// scope(exit) free(diag);
/// assert(pushAnnotation(diag, Diagnostic.Annotation(Pair(1, 1), "", fp.string.makeDynamic("here"))));
/// assert(fp.dynarray.length(diag.annotations) == 1);
/// ---
bool pushAnnotation(ref Diagnostic diag, Diagnostic.Annotation annotation) @trusted {
	return fp.dynarray.pushBack(diag.annotations, annotation);
}

/// Appends `annotation` to `diag`, as `pushAnnotation` does, pointing at the start of `diag.location`.
///
/// Returns false if an allocation was refused, leaving `diag` unchanged and the message still the caller's.
///
/// Examples:
/// ---
/// Diagnostic diag;
/// scope(exit) free(diag);
/// diag.location = Detailed("a.c", Pair(2, 5), Pair(2, 9));
/// assert(pushAnnotationAtStart(diag, Diagnostic.Annotation(Pair.init, "", fp.string.makeDynamic("here"))));
/// assert(diag.annotations[0].position == Pair(2, 5));
/// ---
bool pushAnnotationAtStart(ref Diagnostic diag, Diagnostic.Annotation annotation) {
	annotation.position = diag.location.start;
	return pushAnnotation(diag, annotation);
}

/// Appends `annotation` to `diag`, as `pushAnnotation` does, pointing at the end of `diag.location`.
///
/// Returns false if an allocation was refused, leaving `diag` unchanged and the message still the caller's.
///
/// Examples:
/// ---
/// Diagnostic diag;
/// scope(exit) free(diag);
/// diag.location = Detailed("a.c", Pair(2, 5), Pair(2, 9));
/// assert(pushAnnotationAtEnd(diag, Diagnostic.Annotation(Pair.init, "", fp.string.makeDynamic("there"))));
/// assert(diag.annotations[0].position == Pair(2, 9));
/// ---
bool pushAnnotationAtEnd(ref Diagnostic diag, Diagnostic.Annotation annotation) {
	annotation.position = diag.location.end;
	return pushAnnotation(diag, annotation);
}

/// Frees everything `diag` owns: its messages, and its annotations with theirs, nulling its pointers to them.
///
/// Examples:
/// ---
/// Diagnostic diag;
/// diag.message = fp.string.makeDynamic("unused variable");
/// free(diag);
/// assert(diag.message is null);
/// ---
void free(ref Diagnostic diag) @trusted {
	fp.string.free(diag.message);
	fp.string.free(diag.contextMessage);
	fp.string.free(diag.additionalNote);
	foreach (i; 0 .. fp.dynarray.length(diag.annotations))
		fp.string.free(diag.annotations[i].message);
	fp.dynarray.free(diag.annotations);
}


/// A registered source file: views of its name and text, which whoever registered it keeps alive.
struct SourceFile {
	const(char)[] filename; /// The name diagnostics refer to it by.
	const(char)[] source; /// Its full text.
}

private size_t indexOfFile(const SourceFile* files, const(char)[] filename) @trusted {
	foreach (i; 0 .. fp.dynarray.length(files))
		if (files[i].filename == filename) return i;
	return fp.pointer.notFound;
}

private bool tryGetSource(const SourceFile* files, const(char)[] filename, out const(char)[] source) @trusted {
	immutable i = indexOfFile(files, filename);
	if (i == fp.pointer.notFound) return false;
	source = files[i].source;
	return true;
}

/// Collects diagnostics and the source files they point into, and renders them. Release it with `free`.
struct Manager {
	Diagnostic* diagnostics; /// An owned fp dynarray of the diagnostics pushed.
	SourceFile* sourceFiles; /// An fp dynarray of the registered files, whose names and text it borrows.
}


/// Registers `source` as the text of `filename`, replacing any earlier registration of `filename`. Both are borrowed, not copied, so end the registration with `deregisterSource` or `clear` before freeing either; a later registration compares against every registered name.
///
/// Returns false if an allocation was refused, leaving the registrations as they were.
///
/// Examples:
/// ---
/// Manager mgr;
/// scope(exit) free(mgr);
/// assert(registerSource(mgr, "a.c", "int x;\n"));
/// assert(registerSource(mgr, "a.c", "int y;\n"));
/// assert(fp.dynarray.length(mgr.sourceFiles) == 1);
/// ---
bool registerSource(ref Manager mgr, const(char)[] filename, const(char)[] source) @trusted {
	immutable i = indexOfFile(mgr.sourceFiles, filename);
	if (i == fp.pointer.notFound) return fp.dynarray.pushBack(mgr.sourceFiles, SourceFile(filename, source));
	mgr.sourceFiles[i].source = source;
	return true;
}

/// Ends the registration of `filename`, if there is one, and returns whether there was. Diagnostics already pushed against it still render, noting that its source is unavailable.
///
/// Examples:
/// ---
/// Manager mgr;
/// scope(exit) free(mgr);
/// assert(registerSource(mgr, "a.c", "int x;\n"));
/// assert(deregisterSource(mgr, "a.c"));
/// assert(!deregisterSource(mgr, "a.c"));
/// ---
bool deregisterSource(ref Manager mgr, const(char)[] filename) @trusted {
	immutable i = indexOfFile(mgr.sourceFiles, filename);
	if (i == fp.pointer.notFound) return false;
	// Shrinking without matching capacity never reallocates, so it cannot fail.
	cast(void) fp.dynarray.deleteRange(mgr.sourceFiles, i, 1, false);
	return true;
}

/// Appends `diag` to `mgr`, which takes over everything it owns. Returns the stored copy, valid until the next `push`, `clear` or `free`.
///
/// Returns null if an allocation was refused, leaving `mgr` unchanged and what `diag` owns still the caller's.
///
/// Examples:
/// ---
/// Manager mgr;
/// scope(exit) free(mgr);
/// Diagnostic diag;
/// diag.message = fp.string.makeDynamic("unused variable");
/// Diagnostic* stored = push(mgr, diag);
/// assert(stored !is null && stored.message is diag.message);
/// ---
Diagnostic* push(ref Manager mgr, Diagnostic diag) @trusted {
	if (!fp.dynarray.pushBack(mgr.diagnostics, diag)) return null;
	return &mgr.diagnostics[fp.dynarray.length(mgr.diagnostics) - 1];
}


/// Whether any diagnostic pushed to `mgr` is an error.
///
/// Examples:
/// ---
/// Manager mgr;
/// scope(exit) free(mgr);
/// Diagnostic diag;
/// diag.kind = Kind.error;
/// assert(push(mgr, diag) !is null);
/// assert(hasErrors(mgr));
/// ---
bool hasErrors(const ref Manager mgr) @trusted {
	foreach (i; 0 .. fp.dynarray.length(mgr.diagnostics))
		if (mgr.diagnostics[i].kind == Kind.error) return true;
	return false;
}

/// How many diagnostics have been pushed to `mgr`.
///
/// Examples:
/// ---
/// Manager mgr;
/// scope(exit) free(mgr);
/// assert(count(mgr) == 0);
/// assert(push(mgr, Diagnostic.init) !is null);
/// assert(count(mgr) == 1);
/// ---
size_t count(const ref Manager mgr) @trusted { return fp.dynarray.length(mgr.diagnostics); }


/// Frees every diagnostic pushed to `mgr` and ends every registration, keeping `mgr` usable. Registrations end too because `mgr` cannot know whether the text they borrow outlives the diagnostics; re-register any that should.
///
/// Examples:
/// ---
/// Manager mgr;
/// scope(exit) free(mgr);
/// assert(registerSource(mgr, "a.c", "int x;\n"));
/// assert(push(mgr, Diagnostic.init) !is null);
/// clear(mgr);
/// assert(count(mgr) == 0 && !deregisterSource(mgr, "a.c"));
/// ---
void clear(ref Manager mgr) @trusted {
	foreach (i; 0 .. fp.dynarray.length(mgr.diagnostics))
		free(mgr.diagnostics[i]);
	fp.dynarray.clear(mgr.diagnostics);
	fp.dynarray.clear(mgr.sourceFiles);
}

/// Frees `mgr`'s diagnostics, everything they own, and its list of registrations, nulling its pointers to them.
///
/// Examples:
/// ---
/// Manager mgr;
/// assert(push(mgr, Diagnostic.init) !is null);
/// free(mgr);
/// assert(mgr.diagnostics is null);
/// ---
void free(ref Manager mgr) @trusted {
	clear(mgr);
	fp.dynarray.free(mgr.diagnostics);
	fp.dynarray.free(mgr.sourceFiles);
}


// Rendered text, and whether an allocation was refused while writing it; once one is, later writes are skipped.
private struct Output {
	char* text;
	bool failed;
}

private void put(Args...)(ref Output output, Args pieces) {
	if (output.failed) return;
	bool empty = true;
	static foreach (i, A; Args) {
		static if (fp.string.isStringLike!A) empty = empty && fp.string.slice(pieces[i]).length == 0;
		else empty = false;
	}
	// `concatenateMultiple` also returns null when `text` is null and every piece is empty, which is no failure.
	output.failed = fp.string.concatenateMultiple(output.text, pieces) is null && !empty;
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

private void appendUnavailableSourceNote(ref Output output) {
	put(output, " ", Ansi.yellow, Ansi.bold, "(source not available)", Ansi.reset, "\n");
}


// Zero-width codepoints as [low, high] pairs: combining marks, joiners and variation selectors likely in source text, not the full Unicode table.
private immutable uint[] zeroWidthRanges = [
	0x0300, 0x036F, // Combining Diacritical Marks
	0x0483, 0x0489, // Cyrillic combining marks
	0x0591, 0x05BD, 0x05BF, 0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7, 0x05C7, // Hebrew points
	0x0610, 0x061A, 0x064B, 0x065F, 0x0670, 0x0670, 0x06D6, 0x06DC, 0x06DF, 0x06E4, 0x06E7, 0x06E8,
	0x06EA, 0x06ED, // Arabic marks
	0x1AB0, 0x1AFF, // Combining Diacritical Marks Extended
	0x1DC0, 0x1DFF, // Combining Diacritical Marks Supplement
	0x200B, 0x200F, // Zero-width space, joiners and marks
	0x202A, 0x202E, // Directional formatting
	0x2060, 0x2064, // Word joiner and invisible operators
	0x20D0, 0x20FF, // Combining Diacritical Marks for Symbols
	0xFE00, 0xFE0F, // Variation selectors
	0xFE20, 0xFE2F, // Combining half marks
	0xFEFF, 0xFEFF, // Zero-width no-break space (BOM)
	0xE0100, 0xE01EF, // Variation selectors supplement
];

// Double-width codepoints as [low, high] pairs, approximating East Asian Width Wide and Fullwidth, plus most emoji, as Rust's `unicode-width` does.
private immutable uint[] wideRanges = [
	0x1100, 0x115F, // Hangul Jamo
	0x2329, 0x232A, // Angle brackets
	0x2E80, 0x303E, // CJK Radicals, Kangxi, CJK Symbols and Punctuation
	0x3041, 0x33FF, // Hiragana to CJK Compatibility
	0x3400, 0x4DBF, // CJK Extension A
	0x4E00, 0x9FFF, // CJK Unified Ideographs
	0xA000, 0xA4CF, // Yi Syllables and Radicals
	0xAC00, 0xD7A3, // Hangul Syllables
	0xF900, 0xFAFF, // CJK Compatibility Ideographs
	0xFE30, 0xFE4F, // CJK Compatibility Forms
	0xFF00, 0xFF60, 0xFFE0, 0xFFE6, // Fullwidth Forms
	0x16FE0, 0x16FE4, 0x17000, 0x18CFF, 0x1B000, 0x1B2FF, // CJK Extensions and scripts
	0x1F004, 0x1F004, 0x1F0CF, 0x1F0CF, // Mahjong and playing-card symbols used in emoji sets
	0x1F300, 0x1FAFF, // Misc symbols, emoji, and pictographs
	0x20000, 0x3FFFD, // CJK Extension B onwards
];

private bool inRanges(uint codepoint, const uint[] ranges) {
	for (size_t i = 0; i + 1 < ranges.length; i += 2)
		if (codepoint >= ranges[i] && codepoint <= ranges[i + 1]) return true;
	return false;
}

private size_t codepointDisplayWidth(uint codepoint) {
	if (codepoint == 0 || inRanges(codepoint, zeroWidthRanges)) return 0;
	if (inRanges(codepoint, wideRanges)) return 2;
	return 1;
}

// The terminal column 1-based `byteColumn` of the UTF-8 `line` displays at, counting double- and zero-width codepoints.
private size_t byteColumnToDisplayColumn(const(char)[] line, size_t byteColumn) {
	immutable target = byteColumn - 1;
	size_t i = 0;
	size_t column = 1;
	while (i < target && i < line.length) {
		bool valid;
		immutable codepoint = fp.string.decodeUtf8(line, i, valid);
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
private AnnotatedColumn* collectMainLineAnnotations(ref Output output, ref const Diagnostic diag, size_t lineNumber, const(char)[] line) @trusted {
	AnnotatedColumn* result = null;
	foreach (i; 0 .. fp.dynarray.length(diag.annotations)) {
		const annotation = &diag.annotations[i];
		if ((annotation.file.length == 0 || annotation.file == diag.location.file) && annotation.position.line == lineNumber)
			pushResolved(output, result, annotation, line);
	}
	sort!descByColumn(fp.dynarray.slice(result));
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
	sort!descByColumn(fp.dynarray.slice(result));
	return result;
}

private bool byFileAscending(in ForeignGroup a, in ForeignGroup b) {
	return a.file < b.file;
}

private ForeignGroup* collectForeignGroups(ref Output output, ref const Diagnostic diag) @trusted {
	ForeignGroup* groups = null;
	foreach (i; 0 .. fp.dynarray.length(diag.annotations)) {
		const annotation = &diag.annotations[i];
		if (annotation.file.length == 0 || annotation.file == diag.location.file) continue;

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
	sort!byFileAscending(fp.dynarray.slice(groups));
	return groups;
}

private void freeForeignGroups(ForeignGroup* groups) @trusted {
	foreach (g; 0 .. fp.dynarray.length(groups))
		fp.dynarray.free(groups[g].annotations);
	fp.dynarray.free(groups);
}

// Sorts `array` and removes its duplicates.
private void sortUnique(ref size_t* array) @trusted {
	immutable n = fp.dynarray.length(array);
	sort(fp.dynarray.slice(array));
	size_t write = 0;
	foreach (value; fp.dynarray.slice(array).uniq)
		array[write++] = value;
	// Shrinking without matching capacity never reallocates, so it cannot fail.
	if (write < n) cast(void) fp.dynarray.deleteRange(array, write, n - write, false);
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

private void appendSourceContext(ref Output output, ref const Diagnostic diag, const(char)[] source, const SourceFile* sourceFiles) @trusted {
	immutable startLine = diag.location.start.line;
	immutable endLine = diag.location.end.line;

	size_t* lineNumbers = null;
	scope(exit) fp.dynarray.free(lineNumbers);
	foreach (line; startLine .. endLine + 1)
		pushOrFail(output, lineNumbers, line);
	foreach (i; 0 .. fp.dynarray.length(diag.annotations)) {
		const annotation = &diag.annotations[i];
		if (annotation.file.length == 0 || annotation.file == diag.location.file)
			pushOrFail(output, lineNumbers, annotation.position.line);
	}
	sortUnique(lineNumbers);

	ForeignGroup* groups = collectForeignGroups(output, diag);
	scope(exit) freeForeignGroups(groups);

	size_t widest = endLine;
	if (fp.dynarray.length(lineNumbers) > 0) widest = max(widest, lineNumbers[fp.dynarray.length(lineNumbers) - 1]);
	foreach (g; 0 .. fp.dynarray.length(groups))
		foreach (a; 0 .. fp.dynarray.length(groups[g].annotations))
			widest = max(widest, groups[g].annotations[a].position.line);
	immutable width = digitCount(widest);
	immutable kindColor = kindStyles[diag.kind].color;

	const(char)[]* lines = fp.string.split(source, "\n");
	scope(exit) fp.dynarray.free(lines);
	if (lines is null) output.failed = true;

	foreach (i; 0 .. fp.dynarray.length(lineNumbers)) {
		immutable lineNumber = lineNumbers[i];
		if (lineNumber == 0 || lineNumber > fp.dynarray.length(lines)) continue;
		const(char)[] line = lines[lineNumber - 1];
		appendSourceLine(output, lineNumber, width, kindColor);

		// A line shown only for its annotations lies outside the location, so nothing on it is highlighted.
		size_t startColumn = line.length + 1;
		size_t endColumn = line.length + 1;
		if (lineNumber >= startLine && lineNumber <= endLine) {
			if (lineNumber == startLine) startColumn = min(effectiveColumn(diag.location.start.column, line.length), line.length + 1);
			else startColumn = 1;
			if (lineNumber == endLine) endColumn = max(startColumn, min(effectiveColumn(diag.location.end.column, line.length), line.length + 1));
		}
		put(output, line[0 .. startColumn - 1]);
		if (endColumn > startColumn) put(output, kindColor, Ansi.bold, line[startColumn - 1 .. endColumn - 1], Ansi.reset);
		put(output, line[endColumn - 1 .. $], "\n");

		AnnotatedColumn* annotations = collectMainLineAnnotations(output, diag, lineNumber, line);
		scope(exit) fp.dynarray.free(annotations);
		appendAnnotations(output, annotations, width);
	}

	foreach (g; 0 .. fp.dynarray.length(groups)) {
		appendContinuationRow(output, width);
		put(output, " ", Ansi.cyan, Ansi.bold, "┌─ <\"", groups[g].file, "\">", Ansi.reset, "\n");

		const(char)[] foreignSource;
		if (!tryGetSource(sourceFiles, groups[g].file, foreignSource)) {
			appendUnavailableSourceNote(output);
			continue;
		}
		const(char)[]* foreignLines = fp.string.split(foreignSource, "\n");
		scope(exit) fp.dynarray.free(foreignLines);
		if (foreignLines is null) output.failed = true;

		size_t* foreignLineNumbers = null;
		scope(exit) fp.dynarray.free(foreignLineNumbers);
		foreach (a; 0 .. fp.dynarray.length(groups[g].annotations))
			pushOrFail(output, foreignLineNumbers, groups[g].annotations[a].position.line);
		sortUnique(foreignLineNumbers);

		foreach (i; 0 .. fp.dynarray.length(foreignLineNumbers)) {
			immutable lineNumber = foreignLineNumbers[i];
			if (lineNumber == 0 || lineNumber > fp.dynarray.length(foreignLines)) continue;
			const(char)[] line = foreignLines[lineNumber - 1];
			appendSourceLine(output, lineNumber, width, kindColor);
			put(output, line, "\n");

			AnnotatedColumn* annotations = collectForeignLineAnnotations(output, groups[g].annotations, lineNumber, line);
			scope(exit) fp.dynarray.free(annotations);
			appendAnnotations(output, annotations, width);
		}
	}

	appendContinuationRow(output, width);
	appendContinuationRow(output, width);

	if (fp.string.length(diag.contextMessage) > 0) {
		appendGutter(output, width, " └─");
		put(output, " ", fp.string.slice(diag.contextMessage), "\n");
	}
	if (fp.string.length(diag.additionalNote) > 0) {
		appendContinuationRow(output, width);
		appendGutter(output, width, " ");
		put(output, Ansi.blue, Ansi.bold, "Note:", Ansi.reset, " ", fp.string.slice(diag.additionalNote), "\n");
	}
}

private void appendHeader(ref Output output, ref const Diagnostic diag) @trusted {
	immutable style = kindStyles[diag.kind];
	if (diag.hasCode) {
		put(output, Ansi.bold, style.color, "[E");
		foreach (i; digitCount(diag.code) .. 3) put(output, '0');
		put(output, diag.code, "] ");
	}
	put(output, style.color, Ansi.bold, style.name, Ansi.reset);
	put(output, ": ", Ansi.reset, Ansi.bold, fp.string.slice(diag.message), Ansi.reset, "\n");

	char* location = diagnose.source_location.toDisplayString(diag.location);
	scope(exit) fp.string.free(location);
	if (location is null) output.failed = true;
	put(output, " ", Ansi.cyan, Ansi.bold, "┌─", location, Ansi.reset, "\n");
}

private void appendCount(ref Output output, size_t n, const(char)[] color, const(char)[] singular, const(char)[] plural) {
	put(output, color, Ansi.bold, n, n != 1 ? plural : singular, Ansi.reset);
}

private void appendSummary(ref Output output, const ref Manager mgr) @trusted {
	size_t errors = 0, warnings = 0;
	foreach (i; 0 .. fp.dynarray.length(mgr.diagnostics)) {
		if (mgr.diagnostics[i].kind == Kind.error) ++errors;
		else if (mgr.diagnostics[i].kind == Kind.warning) ++warnings;
	}
	if (errors == 0 && warnings == 0) return;

	put(output, Ansi.bold);
	if (errors > 0) appendCount(output, errors, Ansi.red, " error", " errors");
	if (errors > 0 && warnings > 0) put(output, Ansi.bold, ", ", Ansi.reset);
	if (warnings > 0) appendCount(output, warnings, Ansi.yellow, " warning", " warnings");
	put(output, Ansi.bold, " generated.", Ansi.reset, "\n");
}


/// Renders every diagnostic pushed to `mgr` into a new fp string: each one's header, the source lines it points at with its annotations, then a count of errors and warnings. The caller frees it with `fp.string.free`.
///
/// Returns null if nothing was pushed, or if an allocation was refused.
///
/// Examples:
/// ---
/// Manager mgr;
/// scope(exit) free(mgr);
/// assert(registerSource(mgr, "a.c", "int x = y;\n"));
/// Diagnostic diag;
/// diag.kind = Kind.error;
/// diag.message = fp.string.makeDynamic("undefined identifier");
/// diag.location = Detailed("a.c", Pair(1, 9), Pair(1, 10));
/// assert(push(mgr, diag) !is null);
/// char* text = render(mgr);
/// scope(exit) fp.string.free(text);
/// assert(fp.string.contains(text, "undefined identifier", 0));
/// ---
char* render(const ref Manager mgr) @trusted {
	Output output;
	foreach (i; 0 .. fp.dynarray.length(mgr.diagnostics)) {
		const diag = &mgr.diagnostics[i];
		appendHeader(output, *diag);
		const(char)[] source;
		if (tryGetSource(mgr.sourceFiles, diag.location.file, source))
			appendSourceContext(output, *diag, source, mgr.sourceFiles);
		else appendUnavailableSourceNote(output);
		put(output, " ", Ansi.cyan, Ansi.bold, "└─", Ansi.reset, "\n\n");
	}
	appendSummary(output, mgr);
	if (output.failed) fp.string.free(output.text);
	return output.text;
}

/// Renders every diagnostic pushed to `mgr`, as `render` does, and writes the UTF-8 result to `file`.
///
/// Returns false, having written nothing, if an allocation was refused, or if the write fell short.
///
/// Examples:
/// ---
/// Manager mgr;
/// scope(exit) free(mgr);
/// assert(printAll(mgr));
/// ---
bool printAll(const ref Manager mgr, FILE* file = stderr) @trusted {
	char* rendered = render(mgr);
	scope(exit) fp.string.free(rendered);
	if (rendered is null) return count(mgr) == 0;
	immutable length = fp.string.length(rendered);
	return fwrite(rendered, 1, length, file) == length;
}


version(unittest) {
	static import core.stdc.stdio;
	static import core.stdc.stdlib;
	static import core.stdc.string;
	import diagnose.source_location : failAfter, stopFailing;

	private Diagnostic makeDiagnostic(Kind kind, const(char)[] message, Detailed location) {
		Diagnostic diag;
		diag.kind = kind;
		diag.message = fp.string.makeDynamic(message);
		assert(diag.message !is null);
		diag.location = location;
		return diag;
	}

	private Diagnostic.Annotation makeAnnotation(Pair position, const(char)[] file, const(char)[] message, const(char)[] color = Ansi.magenta) {
		char* text = fp.string.makeDynamic(message);
		assert(text !is null);
		return Diagnostic.Annotation(position, file, text, color);
	}

	private void pushTo(ref Manager mgr, Diagnostic diag) {
		assert(push(mgr, diag) !is null);
	}

	version(WASI) private extern(C) FILE* fmemopen(void* buffer, size_t size, const(char)* mode);

	// A writable file to print into; WASI has no `tmpfile`, so there it writes to memory instead.
	private FILE* scratchFile() {
		version(WASI) {
			static char[4096] buffer;
			return fmemopen(buffer.ptr, buffer.length, "w");
		} else return core.stdc.stdio.tmpfile();
	}

	// Whether rendering `mgr` gives text containing `needle`.
	private bool renders(const ref Manager mgr, const(char)[] needle) {
		char* rendered = render(mgr);
		scope(exit) fp.string.free(rendered);
		return fp.string.contains(rendered, needle, 0);
	}
}


unittest {
	version(Windows) {} else assert(enableAnsiColorsAndUTF8());

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
	Diagnostic diag = makeDiagnostic(Kind.error, "boom", Detailed("a.c", Pair(3, 2), Pair(3, 9)));
	scope(exit) free(diag);

	assert(diag.pushAnnotationAtStart(makeAnnotation(Pair.init, "", "here", Ansi.green)));
	assert(diag.pushAnnotationAtEnd(makeAnnotation(Pair.init, "", "there", Ansi.red)));
	assert(diag.pushAnnotation(makeAnnotation(Pair(1, 1), "b.c", "elsewhere", Ansi.blue)));
	assert(fp.dynarray.length(diag.annotations) == 3);
	assert(diag.annotations[0].position == Pair(3, 2));
	assert(diag.annotations[1].position == Pair(3, 9));
	assert(diag.annotations[2].position == Pair(1, 1) && diag.annotations[2].file == "b.c");

	// A refused allocation leaves the diagnostic as it was, and the message the caller's.
	Diagnostic empty;
	Diagnostic.Annotation refused = makeAnnotation(Pair(1, 1), "", "refused");
	failAfter(0);
	assert(!empty.pushAnnotation(refused));
	assert(empty.annotations is null);
	fp.string.free(refused.message);
}

unittest {
	Manager mgr;
	scope(exit) free(mgr);

	assert(registerSource(mgr, "a.c", "one\n"));
	assert(registerSource(mgr, "a.c", "one\ntwo\n"));
	assert(registerSource(mgr, "b.c", "three\n"));
	assert(fp.dynarray.length(mgr.sourceFiles) == 2);

	assert(count(mgr) == 0 && !hasErrors(mgr));
	pushTo(mgr, makeDiagnostic(Kind.note, "fyi", Detailed("a.c", Pair(1, 1), Pair(1, 4))));
	assert(count(mgr) == 1 && !hasErrors(mgr));
	Diagnostic* stored = push(mgr, makeDiagnostic(Kind.error, "bad", Detailed("a.c", Pair(1, 1), Pair(1, 4))));
	assert(stored is &mgr.diagnostics[1]);
	assert(count(mgr) == 2 && hasErrors(mgr));

	// Refused allocations leave the manager as it was, and the diagnostic the caller's.
	Manager empty;
	Diagnostic refused = makeDiagnostic(Kind.error, "refused", Detailed.init);
	failAfter(0);
	assert(!registerSource(empty, "c.c", "four\n"));
	failAfter(0);
	assert(push(empty, refused) is null);
	assert(empty.sourceFiles is null && count(empty) == 0);
	free(refused);

	clear(mgr);
	assert(count(mgr) == 0 && !hasErrors(mgr));
	assert(render(mgr) is null);
	assert(!deregisterSource(mgr, "a.c"));
	assert(!deregisterSource(mgr, "b.c"));

	auto file = scratchFile();
	assert(file !is null);
	scope(exit) cast(void) core.stdc.stdio.fclose(file);
	assert(printAll(mgr, file));
	assert(core.stdc.stdio.ftell(file) == 0);
}

unittest { // a registration is a borrow, and both ways of ending it work
	// Heap filenames, freed while the manager is still in use, make a dangling registration a use-after-free under -fsanitize=address.
	Manager mgr;
	scope(exit) free(mgr);

	enum aName = "a.c";
	enum bName = "b.c";
	char* a = cast(char*) core.stdc.stdlib.malloc(aName.length);
	char* b = cast(char*) core.stdc.stdlib.malloc(bName.length);
	assert(a !is null && b !is null);
	cast(void) core.stdc.string.memcpy(a, aName.ptr, aName.length);
	cast(void) core.stdc.string.memcpy(b, bName.ptr, bName.length);

	assert(registerSource(mgr, a[0 .. aName.length], "alpha\n"));
	assert(registerSource(mgr, b[0 .. bName.length], "beta\n"));
	const(char)[] found;
	assert(tryGetSource(mgr.sourceFiles, "a.c", found) && found == "alpha\n");

	assert(deregisterSource(mgr, a[0 .. aName.length]));
	core.stdc.stdlib.free(a);
	assert(!deregisterSource(mgr, "a.c"));
	assert(!deregisterSource(mgr, "never-registered.c"));
	assert(!tryGetSource(mgr.sourceFiles, "a.c", found));
	assert(tryGetSource(mgr.sourceFiles, "b.c", found) && found == "beta\n");

	// Compares against every surviving name, which would read `a` had deregistering not dropped it.
	assert(registerSource(mgr, "c.c", "gamma\n"));

	pushTo(mgr, makeDiagnostic(Kind.error, "file is gone", Detailed("a.c", Pair(1, 1), Pair(1, 2))));
	assert(renders(mgr, "(source not available)"));

	clear(mgr);
	core.stdc.stdlib.free(b);
	assert(!deregisterSource(mgr, "b.c"));
	assert(!tryGetSource(mgr.sourceFiles, "b.c", found));
	assert(registerSource(mgr, "d.c", "delta\n"));
	assert(tryGetSource(mgr.sourceFiles, "d.c", found) && found == "delta\n");
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

	size_t* array = null;
	scope(exit) fp.dynarray.free(array);
	sortUnique(array);
	assert(fp.dynarray.length(array) == 0);
	static immutable size_t[7] values = [3, 1, 2, 3, 1, 5, 2];
	foreach (value; values)
		assert(fp.dynarray.pushBack(array, value));
	sortUnique(array);
	assert(fp.dynarray.slice(array) == [1, 2, 3, 5]);
}

unittest {
	{
		// Every kind, each with a code.
		Manager mgr;
		scope(exit) free(mgr);
		assert(registerSource(mgr, "k.c", "line one\nline two\n"));
		static immutable Kind[4] kinds = [Kind.info, Kind.note, Kind.warning, Kind.error];
		foreach (i, kind; kinds) {
			Diagnostic diag = makeDiagnostic(kind, "msg", Detailed("k.c", Pair(1, 1), Pair(1, 5)));
			diag.hasCode = true;
			diag.code = i == 3 ? 1234 : i + 1;
			pushTo(mgr, diag);
		}
		static immutable string[9] needles = ["[E001]", "[E1234]", "Info", "Note", "Warning", "Error", "1 error", "1 warning", ", "];
		foreach (needle; needles)
			assert(renders(mgr, needle));
	}
	{
		// Plural errors with no warnings, against an unregistered file.
		Manager mgr;
		scope(exit) free(mgr);
		foreach (i; 0 .. 2)
			pushTo(mgr, makeDiagnostic(Kind.error, "bad", Detailed("missing.c", Pair(1, 1), Pair(1, 1))));
		assert(renders(mgr, "2 errors"));
		assert(!renders(mgr, "warning"));
		assert(renders(mgr, "(source not available)"));
	}
	{
		// Plural warnings with no errors.
		Manager mgr;
		scope(exit) free(mgr);
		foreach (i; 0 .. 3)
			pushTo(mgr, makeDiagnostic(Kind.warning, "careful", Detailed("missing.c", Pair(1, 1), Pair(1, 1))));
		assert(renders(mgr, "3 warnings"));
		assert(!renders(mgr, "error"));
	}
	{
		// Several annotations on one line, one at its end, and one on a later line that widens the gutter.
		Manager mgr;
		scope(exit) free(mgr);
		assert(registerSource(mgr, "m.c", "int main() {\n    return 0;\n\n\n\n\n\n\n\n}"));
		Diagnostic diag = makeDiagnostic(Kind.error, "bad name", Detailed("m.c", Pair(1, 5), Pair(1, 9)));
		assert(diag.pushAnnotation(makeAnnotation(Pair(1, 1), "", "start", Ansi.green)));
		assert(diag.pushAnnotation(makeAnnotation(Pair(1, 5), "m.c", "here")));
		assert(diag.pushAnnotation(makeAnnotation(Pair(1, 0), "", "eol", Ansi.cyan)));
		assert(diag.pushAnnotation(makeAnnotation(Pair(2, 5), "", "returns")));
		assert(diag.pushAnnotation(makeAnnotation(Pair(10, 1), "", "closing")));
		pushTo(mgr, diag);
		static immutable string[6] needles = ["start", "here", "eol", "closing", Ansi.bold ~ " 1 │", Ansi.bold ~ "10 │"];
		foreach (needle; needles)
			assert(renders(mgr, needle));
		assert(!renders(mgr, Ansi.bold ~ "    return 0;"));
	}
	{
		// Locations pointing past the end of their line, or reversed, and an annotation on line 0.
		Manager mgr;
		scope(exit) free(mgr);
		assert(registerSource(mgr, "z.c", "abc"));
		pushTo(mgr, makeDiagnostic(Kind.note, "at eof", Detailed("z.c", Pair(1, 4), Pair(1, 4))));
		pushTo(mgr, makeDiagnostic(Kind.note, "past eol", Detailed("z.c", Pair(1, 9), Pair(1, 12))));
		Diagnostic reversed = makeDiagnostic(Kind.note, "reversed", Detailed("z.c", Pair(1, 3), Pair(1, 2)));
		assert(reversed.pushAnnotation(makeAnnotation(Pair(0, 1), "", "nowhere")));
		pushTo(mgr, reversed);
		assert(renders(mgr, "abc"));
		assert(renders(mgr, "past eol"));
		assert(!renders(mgr, "nowhere"));
	}
	{
		// A location running past the end of its file.
		Manager mgr;
		scope(exit) free(mgr);
		assert(registerSource(mgr, "big.c", "a\nb\nc"));
		pushTo(mgr, makeDiagnostic(Kind.warning, "out of range", Detailed("big.c", Pair(1, 1), Pair(10, 1))));
		assert(renders(mgr, "c" ~ Ansi.reset ~ "\n"));
	}
	{
		// Foreign files: two annotations in one, an unregistered one, a line past the end, and groups needing sorting.
		Manager mgr;
		scope(exit) free(mgr);
		assert(registerSource(mgr, "main.c", "main line\n"));
		assert(registerSource(mgr, "other.c", "other line one\nother line two\n"));
		Diagnostic diag = makeDiagnostic(Kind.error, "cross-file", Detailed("main.c", Pair(1, 1), Pair(1, 5)));
		assert(diag.pushAnnotation(makeAnnotation(Pair(1, 1), "other.c", "first", Ansi.blue)));
		assert(diag.pushAnnotation(makeAnnotation(Pair(2, 1), "other.c", "second", Ansi.blue)));
		assert(diag.pushAnnotation(makeAnnotation(Pair(1, 1), "missing.c", "third", Ansi.blue)));
		assert(diag.pushAnnotation(makeAnnotation(Pair(99, 1), "other.c", "fourth", Ansi.blue)));
		pushTo(mgr, diag);
		static immutable string[5] needles = ["other.c", "missing.c", "first", "second", "(source not available)"];
		foreach (needle; needles)
			assert(renders(mgr, needle));
		assert(!renders(mgr, "fourth"));
	}
	{
		// A context message and closing note, and a diagnostic with neither.
		Manager mgr;
		scope(exit) free(mgr);
		assert(registerSource(mgr, "ctx.c", "x = 1\n"));
		Diagnostic diag = makeDiagnostic(Kind.error, "type mismatch", Detailed("ctx.c", Pair(1, 1), Pair(1, 2)));
		diag.contextMessage = fp.string.makeDynamic("in this expression");
		diag.additionalNote = fp.string.makeDynamic("try casting instead");
		pushTo(mgr, diag);
		pushTo(mgr, makeDiagnostic(Kind.info, "fyi", Detailed("ctx.c", Pair(1, 1), Pair(1, 2))));
		static immutable string[3] needles = ["in this expression", "try casting instead", "Note:"];
		foreach (needle; needles)
			assert(renders(mgr, needle));
	}
	{
		// Each allocation in turn is refused: rendering returns null and prints nothing, until it can finish.
		Manager mgr;
		scope(exit) free(mgr);
		assert(registerSource(mgr, "main.c", "int x = y;\n"));
		assert(registerSource(mgr, "other.c", "int y;\n"));
		Diagnostic diag = makeDiagnostic(Kind.error, "mismatch", Detailed("main.c", Pair(1, 9), Pair(1, 10)));
		diag.hasCode = true;
		diag.contextMessage = fp.string.makeDynamic("in this declaration");
		diag.additionalNote = fp.string.makeDynamic("declare it first");
		assert(diag.pushAnnotation(makeAnnotation(Pair(1, 5), "", "declared here")));
		assert(diag.pushAnnotation(makeAnnotation(Pair(1, 5), "other.c", "and here")));
		assert(diag.pushAnnotation(makeAnnotation(Pair(1, 1), "third.c", "and there")));
		pushTo(mgr, diag);

		char* expected = render(mgr);
		scope(exit) fp.string.free(expected);
		assert(expected !is null);

		auto file = scratchFile();
		assert(file !is null);
		scope(exit) cast(void) core.stdc.stdio.fclose(file);
		for (size_t n = 0;; ++n) {
			failAfter(n);
			char* rendered = render(mgr);
			stopFailing();
			if (rendered !is null) {
				assert(fp.string.equal(rendered, expected));
				fp.string.free(rendered);
				break;
			}
			failAfter(n);
			assert(!printAll(mgr, file));
			stopFailing();
			assert(core.stdc.stdio.ftell(file) == 0);
		}
		assert(printAll(mgr, file));
		assert(core.stdc.stdio.ftell(file) == fp.string.length(expected));
	}
}
