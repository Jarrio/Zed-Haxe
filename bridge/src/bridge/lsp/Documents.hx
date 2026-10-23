package bridge.lsp;

typedef Position = {line:Int, character:Int};
typedef Range = {start:Position, end:Position};
typedef ContentChange = {?range:Range, text:String};

/**
	Keeps the text of open documents, following `didOpen`/`didChange`/`didClose`,
	so the bridge can look at the line under the cursor.

	LSP positions count UTF-16 code units, which is exactly how JavaScript strings index.
**/
class Documents {
	final texts = new Map<String, String>();

	public function new() {}

	public function open(uri:String, text:String) {
		texts.set(uri, text);
	}

	public function close(uri:String) {
		texts.remove(uri);
	}

	public function change(uri:String, changes:Array<ContentChange>) {
		var text = texts.get(uri);
		if (text == null) {
			return;
		}
		for (change in changes) {
			final range = change.range;
			if (range == null) {
				text = change.text;
			} else {
				final start = offsetAt(text, range.start);
				final end = offsetAt(text, range.end);
				text = text.substring(0, start) + change.text + text.substring(end);
			}
		}
		texts.set(uri, text);
	}

	public function uris():Array<String> {
		return [for (uri in texts.keys()) uri];
	}

	/** The whole text of an open document, or null. **/
	public function text(uri:String):Null<String> {
		return texts.get(uri);
	}

	/** The LSP position of `offset` in `text`. **/
	public static function positionAt(text:String, offset:Int):Position {
		var line = 0;
		var lineStart = 0;
		var next = text.indexOf("\n");
		while (next >= 0 && next < offset) {
			line++;
			lineStart = next + 1;
			next = text.indexOf("\n", lineStart);
		}
		return {line: line, character: offset - lineStart};
	}

	/** The text of line `line` (without its line break), or null. **/
	public function line(uri:String, line:Int):Null<String> {
		final text = texts.get(uri);
		if (text == null) {
			return null;
		}
		final start = offsetAt(text, {line: line, character: 0});
		var end = text.indexOf("\n", start);
		if (end < 0) {
			end = text.length;
		}
		final content = text.substring(start, end);
		return StringTools.endsWith(content, "\r") ? content.substr(0, content.length - 1) : content;
	}

	public static function offsetAt(text:String, position:Position):Int {
		var offset = 0;
		for (_ in 0...position.line) {
			final next = text.indexOf("\n", offset);
			if (next < 0) {
				return text.length;
			}
			offset = next + 1;
		}
		return Std.int(Math.min(offset + position.character, text.length));
	}
}
