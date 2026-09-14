module diagnose.diagnostics;

import diagnose.source_location;

import fp.dynarray : pushBack, deleteRange, daLength = length, daFree = free, daSlice = slice, daClear = clear;
import fp.string : concatenate, concatenateSlice, concatenateMultipleSlices, promoteLiteral, format, strFree = free, strLength = length, contains, splitSlices, codepointsSlice;

import std.algorithm.sorting : stdSort = sort;
import std.algorithm.comparison : min;
import std.algorithm.iteration : uniq;

import core.stdc.stdio : FILE, fwrite, stderr;

version (Windows) import core.sys.windows.windows;

/// Enables ANSI/VT100 escape sequence processing and UTF-8 output on the
/// Windows console; a no-op everywhere else (ANSI codes and UTF-8 already
/// work natively in Linux/macOS terminals). Unlike the original C++ port,
/// output goes through plain `core.stdc.stdio` byte writes rather than a
/// `nowide`-style stream, so there is no separate UTF-8/UTF-16 console
/// translation layer to enable — instead the console's active output code
/// page is switched to UTF-8 so the raw bytes we write are interpreted
/// correctly rather than through the legacy ANSI/OEM code page.
void enableAnsiColors() {
	version (Windows) {
		SetConsoleOutputCP(CP_UTF8);

		HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
		if (hOut == INVALID_HANDLE_VALUE) return;

		DWORD dwMode = 0;
		if (!GetConsoleMode(hOut, &dwMode)) return;

		dwMode |= ENABLE_VIRTUAL_TERMINAL_PROCESSING;
		SetConsoleMode(hOut, dwMode);
	}
}

/// ANSI color/style codes for terminal output.
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

	/// Cycles through foreground colors on each call.
	static const(char)[] nextColor() @nogc nothrow {
		static immutable string[16] fgColors = [
			black, red, green, yellow, blue, magenta, cyan, white,
			brightBlack, brightRed, brightGreen, brightYellow,
			brightBlue, brightMagenta, brightCyan, brightWhite
		];
		static size_t index = 0;
		immutable color = fgColors[index];
		index = (index + 1) % fgColors.length;
		return color;
	}

	/// Cycles through background colors on each call.
	static const(char)[] nextBg() @nogc nothrow {
		static immutable string[16] bgColors = [
			bgBlack, bgRed, bgGreen, bgYellow,
			bgBlue, bgMagenta, bgCyan, bgWhite,
			bgBrightBlack, bgBrightRed, bgBrightGreen, bgBrightYellow,
			bgBrightBlue, bgBrightMagenta, bgBrightCyan, bgBrightWhite
		];
		static size_t index = 0;
		immutable color = bgColors[index];
		index = (index + 1) % bgColors.length;
		return color;
	}
}


@nogc nothrow:


enum Kind { info, note, warning, error }

/// An extended diagnostic with support for generic annotations and
/// additional context.
struct Diagnostic {
	struct Annotation {
		Pair position;
		const(char)[] file; // Empty means "same file as the diagnostic's location"
		char* message; // Owned fp string
		const(char)[] color = Ansi.magenta;
	}

	Kind kind;
	bool hasCode = false;
	size_t code = 0;
	char* message; // Owned fp string
	Detailed location;

	Annotation* annotations; // fp dynarray of Annotation
	char* contextMessage; // Owned fp string, e.g. "The values are outputs of this match expression"; may be null
	char* additionalNote; // Owned fp string, e.g. "Outputs of match expressions must coerce to the same type"; may be null
}

ref Diagnostic pushAnnotation(ref Diagnostic diag, Diagnostic.Annotation a) @trusted {
	pushBack(diag.annotations, a);
	return diag;
}

ref Diagnostic pushAnnotationAtStart(ref Diagnostic diag, Diagnostic.Annotation a) {
	a.position = diag.location.start;
	return pushAnnotation(diag, a);
}

ref Diagnostic pushAnnotationAtEnd(ref Diagnostic diag, Diagnostic.Annotation a) {
	a.position = diag.location.end;
	return pushAnnotation(diag, a);
}

/// Frees everything `diag` owns (its message strings and its annotations,
/// including each annotation's own message). `diag` itself must not be used
/// afterwards.
void free(ref Diagnostic diag) @trusted {
	strFree(diag.message);
	strFree(diag.contextMessage);
	strFree(diag.additionalNote);
	foreach (i; 0 .. daLength(diag.annotations))
		strFree(diag.annotations[i].message);
	daFree(diag.annotations);
}

/// A registered source file: a non-owning view of both its name and text.
struct SourceFile {
	const(char)[] filename;
	const(char)[] source;
}

private bool tryGetSource(const SourceFile* files, const(char)[] filename, out const(char)[] source) @trusted {
	foreach (i; 0 .. daLength(files))
		if (files[i].filename == filename) {
			source = files[i].source;
			return true;
		}
	return false;
}

struct Manager {
	Diagnostic* diagnostics; // fp dynarray of Diagnostic
	SourceFile* sourceFiles; // fp dynarray of SourceFile

	@nogc nothrow:

	/// Registers (or replaces) the source text associated with `filename`.
	/// Both are stored as non-owning slices, so the memory they point into
	/// must outlive this manager.
	void registerSource(const(char)[] filename, const(char)[] source) @trusted {
		foreach (i; 0 .. daLength(sourceFiles))
			if (sourceFiles[i].filename == filename) {
				sourceFiles[i].source = source;
				return;
			}
		pushBack(sourceFiles, SourceFile(filename, source));
	}

	/// Takes ownership of `diag` -- don't use or free it again after this call.
	ref Diagnostic push(Diagnostic diag) @trusted {
		pushBack(diagnostics, diag);
		return diagnostics[daLength(diagnostics) - 1];
	}

	bool hasErrors() const @trusted {
		foreach (i; 0 .. daLength(diagnostics))
			if (diagnostics[i].kind == Kind.error) return true;
		return false;
	}

	size_t count() const @trusted { return daLength(diagnostics); }

	/// Frees every pushed diagnostic's owned memory and empties the list
	/// (registered source texts, being non-owning views, are untouched).
	void clear() @trusted {
		foreach (i; 0 .. daLength(diagnostics))
			free(diagnostics[i]);
		daClear(diagnostics);
	}

	/// Renders every pushed diagnostic into a single newly heap-allocated fp
	/// string (Ariadne-style: source context, annotations, and a trailing
	/// error/warning summary). The caller frees the result.
	char* render() const @trusted {
		static void printDiagnosticHeader(ref char* out_, const Diagnostic diag) @trusted {
			static void appendKindPrefix(ref char* out_, Kind kind) @trusted {
				final switch (kind) {
					case Kind.info:
						concatenateMultipleSlices(out_, Ansi.cyan, Ansi.bold, "Info");
						break;
					case Kind.note:
						concatenateMultipleSlices(out_, Ansi.blue, Ansi.bold, "Note");
						break;
					case Kind.warning:
						concatenateMultipleSlices(out_, Ansi.yellow, Ansi.bold, "Warning");
						break;
					case Kind.error:
						concatenateMultipleSlices(out_, Ansi.red, Ansi.bold, "Error");
						break;
				}
				concatenateSlice(out_, Ansi.reset);
			}

			if (diag.hasCode) {
				concatenateMultipleSlices(out_, Ansi.bold, getKindColor(diag.kind), "[E");
				char* code = format("%03zu".ptr, diag.code);
				scope(exit) strFree(code);
				concatenate(out_, code);
				concatenateSlice(out_, "] ");
			}

			appendKindPrefix(out_, diag.kind);
			concatenateMultipleSlices(out_, ": ", Ansi.reset, Ansi.bold, diag.message.daSlice, Ansi.reset, "\n");

			concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold, "┌─");
			char* loc = diag.location.toDisplayString();
			scope(exit) strFree(loc);
			concatenate(out_, loc);
			concatenateMultipleSlices(out_, Ansi.reset, "\n");
		}

		static void appendSummary(ref char* out_, size_t errorCount, size_t warningCount) @trusted {
			if (errorCount == 0 && warningCount == 0) return;

			concatenateSlice(out_, Ansi.bold);
			if (errorCount > 0) {
				concatenateSlice(out_, Ansi.red);
				appendSize(out_, errorCount);
				concatenateMultipleSlices(out_, errorCount != 1 ? " errors" : " error", Ansi.reset);
			}
			if (errorCount > 0 && warningCount > 0) {
				concatenateMultipleSlices(out_, Ansi.bold, ", ", Ansi.reset);
			}
			if (warningCount > 0) {
				concatenateMultipleSlices(out_, Ansi.yellow, Ansi.bold);
				appendSize(out_, warningCount);
				concatenateMultipleSlices(out_, warningCount != 1 ? " warnings" : " warning", Ansi.reset);
			}
			concatenateMultipleSlices(out_, Ansi.bold, " generated.", Ansi.reset, "\n");
		}

		char* out_ = null;

		immutable n = daLength(diagnostics);
		foreach (i; 0 .. n) {
			const diag = diagnostics[i];
			printDiagnosticHeader(out_, diag);

			const(char)[] source;
			if (tryGetSource(sourceFiles, diag.location.file, source))
				printSourceContext(out_, diag, source, sourceFiles);
			else appendUnavailableSourceNote(out_);

			concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold, "└─", Ansi.reset, "\n\n");
		}

		if (n > 0) {
			size_t errorCount = 0, warningCount = 0;
			foreach (i; 0 .. n) {
				if (diagnostics[i].kind == Kind.error) ++errorCount;
				else if (diagnostics[i].kind == Kind.warning) ++warningCount;
			}
			appendSummary(out_, errorCount, warningCount);
		}

		return out_;
	}

	/// Renders every pushed diagnostic and writes the UTF-8 result to `out`
	/// (`stderr` by default, matching the original's `nowide::cerr`).
	void printAll(FILE* out_ = stderr) const @trusted {
		char* rendered = render();
		scope(exit) strFree(rendered);
		if (rendered !is null)
			fwrite(rendered, 1, strLength(rendered), out_);
	}
}

/// Frees `mgr`'s diagnostics (and everything they own) and its registered
/// source file list. `mgr` itself must not be used again after this call.
void free(ref Manager mgr) @trusted {
	foreach (i; 0 .. daLength(mgr.diagnostics))
		free(mgr.diagnostics[i]);
	daFree(mgr.diagnostics);
	daFree(mgr.sourceFiles);
}


// ---------------------------------------------------------------------------
// Rendering internals
// ---------------------------------------------------------------------------


private const(char)[] getKindColor(Kind kind) @nogc nothrow {
	final switch (kind) {
		case Kind.info: return Ansi.cyan;
		case Kind.note: return Ansi.blue;
		case Kind.warning: return Ansi.yellow;
		case Kind.error: return Ansi.red;
	}
}

private void appendSpaces(ref char* out_, size_t n) @trusted {
	foreach (i; 0 .. n) concatenateSlice(out_, " ");
}

/// Number of decimal digits needed to print `value` (at least 1).
private size_t digitCount(size_t value) {
	size_t count = 1;
	while (value >= 10) {
		value /= 10;
		++count;
	}
	return count;
}

unittest {
	assert(digitCount(0) == 1);
	assert(digitCount(9) == 1);
	assert(digitCount(10) == 2);
	assert(digitCount(999) == 3);
	assert(digitCount(1000) == 4);
}

private void appendUnavailableSourceNote(ref char* out_) @trusted {
	concatenateMultipleSlices(out_, " ", Ansi.yellow, Ansi.bold, "(source not available)", Ansi.reset, "\n");
}

/// Zero-width codepoints: combining marks, joiners, and variation selectors.
/// Not an exhaustive Unicode combining-class table — covers the scripts and
/// symbols most likely to show up in diagnostic source text and messages.
private immutable uint[] zeroWidthRanges = [
	0x0300, 0x036F, // Combining Diacritical Marks
	0x0483, 0x0489, // Cyrillic combining marks
	0x0591, 0x05BD, 0x05BF, 0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7, 0x05C7, // Hebrew points
	0x0610, 0x061A, 0x064B, 0x065F, 0x0670, 0x0670, 0x06D6, 0x06DC, 0x06DF, 0x06E4, 0x06E7, 0x06E8,
	0x06EA, 0x06ED, // Arabic marks
	0x1AB0, 0x1AFF, // Combining Diacritical Marks Extended
	0x1DC0, 0x1DFF, // Combining Diacritical Marks Supplement
	0x200B, 0x200F, // Zero-width space / joiners / marks
	0x202A, 0x202E, // Directional formatting
	0x2060, 0x2064, // Word joiner and invisible operators
	0x20D0, 0x20FF, // Combining Diacritical Marks for Symbols
	0xFE00, 0xFE0F, // Variation selectors
	0xFE20, 0xFE2F, // Combining half marks
	0xFEFF, 0xFEFF, // Zero-width no-break space (BOM)
	0xE0100, 0xE01EF, // Variation selectors supplement
];

/// Double-width codepoints: CJK, Hangul, fullwidth forms, and most emoji.
/// A pragmatic approximation of East Asian Width "Wide"/"Fullwidth" (the same
/// approach used by terminal-width libraries like Rust's `unicode-width`) —
/// actual rendering still depends on the terminal emulator and font.
private immutable uint[] wideRanges = [
	0x1100, 0x115F, // Hangul Jamo
	0x2329, 0x232A, // Angle brackets
	0x2E80, 0x303E, // CJK Radicals, Kangxi, CJK Symbols and Punctuation
	0x3041, 0x33FF, // Hiragana .. CJK Compatibility
	0x3400, 0x4DBF, // CJK Extension A
	0x4E00, 0x9FFF, // CJK Unified Ideographs
	0xA000, 0xA4CF, // Yi Syllables and Radicals
	0xAC00, 0xD7A3, // Hangul Syllables
	0xF900, 0xFAFF, // CJK Compatibility Ideographs
	0xFE30, 0xFE4F, // CJK Compatibility Forms
	0xFF00, 0xFF60, 0xFFE0, 0xFFE6, // Fullwidth Forms
	0x16FE0, 0x16FE4, 0x17000, 0x18CFF, 0x1B000, 0x1B2FF, // CJK Extensions / scripts
	0x1F004, 0x1F004, 0x1F0CF, 0x1F0CF, // Mahjong/playing-card wide symbols used in emoji sets
	0x1F300, 0x1FAFF, // Misc symbols, emoji, and pictographs
	0x20000, 0x3FFFD, // CJK Extensions B..
];

/// Maps a 1-based byte column into `line` to the 1-based terminal display
/// column it actually renders at, accounting for multi-byte UTF-8 sequences
/// and double-width codepoints. `line` is the raw UTF-8 source line; `line`
/// itself is never re-encoded, only walked to accumulate display widths.
private size_t byteColumnToDisplayColumn(const(char)[] line, size_t byteColumn) @trusted {
	/// The number of UTF-8 bytes `encodeUtf8` (fp.string) would have used to
	/// encode `cp` — recovers per-codepoint byte length from `codepointsSlice`'s
	/// decoded output, since it hands back codepoints without their widths.
	static size_t utf8EncodedLength(uint cp) @safe @nogc nothrow pure {
		if (cp <= 0x7F) return 1;
		if (cp <= 0x7FF) return 2;
		if (cp <= 0xFFFF) return 3;
		return 4;
	}

	static int codepointDisplayWidth(uint cp) @safe @nogc nothrow pure {
		/// Returns true if `cp` falls in `[lo, hi]` for any pair in `ranges`
		/// (flattened as lo0, hi0, lo1, hi1, ...).
		static bool inRanges(uint cp, const uint[] ranges) @safe @nogc nothrow pure {
			for (size_t i = 0; i + 1 < ranges.length; i += 2)
				if (cp >= ranges[i] && cp <= ranges[i + 1]) return true;
			return false;
		}

		if (cp == 0 || inRanges(cp, zeroWidthRanges)) return 0;
		if (inRanges(cp, wideRanges)) return 2;
		return 1;
	}

	immutable targetByteIndex = byteColumn - 1; // 0-based byte offset the column refers to
	if (targetByteIndex == 0) return 1;

	uint* codepoints = codepointsSlice(line);
	if (codepoints is null) return byteColumn; // Invalid UTF-8: fall back to byte columns.
	scope(exit) daFree(codepoints);

	size_t byteIdx = 0;
	size_t displayCol = 1;
	foreach (i; 0 .. daLength(codepoints)) {
		if (byteIdx >= targetByteIndex) break;
		displayCol += codepointDisplayWidth(codepoints[i]);
		byteIdx += utf8EncodedLength(codepoints[i]);
	}
	return displayCol;
}

/// An annotation paired with its already-resolved display column (column 0
/// means "end of line").
private struct AnnotatedColumn {
	const(Diagnostic.Annotation)* annotation;
	size_t column;
}

private bool descByColumn(in AnnotatedColumn a, in AnnotatedColumn b) @nogc nothrow {
	return a.column > b.column;
}

private size_t effectiveColumn(size_t column, size_t lineLen) @nogc nothrow {
	return column == 0 ? lineLen + 1 : column;
}

/// A foreign file's annotations (grouped for the "points into another file" block).
private struct ForeignGroup {
	const(char)[] file;
	const(Diagnostic.Annotation)** annotations; // fp dynarray of Annotation*
}

/// Sorts the fp dynarray `arr` and removes adjacent duplicates in place,
/// shrinking its length to match. Replaces the `std::set<size_t>` used by
/// the original C++ to collect/dedupe/sort line numbers.
private void sortUnique(ref size_t* arr) @trusted {
	immutable n = daLength(arr);
	if (n == 0) return;

	stdSort(daSlice(arr));

	size_t write = 0;
	foreach (v; daSlice(arr).uniq)
		arr[write++] = v;
	if (write < n)
		deleteRange(arr, write, n - write, false);
}

unittest {
	size_t* arr = null;
	scope (exit) daFree(arr);
	int[7] vals = [3, 1, 2, 3, 1, 5, 2];
	foreach (v; vals)
		pushBack(arr, cast(size_t) v);

	sortUnique(arr);
	assert(daLength(arr) == 4);
	assert(arr[0] == 1 && arr[1] == 2 && arr[2] == 3 && arr[3] == 5);
}

private void printSourceContext(ref char* out_, const Diagnostic diag, const(char)[] source, const SourceFile* sourceFiles) @trusted {
	static void appendPadded(ref char* out_, size_t value, size_t width) @trusted {
		immutable digits = digitCount(value);
		if (width > digits) appendSpaces(out_, width - digits);
		appendSize(out_, value);
	}

	/// Collects the diagnostic's own-file annotations touching `lineNum`, sorted
	/// by display column descending (matches the original's right-to-left
	/// connector drawing order).
	static AnnotatedColumn* collectMainLineAnnotations(const Diagnostic.Annotation* annotations, const(char)[] diagFile, size_t lineNum, const(char)[] lineStr) @trusted {
		AnnotatedColumn* result = null;
		foreach (i; 0 .. daLength(annotations)) {
			const ann = &annotations[i];
			if ((ann.file.length == 0 || ann.file == diagFile) && ann.position.line == lineNum) {
				immutable byteCol = effectiveColumn(ann.position.column, lineStr.length);
				pushBack(result, AnnotatedColumn(ann, byteColumnToDisplayColumn(lineStr, byteCol)));
			}
		}
		stdSort!descByColumn(daSlice(result));
		return result;
	}

	/// Same as `collectMainLineAnnotations`, but over an already file-filtered
	/// group of annotation pointers (used for the "points into another file" case).
	static AnnotatedColumn* collectForeignLineAnnotations(const(Diagnostic.Annotation)** group, size_t lineNum, const(char)[] lineStr) @trusted {
		AnnotatedColumn* result = null;
		foreach (i; 0 .. daLength(group)) {
			const ann = group[i];
			if (ann.position.line == lineNum) {
				immutable byteCol = effectiveColumn(ann.position.column, lineStr.length);
				pushBack(result, AnnotatedColumn(ann, byteColumnToDisplayColumn(lineStr, byteCol)));
			}
		}
		stdSort!descByColumn(daSlice(result));
		return result;
	}

	static void printAnnotationsForLine(ref char* out_, const AnnotatedColumn* sorted, size_t lineNumWidth) @trusted {
		immutable n = daLength(sorted);
		foreach (i; 0 .. n) {
			const ann = sorted[i].annotation;
			immutable actualColumn = sorted[i].column;

			concatenateMultipleSlices(out_, "  ", Ansi.cyan, Ansi.bold);
			appendSpaces(out_, lineNumWidth);
			concatenateMultipleSlices(out_, "│", Ansi.reset, " ");

			foreach (col; 1 .. actualColumn) {
				bool hasLater = false;
				foreach (j; i + 1 .. n) {
					if (sorted[j].column == col) {
						concatenateMultipleSlices(out_, sorted[j].annotation.color, "│", Ansi.reset);
						hasLater = true;
						break;
					}
				}
				if (!hasLater) concatenateSlice(out_, " ");
			}

			concatenateMultipleSlices(out_, ann.color, "└─ ", Ansi.reset, ann.message.daSlice, "\n");
		}
	}

	static ForeignGroup* collectForeignGroups(const Diagnostic diag) @trusted {
		static bool byFileAscending(in ForeignGroup a, in ForeignGroup b) @nogc nothrow {
			return a.file < b.file;
		}

		ForeignGroup* groups = null;
		foreach (i; 0 .. daLength(diag.annotations)) {
			const ann = &diag.annotations[i];
			if (ann.file.length == 0 || ann.file == diag.location.file) continue;

			bool found = false;
			foreach (g; 0 .. daLength(groups))
				if (groups[g].file == ann.file) {
					pushBack(groups[g].annotations, ann);
					found = true;
					break;
				}
			if (!found) {
				ForeignGroup g;
				g.file = ann.file;
				pushBack(g.annotations, ann);
				pushBack(groups, g);
			}
		}
		stdSort!byFileAscending(daSlice(groups));
		return groups;
	}

	static void freeForeignGroups(ForeignGroup* groups) @trusted {
		foreach (g; 0 .. daLength(groups))
			daFree(groups[g].annotations);
		daFree(groups);
	}

	immutable startLine = diag.location.start.line;
	immutable endLine = diag.location.end.line;

	size_t* linesToPrint = null;
	scope(exit) daFree(linesToPrint);
	foreach (line; startLine .. endLine + 1)
		pushBack(linesToPrint, line);
	foreach (i; 0 .. daLength(diag.annotations)) {
		const ann = &diag.annotations[i];
		if (ann.file.length == 0 || ann.file == diag.location.file)
			pushBack(linesToPrint, ann.position.line);
	}
	sortUnique(linesToPrint);

	const(char)[]* lines = splitSlices(source, "\n");
	scope(exit) daFree(lines);

	immutable lineNumWidth = digitCount(endLine);
	const(char)[] kindColor = getKindColor(diag.kind);

	// Print the diagnostic's own source lines, highlighting its span.
	foreach (i; 0 .. daLength(linesToPrint)) {
		immutable lineNum = linesToPrint[i];
		if (lineNum > daLength(lines)) break;

		const(char)[] lineStr = lines[lineNum - 1];

		concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold);
		appendPadded(out_, lineNum, lineNumWidth);
		concatenateMultipleSlices(out_, " │ ", Ansi.reset, kindColor, "➤ ", Ansi.reset);

		immutable startCol = (lineNum == startLine) ? effectiveColumn(diag.location.start.column, lineStr.length) : 1;
		immutable endCol = (lineNum == endLine) ? effectiveColumn(diag.location.end.column, lineStr.length) : lineStr.length + 1;

		if (startCol > 1)
			concatenateSlice(out_, lineStr[0 .. startCol - 1]);

		immutable highlightStart = startCol - 1;
		immutable highlightLen = min(endCol - startCol, lineStr.length - highlightStart);
		if (highlightLen > 0)
			concatenateMultipleSlices(out_, kindColor, Ansi.bold, lineStr[highlightStart .. highlightStart + highlightLen], Ansi.reset);

		if (endCol - 1 < lineStr.length)
			concatenateSlice(out_, lineStr[endCol - 1 .. $]);

		concatenateSlice(out_, "\n");

		AnnotatedColumn* lineAnnotations = collectMainLineAnnotations(diag.annotations, diag.location.file, lineNum, lineStr);
		scope(exit) daFree(lineAnnotations);
		if (daLength(lineAnnotations) > 0)
			printAnnotationsForLine(out_, lineAnnotations, lineNumWidth);
	}

	// Print each foreign-file annotation group as its own block.
	ForeignGroup* groups = collectForeignGroups(diag);
	scope(exit) freeForeignGroups(groups);

	foreach (g; 0 .. daLength(groups)) {
		concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold);
		appendSpaces(out_, lineNumWidth);
		concatenateMultipleSlices(out_, " ·", Ansi.reset, "\n");

		concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold, "┌─ <\"", groups[g].file, "\">", Ansi.reset, "\n");

		const(char)[] foreignSource;
		if (!tryGetSource(sourceFiles, groups[g].file, foreignSource)) {
			appendUnavailableSourceNote(out_);
			continue;
		}

		const(char)[]* foreignLines = splitSlices(foreignSource, "\n");
		scope(exit) daFree(foreignLines);

		size_t* foreignLineSet = null;
		scope(exit) daFree(foreignLineSet);
		foreach (a; 0 .. daLength(groups[g].annotations))
			pushBack(foreignLineSet, groups[g].annotations[a].position.line);
		sortUnique(foreignLineSet);

		foreach (li; 0 .. daLength(foreignLineSet)) {
			immutable lineNum = foreignLineSet[li];
			if (lineNum > daLength(foreignLines)) continue;
			const(char)[] lineStr = foreignLines[lineNum - 1];

			concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold);
			appendPadded(out_, lineNum, lineNumWidth);
			concatenateMultipleSlices(out_, " │ ", Ansi.reset, kindColor, "➤ ", Ansi.reset, lineStr, "\n");

			AnnotatedColumn* lineAnnotations = collectForeignLineAnnotations(groups[g].annotations, lineNum, lineStr);
			scope(exit) daFree(lineAnnotations);
			printAnnotationsForLine(out_, lineAnnotations, lineNumWidth);
		}
	}

	// Print continuation dots.
	foreach (_; 0 .. 2) {
		concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold);
		appendSpaces(out_, lineNumWidth);
		concatenateMultipleSlices(out_, " ·", Ansi.reset, "\n");
	}

	if (diag.contextMessage !is null && strLength(diag.contextMessage) > 0) {
		concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold);
		appendSpaces(out_, lineNumWidth);
		concatenateMultipleSlices(out_, " └─", Ansi.reset, " ", diag.contextMessage.daSlice, "\n");
	}

	if (diag.additionalNote !is null && strLength(diag.additionalNote) > 0) {
		concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold);
		appendSpaces(out_, lineNumWidth);
		concatenateMultipleSlices(out_, " ·", Ansi.reset, "\n");

		concatenateMultipleSlices(out_, " ", Ansi.cyan, Ansi.bold);
		appendSpaces(out_, lineNumWidth);
		concatenateMultipleSlices(out_, " ", Ansi.reset, Ansi.blue, Ansi.bold, "Note:", Ansi.reset, " ", diag.additionalNote.daSlice, "\n");
	}
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------


unittest {
	assert(Ansi.nextColor() == Ansi.black);
	foreach (_; 0 .. 15)
		cast(void) Ansi.nextColor();
	assert(Ansi.nextColor() == Ansi.black); // wraps back around after 16 colors

	assert(Ansi.nextBg() == Ansi.bgBlack);
	foreach (_; 0 .. 15)
		cast(void) Ansi.nextBg();
	assert(Ansi.nextBg() == Ansi.bgBlack);
}

unittest {
	Diagnostic diag;
	diag.kind = Kind.error;
	diag.message = promoteLiteral("boom");
	diag.location = Detailed("a.c", Pair(3, 2), Pair(3, 9));

	diag.pushAnnotationAtStart(Diagnostic.Annotation(Pair.init, "", promoteLiteral("here"), Ansi.green));
	diag.pushAnnotationAtEnd(Diagnostic.Annotation(Pair.init, "", promoteLiteral("there"), Ansi.red));
	diag.pushAnnotation(Diagnostic.Annotation(Pair(1, 1), "b.c", promoteLiteral("elsewhere"), Ansi.blue));

	assert(daLength(diag.annotations) == 3);
	assert(diag.annotations[0].position == Pair(3, 2)); // filled in by pushAnnotationAtStart
	assert(diag.annotations[1].position == Pair(3, 9)); // filled in by pushAnnotationAtEnd
	assert(diag.annotations[2].position == Pair(1, 1)); // explicit position, untouched
	assert(diag.annotations[2].file == "b.c");

	free(diag);
}

unittest {
	Manager mgr;
	scope (exit) free(mgr);

	mgr.registerSource("a.c", "one\n");
	mgr.registerSource("a.c", "one\ntwo\n"); // overwrite the existing entry
	mgr.registerSource("b.c", "three\n");

	assert(mgr.count() == 0);
	assert(!mgr.hasErrors());

	Diagnostic note;
	note.kind = Kind.note;
	note.message = promoteLiteral("fyi");
	note.location = Detailed("a.c", Pair(1, 1), Pair(1, 4));
	mgr.push(note);

	assert(mgr.count() == 1);
	assert(!mgr.hasErrors());

	Diagnostic err;
	err.kind = Kind.error;
	err.message = promoteLiteral("bad");
	err.location = Detailed("a.c", Pair(1, 1), Pair(1, 4));
	mgr.push(err);

	assert(mgr.count() == 2);
	assert(mgr.hasErrors());

	mgr.clear();
	assert(mgr.count() == 0);
	assert(!mgr.hasErrors());

	assert(mgr.render() is null); // nothing pushed after clear()

	import core.stdc.stdio : tmpfile, fclose, ftell;

	auto f = tmpfile();
	scope (exit) fclose(f);
	mgr.printAll(f);
	assert(ftell(f) == 0); // printAll skips the write when render() returns null
}

unittest {
	// All four diagnostic kinds, each with a code: exercises getKindColor's
	// and appendKindPrefix's four switch cases, plus the `[Ennn]` prefix.
	static immutable(char)[] src = "line one\nline two\n";

	Manager mgr;
	scope (exit) free(mgr);
	mgr.registerSource("k.c", src);

	immutable Kind[4] kinds = [Kind.info, Kind.note, Kind.warning, Kind.error];
	foreach (i, k; kinds) {
		Diagnostic d;
		d.kind = k;
		d.hasCode = true;
		d.code = i + 1;
		d.message = promoteLiteral("msg");
		d.location = Detailed("k.c", Pair(1, 1), Pair(1, 5));
		mgr.push(d);
	}

	char* rendered = mgr.render();
	scope (exit) strFree(rendered);
	assert(rendered !is null);
	assert(contains(rendered, "[E001]", 0));
	assert(contains(rendered, "[E004]", 0));
	// The ANSI reset code sits between the kind word and the trailing colon,
	// so check for the words themselves rather than "Kind:".
	assert(contains(rendered, "Info", 0));
	assert(contains(rendered, "Note", 0));
	assert(contains(rendered, "Warning", 0));
	assert(contains(rendered, "Error", 0));
	assert(contains(rendered, "1 error", 0));
	assert(contains(rendered, "1 warning", 0));
	assert(contains(rendered, ", ", 0)); // joins "1 error" and "1 warning" in the summary
}

unittest {
	// Plural, error-only summary (no comma, since there are no warnings).
	Manager mgr;
	scope (exit) free(mgr);

	foreach (_; 0 .. 2) {
		Diagnostic d;
		d.kind = Kind.error;
		d.message = promoteLiteral("bad");
		d.location = Detailed("missing.c", Pair(1, 1), Pair(1, 1));
		mgr.push(d);
	}

	char* rendered = mgr.render();
	scope (exit) strFree(rendered);
	assert(contains(rendered, "2 errors", 0));
	assert(!contains(rendered, "warning", 0));
	assert(contains(rendered, "(source not available)", 0));
}

unittest {
	// Plural, warning-only summary.
	Manager mgr;
	scope (exit) free(mgr);

	foreach (_; 0 .. 3) {
		Diagnostic d;
		d.kind = Kind.warning;
		d.message = promoteLiteral("careful");
		d.location = Detailed("missing.c", Pair(1, 1), Pair(1, 1));
		mgr.push(d);
	}

	char* rendered = mgr.render();
	scope (exit) strFree(rendered);
	assert(contains(rendered, "3 warnings", 0));
	assert(!contains(rendered, "error", 0));
}

unittest {
	// Own-file annotations: multiple per line (descending-column sort and the
	// connector-drawing branches in printAnnotationsForLine) plus a column-0
	// ("end of line") annotation.
	static immutable(char)[] src = "int main() {\n    return 0;\n}";

	Manager mgr;
	scope (exit) free(mgr);
	mgr.registerSource("m.c", src);

	Diagnostic diag;
	diag.kind = Kind.error;
	diag.message = promoteLiteral("bad name");
	diag.location = Detailed("m.c", Pair(1, 5), Pair(1, 9)); // highlights "main"

	diag.pushAnnotation(Diagnostic.Annotation(Pair(1, 1), "", promoteLiteral("start"), Ansi.green));
	diag.pushAnnotation(Diagnostic.Annotation(Pair(1, 5), "m.c", promoteLiteral("here"), Ansi.magenta));
	diag.pushAnnotation(Diagnostic.Annotation(Pair(1, 0), "", promoteLiteral("eol"), Ansi.cyan));
	mgr.push(diag);

	char* rendered = mgr.render();
	scope (exit) strFree(rendered);
	assert(contains(rendered, "start", 0));
	assert(contains(rendered, "here", 0));
	assert(contains(rendered, "eol", 0));
}

unittest {
	// A zero-width location (start == end, pointing past the end of the
	// line): exercises the "nothing to highlight" branches.
	static immutable(char)[] src = "abc";

	Manager mgr;
	scope (exit) free(mgr);
	mgr.registerSource("z.c", src);

	Diagnostic diag;
	diag.kind = Kind.note;
	diag.message = promoteLiteral("at eof");
	diag.location = Detailed("z.c", Pair(1, 4), Pair(1, 4));
	mgr.push(diag);

	char* rendered = mgr.render();
	scope (exit) strFree(rendered);
	assert(contains(rendered, "abc", 0));
}

unittest {
	// A diagnostic spanning past the end of its registered source: exercises
	// the "line past end of file" break and multi-digit line-number padding.
	static immutable(char)[] src = "a\nb\nc"; // 3 lines, no trailing newline

	Manager mgr;
	scope (exit) free(mgr);
	mgr.registerSource("big.c", src);

	Diagnostic diag;
	diag.kind = Kind.warning;
	diag.message = promoteLiteral("out of range");
	diag.location = Detailed("big.c", Pair(1, 1), Pair(10, 1));
	mgr.push(diag);

	char* rendered = mgr.render();
	scope (exit) strFree(rendered);
	assert(rendered !is null);
	assert(contains(rendered, "a", 0));
	assert(contains(rendered, "c", 0));
}

unittest {
	// Foreign-file annotation groups: two annotations in the same foreign
	// file (existing-group branch), an unregistered foreign file (unavailable
	// branch), and a foreign line past the end of its file (continue branch).
	// The insertion order below ("other.c" group created before "missing.c")
	// also forces collectForeignGroups' sort to actually reorder them.
	static immutable(char)[] mainSrc = "main line\n";
	static immutable(char)[] otherSrc = "other line one\nother line two\n";

	Manager mgr;
	scope (exit) free(mgr);
	mgr.registerSource("main.c", mainSrc);
	mgr.registerSource("other.c", otherSrc);
	// "missing.c" intentionally left unregistered.

	Diagnostic diag;
	diag.kind = Kind.error;
	diag.message = promoteLiteral("cross-file");
	diag.location = Detailed("main.c", Pair(1, 1), Pair(1, 5));

	diag.pushAnnotation(Diagnostic.Annotation(Pair(1, 1), "other.c", promoteLiteral("first"), Ansi.blue));
	diag.pushAnnotation(Diagnostic.Annotation(Pair(2, 1), "other.c", promoteLiteral("second"), Ansi.blue));
	diag.pushAnnotation(Diagnostic.Annotation(Pair(1, 1), "missing.c", promoteLiteral("third"), Ansi.blue));
	diag.pushAnnotation(Diagnostic.Annotation(Pair(99, 1), "other.c", promoteLiteral("fourth"), Ansi.blue));
	mgr.push(diag);

	char* rendered = mgr.render();
	scope (exit) strFree(rendered);
	assert(contains(rendered, "other.c", 0));
	assert(contains(rendered, "missing.c", 0));
	assert(contains(rendered, "first", 0));
	assert(contains(rendered, "second", 0));
	assert(contains(rendered, "(source not available)", 0));
}

unittest {
	// contextMessage and additionalNote, both present and both absent.
	static immutable(char)[] src = "x = 1\n";

	Manager mgr;
	scope (exit) free(mgr);
	mgr.registerSource("ctx.c", src);

	Diagnostic diag;
	diag.kind = Kind.error;
	diag.message = promoteLiteral("type mismatch");
	diag.location = Detailed("ctx.c", Pair(1, 1), Pair(1, 2));
	diag.contextMessage = promoteLiteral("in this expression");
	diag.additionalNote = promoteLiteral("try casting instead");
	mgr.push(diag);

	Diagnostic bare;
	bare.kind = Kind.info;
	bare.message = promoteLiteral("fyi");
	bare.location = Detailed("ctx.c", Pair(1, 1), Pair(1, 2));
	mgr.push(bare);

	char* rendered = mgr.render();
	scope (exit) strFree(rendered);
	assert(contains(rendered, "in this expression", 0));
	assert(contains(rendered, "try casting instead", 0));
	assert(contains(rendered, "Note:", 0));
}

unittest {
	// printAll writing a non-empty render to a real FILE*.
	Manager mgr;
	scope (exit) free(mgr);

	Diagnostic diag;
	diag.kind = Kind.error;
	diag.message = promoteLiteral("bad");
	diag.location = Detailed("p.c", Pair(1, 1), Pair(1, 1));
	mgr.push(diag);

	import core.stdc.stdio : tmpfile, fclose, ftell;

	auto f = tmpfile();
	scope (exit) fclose(f);
	mgr.printAll(f);
	assert(ftell(f) > 0);
}

