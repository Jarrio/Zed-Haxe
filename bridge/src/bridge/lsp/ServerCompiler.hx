package bridge.lsp;

import bridge.markup.MarkupProvider;
import haxe.io.Path;
import js.lib.Promise;

/**
	Asks the Haxe compiler things through the language server's `haxe/runMethod` passthrough,
	using the server's compilation cache and display arguments.

	Questions about code that doesn't exist on disk ("what fields does `Button` have?") are asked with
	"probes": an existing module's text with a few lines added, sent as unsaved `contents`. Each probe
	invalidates the module before and after, as the server does when a file is edited, so the compiler's
	cache never keeps the probe. Probes run one at a time.
**/
class ServerCompiler implements Compiler {
	final bridge:Router;
	final readFile:String->Null<String>;

	/** Folder relative class paths are relative to: the last `--cwd` of the display arguments, or the workspace. **/
	final cwd:() -> String;

	var paths:Null<Promise<Array<String>>>;
	var queue:Promise<Dynamic> = Promise.resolve(null);

	public function new(bridge:Router, readFile:String->Null<String>, cwd:() -> String) {
		this.bridge = bridge;
		this.readFile = readFile;
		this.cwd = cwd;
	}

	/** Forget the class paths, e.g. after the display arguments changed. **/
	public function invalidate() {
		paths = null;
	}

	public function classPaths():Promise<Array<String>> {
		if (paths == null) {
			paths = bridge.requestServer("haxe/runMethod", {method: "server/contexts", params: {}}).then(function(contexts:Null<Array<Dynamic>>) {
				// The target's context has the most class paths; macro contexts can have fewer.
				var best:Array<String> = [];
				for (context in contexts ?? []) {
					final listed:Null<Array<String>> = context.classPaths;
					final classPaths = listed ?? [];
					if (context.platform != "eval" && classPaths.length > best.length || best.length == 0) {
						best = classPaths;
					}
				}
				final std = ~/[\/\\]std([\/\\]|$)/;
				final result = [];
				for (classPath in best) {
					if (classPath == "" || std.match(classPath)) {
						continue;
					}
					final absolute = Path.removeTrailingSlashes(Path.isAbsolute(classPath) ? classPath : Path.join([cwd(), classPath]));
					if (!result.contains(absolute)) {
						result.push(absolute);
					}
				}
				return result;
			}, _ -> []);
		}
		return paths;
	}

	public function fields(typePath:String, host:HostClass):Promise<Array<Dynamic>> {
		final text = readFile(host.file);
		if (text == null) {
			return Promise.resolve([]);
		}
		final code = 'var haxeZedValue:$typePath = null; haxeZedValue.';
		final probe = text + '\nprivate class HaxeZedProbe { static function haxeZedProbe() { $code } }\n';
		return display("display/completion", host.file, probe, probe.lastIndexOf(code) + code.length).then(function(result:Dynamic) {
			final items:Array<Dynamic> = result?.items ?? [];
			return items;
		});
	}

	/**
		Runs a display method (`display/completion`, `display/hover`, ...) on `contents` as the text of `file`,
		at `offset` (a JavaScript string index). Resolves with null when the compiler reports an error.
	**/
	public function display(method:String, file:String, contents:String, offset:Int):Promise<Dynamic> {
		return serial(function() {
			return invalidateFile(file).then(function(_) {
				return bridge.requestServer("haxe/runMethod", {
					method: method,
					params: {
						file: file,
						contents: contents,
						offset: codePoints(contents, offset),
						wasAutoTriggered: false
					}
				});
			}).then(function(result) {
				return invalidateFile(file).then(_ -> result);
			}, function(error) {
				Log.info('$method probe failed: ${haxe.Json.stringify(error)}');
				return invalidateFile(file).then(_ -> null);
			});
		});
	}

	function invalidateFile(file:String):Promise<Dynamic> {
		return bridge.requestServer("haxe/runMethod", {method: "server/invalidate", params: {file: file}}).then(null, _ -> null);
	}

	function serial(task:() -> Promise<Dynamic>):Promise<Dynamic> {
		final result = queue.then(_ -> task(), _ -> task());
		queue = result.then(_ -> null, _ -> null);
		return result;
	}

	/** Haxe counts offsets in Unicode code points; JavaScript strings index UTF-16 units. **/
	public static function codePoints(text:String, offset:Int):Int {
		var count = offset;
		for (i in 0...Std.int(Math.min(offset, text.length))) {
			final unit = text.charCodeAt(i);
			if (unit >= 0xDC00 && unit <= 0xDFFF) {
				count--;
			}
		}
		return count;
	}
}
