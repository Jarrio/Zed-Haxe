package bridge.lsp;

import bridge.util.Uris;

/**
	Keeps the compilation server's cache in step with Haxe files changed outside the one being edited.

	haxe-language-server turns the compiler's own file checks off (`noModuleChecks`) and reports edits
	instead, but only the first edit of a document since it was last saved, and nothing for `.hx` files
	changed on disk (git, code generators, other editors). The compiler then keeps using old versions:
	on Haxe 5 a file changed on disk stays stale even after `server/invalidate`, and completion in a
	document edited before another file was saved can come back empty.

	So when a Haxe file is saved or changes on disk, file checks are turned back on (they cost nothing
	measurable on a 400-module project) and the other open Haxe documents are invalidated, so the next
	request in them is typed against the new versions. Both are sent before any later request, and a
	server restart starts from an empty cache, so there is no race with the server's own `server/configure`.
**/
class ServerCache {
	final bridge:Router;
	final documents:Documents;

	public function new(bridge:Router, documents:Documents) {
		this.bridge = bridge;
		this.documents = documents;
	}

	/** `paths` were saved or changed on disk. **/
	public function filesChanged(paths:Array<String>) {
		final changed = paths.filter(isHaxeFile);
		if (changed.length == 0) {
			return;
		}
		runMethod("server/configure", {noModuleChecks: false});
		for (uri in documents.uris()) {
			final path = Uris.toPath(uri);
			if (path != null && isHaxeFile(path) && !changed.contains(path)) {
				runMethod("server/invalidate", {file: path});
			}
		}
	}

	function runMethod(method:String, params:Dynamic) {
		bridge.requestServer("haxe/runMethod", {method: method, params: params}).then(null, _ -> null);
	}

	static function isHaxeFile(path:String):Bool {
		return StringTools.endsWith(path, ".hx");
	}
}
