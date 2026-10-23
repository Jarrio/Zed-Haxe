package bridge.util;

import js.node.Url;
import js.node.url.URL;

class Uris {
	/** The file path of a `file:` URI, or null for anything else. **/
	public static function toPath(uri:String):Null<String> {
		return try Url.fileURLToPath(new URL(uri)) catch (_) null;
	}

	public static function fromPath(path:String):String {
		return Url.pathToFileURL(path).href;
	}
}
