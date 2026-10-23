package bridge.lsp;

import bridge.util.Uris;

/**
	Keeps the compilation server's cache in step with what is open in Zed.

	haxe-language-server turns the compiler's own file checks off (`noModuleChecks`) and reports edits
	instead, but only the first edit of a document since that document was saved, and nothing for `.hx`
	files changed on disk (git, code generators, other editors). Two things then go wrong, on Haxe 4 and 5:

	- A file changed on disk stays stale. So when a Haxe file is saved or changes on disk, file checks
	  are turned back on; they cost nothing measurable on a 400-module project. A server restart starts
	  from an empty cache, so there is no race with the server's own `server/configure`.
	- When a file is saved or opened, the server checks every open file again, reading them from disk,
	  and it rebuilds its completion cache from disk when Haxe (re)starts or the display arguments
	  change. The compiler then keeps that version of a document with unsaved edits and answers
	  completion for text that isn't there (often nothing at all). So after any of these, each open
	  document is invalidated before Zed next edits it or asks about it, so the compiler reads it afresh.
**/
class ServerCache {
	final bridge:Router;
	final documents:Documents;

	/** Open documents the compiler may have read from disk since it last saw them as Zed has them. **/
	final stale = new Map<String, Bool>();

	public function new(bridge:Router, documents:Documents) {
		this.bridge = bridge;
		this.documents = documents;
	}

	/** `paths` were saved or changed on disk. **/
	public function filesChanged(paths:Array<String>) {
		if (paths.filter(isHaxeFile).length == 0) {
			return;
		}
		runMethod("server/configure", {noModuleChecks: false});
		markOpenDocuments();
	}

	/** A document was opened, so the server checks the open files from disk. **/
	public function documentOpened() {
		markOpenDocuments();
	}

	/** The server started building its completion cache, which compiles the project from disk. **/
	public function cacheRebuilding() {
		markOpenDocuments();
	}

	/** Before Zed's edit of, or request about, `uri` reaches the server. **/
	public function beforeUse(uri:String) {
		if (stale.remove(uri)) {
			final path = Uris.toPath(uri);
			if (path != null) {
				runMethod("server/invalidate", {file: path});
			}
		}
	}

	function markOpenDocuments() {
		for (uri in documents.uris()) {
			final path = Uris.toPath(uri);
			if (path != null && isHaxeFile(path)) {
				stale.set(uri, true);
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
