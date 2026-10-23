package bridge.lsp;

import bridge.util.Uris;

/** A replacement in a file's text: `removed` characters at `at` become `text`. **/
typedef TextEdit = {
	final at:Int;
	final removed:Int;
	final text:String;
}

/**
	A copy of a Haxe file with code added for the compiler to answer about (completion, hover...
	at code that isn't really there), sent as the file's contents. It keeps the edits that made it,
	so positions in Haxe's answer can be moved back to the real file.
**/
class Probe {
	public final file:String;
	public final text:String;

	/** Where the compiler is asked, in `text`. **/
	public final offset:Int;

	final original:String;

	/** In order, with offsets in `original`. **/
	final edits:Array<TextEdit>;

	function new(file:String, original:String, edits:Array<TextEdit>, offset:Int) {
		this.file = file;
		this.original = original;
		this.edits = edits;
		this.offset = offset;
		text = apply(original, edits);
	}

	/**
		`head + tail` at the start of `className`'s body (or in a new class at the end of the file when it
		isn't found), after `edits`. The compiler is asked between the two.
	**/
	public static function inClass(file:String, text:String, className:String, head:String, tail:String, edits:Array<TextEdit>):Probe {
		final declaration = new EReg('\\bclass\\s+$className\\b[^{]*\\{', "");
		final found = declaration.match(text);
		final at = found ? declaration.matchedPos().pos + declaration.matchedPos().len : text.length;
		final opening = found ? head : '\nprivate class HaxeZedProbe {$head';
		final all = edits.concat([{at: at, removed: 0, text: opening + tail + (found ? "" : "}\n")}]);
		all.sort((a, b) -> a.at - b.at);
		var shift = 0;
		for (edit in all) {
			if (edit.at < at) {
				shift += edit.text.length - edit.removed;
			}
		}
		return new Probe(file, text, all, at + shift + opening.length);
	}

	/** `code` in a function of a class added at the end of the file; the compiler is asked at `offsetInCode`. **/
	public static function atEnd(file:String, text:String, code:String, offsetInCode:Int):Probe {
		final opening = '\nprivate class HaxeZedProbe { static function haxeZedProbe() { ';
		final edit:TextEdit = {at: text.length, removed: 0, text: opening + code + ' } }\n'};
		return new Probe(file, text, [edit], text.length + opening.length + offsetInCode);
	}

	/** Where an offset in the probe's text is in the real file; inside inserted text, the start of the edit. **/
	public function toOriginal(offset:Int):Int {
		var shift = 0;
		for (edit in edits) {
			final start = edit.at + shift;
			if (offset < start) {
				break;
			}
			if (offset < start + edit.text.length) {
				return edit.at;
			}
			shift += edit.text.length - edit.removed;
		}
		return offset - shift;
	}

	/** Locations Haxe gave in the probe's text, moved to where they are in the real file. **/
	public function realLocations(locations:Array<Dynamic>):Array<Dynamic> {
		final uri = Uris.fromPath(file);
		for (location in locations) {
			if (Uris.sameFile(location.uri, uri)) {
				final start = toOriginal(Documents.offsetAt(text, location.range.start));
				final end = toOriginal(Documents.offsetAt(text, location.range.end));
				location.range = {start: Documents.positionAt(original, start), end: Documents.positionAt(original, end)};
			}
		}
		return locations;
	}

	static function apply(text:String, edits:Array<TextEdit>):String {
		final result = new StringBuf();
		var last = 0;
		for (edit in edits) {
			result.add(text.substring(last, edit.at));
			result.add(edit.text);
			last = edit.at + edit.removed;
		}
		result.add(text.substr(last));
		return result.toString();
	}
}
