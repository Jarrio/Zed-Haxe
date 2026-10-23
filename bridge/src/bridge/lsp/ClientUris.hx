package bridge.lsp;

import bridge.util.Uris;

/**
	Gives Zed back its own spelling of file URIs. On Windows haxe-language-server writes them like VS Code
	(`file:///d%3A/game/Main.hx`) where Zed sent `file:///D:/game/Main.hx`, and Zed compares URIs as text,
	so diagnostics and locations for an open file would miss it. Does nothing on other systems.
**/
class ClientUris {
	final enabled:Bool;

	/** Zed's spelling of each file URI it sent, by `Uris.windowsKey`. **/
	final spellings = new Map<String, String>();

	public function new(enabled:Bool) {
		this.enabled = enabled;
	}

	/** Remembers the file URIs in a message from Zed. **/
	public function learn(message:Dynamic) {
		if (enabled) {
			visit(message, function(uri) {
				spellings.set(Uris.windowsKey(uri), uri);
				return uri;
			});
		}
	}

	/** Respells the file URIs in a message for Zed, in place: as Zed spelled them, else with Zed's drive spelling. **/
	public function respell(message:Dynamic) {
		if (enabled) {
			visit(message, uri -> spellings.get(Uris.windowsKey(uri)) ?? Uris.withDrive(uri));
		}
	}

	/** Replaces each `file:` URI in `value`, object keys included (`WorkspaceEdit.changes` is keyed by URI). **/
	static function visit(value:Dynamic, replace:String->String):Dynamic {
		if (Std.isOfType(value, String)) {
			return isFileUri(value) ? replace(value) : value;
		}
		if (Std.isOfType(value, Array)) {
			final array:Array<Dynamic> = value;
			for (i in 0...array.length) {
				array[i] = visit(array[i], replace);
			}
		} else if (value != null && Reflect.isObject(value)) {
			for (field in Reflect.fields(value)) {
				final replaced = visit(Reflect.field(value, field), replace);
				final name = isFileUri(field) ? replace(field) : field;
				if (name != field) {
					Reflect.deleteField(value, field);
				}
				Reflect.setField(value, name, replaced);
			}
		}
		return value;
	}

	/** A whole URI, not text that starts with one: URIs have no raw spaces or line breaks. **/
	static function isFileUri(text:String):Bool {
		return StringTools.startsWith(text, "file:") && !~/\s/.match(text);
	}
}
