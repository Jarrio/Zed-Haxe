package bridge.util;

import js.Node.process;
import js.node.Url;
import js.node.url.URL;

class Uris {
	static final isWindows = process.platform == "win32";
	static final windowsDrive = ~/^file:\/\/\/([A-Za-z])(:|%3[Aa])\//;

	/** The file path of a `file:` URI, or null for anything else. **/
	public static function toPath(uri:String):Null<String> {
		return try Url.fileURLToPath(new URL(uri)) catch (_) null;
	}

	public static function fromPath(path:String):String {
		return Url.pathToFileURL(path).href;
	}

	/**
		Whether two `file:` URIs name the same file. On Windows haxe-language-server spells them like VS Code
		(`file:///d%3A/game/Main.hx`) where Zed sends `file:///D:/game/Main.hx`, and paths ignore case.
	**/
	public static function sameFile(a:String, b:String, ?windows:Bool):Bool {
		return a == b || ((windows ?? isWindows) && windowsKey(a) == windowsKey(b));
	}

	/** A Windows `file:` URI reduced so that every spelling of the same file gives the same key. **/
	public static function windowsKey(uri:String):String {
		final spelled = withDrive(uri);
		return (try js.Syntax.code("decodeURIComponent({0})", spelled) catch (_) spelled).toLowerCase();
	}

	/** `uri` with its Windows drive spelled as Zed does: `file:///D:/`. **/
	public static function withDrive(uri:String):String {
		return windowsDrive.match(uri) ? 'file:///${windowsDrive.matched(1).toUpperCase()}:/${windowsDrive.matchedRight()}' : uri;
	}
}
