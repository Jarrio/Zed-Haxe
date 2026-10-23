package bridge.markup;

/** Where an offset falls inside a piece of XML markup. **/
enum XmlPosition {
	/** On a tag name after `<`. `start`/`end` delimit the whole name; `parents` are the open elements around it. **/
	TagName(name:String, start:Int, end:Int, parents:Array<String>);

	/** On a tag name after `</`. `open` is the innermost element still open. **/
	CloseTagName(name:String, start:Int, end:Int, open:Null<String>);

	/** On an attribute name inside a start tag, or where one can be typed (then `name` is empty). **/
	AttributeName(tag:String, name:String, start:Int, end:Int, present:Array<String>);

	/** Inside a quoted attribute value. `valueStart` is the offset just after the opening quote. **/
	AttributeValue(tag:String, attribute:String, value:String, valueStart:Int);

	/** Text, comments, or anywhere else. **/
	Other;
}

typedef XmlElement = {
	final name:String;
	final attributes:Map<String, String>;

	/** Offset of the `<`. **/
	final start:Int;
}

private enum Step {
	Found(position:XmlPosition);
	Next(index:Int);
}

/**
	A forgiving XML scanner for markup that is being typed: it never fails on incomplete input.
	Attribute values may contain `<` and `>` (HaxeUI event handlers are Haxe code).
**/
class XmlCursor {
	/** What is at `offset` in `text`. **/
	public static function at(text:String, offset:Int):XmlPosition {
		return scan(text, offset, null);
	}

	/** Every start tag in `text`, in document order. **/
	public static function elements(text:String):Array<XmlElement> {
		final found = [];
		scan(text, -1, found);
		return found;
	}

	/**
		Offset just past the element that starts at `start` (a `<`), or `text.length` while it isn't closed yet.
	**/
	public static function elementEnd(text:String, start:Int):Int {
		final stack = [];
		var i = start;
		while (i < text.length) {
			if (text.charAt(i) != "<") {
				i++;
				continue;
			}
			switch tag(text, i, -1, stack, null) {
				case Next(next):
					i = next;
					if (stack.length == 0) {
						return next;
					}
				case Found(_):
					return text.length;
			}
		}
		return text.length;
	}

	static function scan(text:String, offset:Int, found:Null<Array<XmlElement>>):XmlPosition {
		final stack = [];
		var i = 0;
		final limit = offset < 0 ? text.length : offset;
		while (i < limit) {
			if (text.charAt(i) != "<") {
				i++;
				continue;
			}
			switch tag(text, i, offset, stack, found) {
				case Found(position):
					return position;
				case Next(next):
					i = next;
			}
		}
		return Other;
	}

	/** Reads the markup construct starting at the `<` at `i`. **/
	static function tag(text:String, i:Int, offset:Int, stack:Array<String>, found:Null<Array<XmlElement>>):Step {
		for (pair in [["<!--", "-->"], ["<![CDATA[", "]]>"], ["<?", "?>"], ["<!", ">"]]) {
			if (text.substr(i, pair[0].length) == pair[0]) {
				final end = text.indexOf(pair[1], i + pair[0].length);
				if (end < 0 || (offset >= 0 && end + pair[1].length > offset)) {
					return Found(Other);
				}
				return Next(end + pair[1].length);
			}
		}

		final closing = text.charAt(i + 1) == "/";
		final nameStart = i + (closing ? 2 : 1);
		final nameEnd = skipName(text, nameStart);
		final name = text.substring(nameStart, nameEnd);
		if (offset >= nameStart && offset <= nameEnd) {
			return Found(closing ? CloseTagName(name, nameStart, nameEnd, stack[stack.length - 1]) : TagName(name, nameStart, nameEnd, stack.copy()));
		}

		if (closing) {
			final end = text.indexOf(">", nameEnd);
			if (end < 0 || (offset >= 0 && end >= offset)) {
				return Found(Other);
			}
			final index = stack.lastIndexOf(name);
			if (index >= 0) {
				stack.splice(index, stack.length - index);
			}
			return Next(end + 1);
		}

		final attributes = new Map<String, String>();
		final present = [];
		var k = nameEnd;
		while (k < text.length) {
			final spaceStart = k;
			k = skipSpace(text, k);
			if (offset >= 0 && offset > spaceStart && offset <= k && (offset < k || !isNameChar(text.charCodeAt(k)))) {
				// After whitespace in a start tag, and not at the start of an existing attribute: a new one can go here.
				return Found(AttributeName(name, "", offset, offset, present.concat(attributeNames(text, k))));
			}
			final char = text.charAt(k);
			if (char == ">" || (char == "/" && text.charAt(k + 1) == ">")) {
				final selfClosing = char == "/";
				final tagEnd = k + (selfClosing ? 2 : 1);
				if (offset >= 0 && offset < tagEnd) {
					return Found(Other);
				}
				if (found != null) {
					found.push({name: name, attributes: attributes, start: i});
				}
				if (!selfClosing) {
					stack.push(name);
				}
				return Next(tagEnd);
			}
			if (char == "<") {
				// An unclosed start tag followed by another tag.
				return Next(k);
			}

			final attributeStart = k;
			k = skipName(text, k);
			final attribute = text.substring(attributeStart, k);
			if (offset >= attributeStart && offset <= k && attribute != "") {
				return Found(AttributeName(name, attribute, attributeStart, k, present.concat(attributeNames(text, skipValue(text, k)))));
			}
			if (attribute == "") {
				k++;
				continue;
			}
			present.push(attribute);
			k = skipSpace(text, k);
			if (text.charAt(k) != "=") {
				continue;
			}
			k = skipSpace(text, k + 1);
			final quote = text.charAt(k);
			if (quote != '"' && quote != "'") {
				continue;
			}
			final valueStart = k + 1;
			var valueEnd = text.indexOf(quote, valueStart);
			if (valueEnd < 0) {
				valueEnd = text.length;
			}
			final value = text.substring(valueStart, valueEnd);
			if (offset >= valueStart && offset <= valueEnd) {
				return Found(AttributeValue(name, attribute, value, valueStart));
			}
			attributes.set(attribute, value);
			k = valueEnd + 1;
		}
		return offset >= 0 ? Found(Other) : Next(text.length);
	}

	/** Names of the attributes from `i` to the end of the start tag. **/
	static function attributeNames(text:String, i:Int):Array<String> {
		final names = [];
		var k = skipSpace(text, i);
		while (k < text.length && !["<", ">", "/"].contains(text.charAt(k))) {
			final start = k;
			k = skipName(text, k);
			if (k == start) {
				k++;
			} else {
				names.push(text.substring(start, k));
			}
			k = skipSpace(text, skipValue(text, k));
		}
		return names;
	}

	/** Skips `="..."` after an attribute name, if present. **/
	static function skipValue(text:String, i:Int):Int {
		var k = skipSpace(text, i);
		if (text.charAt(k) != "=") {
			return i;
		}
		k = skipSpace(text, k + 1);
		final quote = text.charAt(k);
		if (quote != '"' && quote != "'") {
			return k;
		}
		final end = text.indexOf(quote, k + 1);
		return end < 0 ? text.length : end + 1;
	}

	static function skipName(text:String, i:Int):Int {
		while (i < text.length && isNameChar(text.charCodeAt(i))) {
			i++;
		}
		return i;
	}

	static function skipSpace(text:String, i:Int):Int {
		while (i < text.length && StringTools.isSpace(text, i)) {
			i++;
		}
		return i;
	}

	static function isNameChar(c:Int):Bool {
		return (c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "-".code
			|| c == "_".code || c == ".".code || c == ":".code;
	}
}
