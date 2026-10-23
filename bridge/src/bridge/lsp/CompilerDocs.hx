package bridge.lsp;

import bridge.rpc.Message;
import js.lib.Promise;

typedef DefineDoc = {
	var name:String;
	var doc:String;
	var ?parameters:Array<String>;
	var ?platforms:Array<String>;
	var ?links:Array<String>;
	var ?origin:Dynamic;
	var ?deprecated:Dynamic;
}

typedef MetadataDoc = {
	var name:String;
	var doc:String;
	var ?parameters:Array<String>;
	var ?platforms:Array<String>;
	var ?targets:Array<String>;
	var ?links:Array<String>;
	var ?origin:Dynamic;
	var ?internal:Bool;
}

/** What sits under the cursor, as far as define and metadata docs are concerned. **/
enum DocContext {
	/** A define name inside `#if` / `#elseif`. **/
	Define(name:String);

	/** A metadata name after `@:` (stored without the colon). **/
	Metadata(name:String);
}

/**
	Hover and completion for defines (`#if FLX_NO_MOUSE`) and metadata (`@:bitmap`), using the compiler's
	`display/defines` and `display/metadata` (Haxe 4.3.4+). These include library documentation
	registered through haxelib.json, `Compiler.register*DescriptionFile`, or the bridge's doc packs.
	The server doesn't offer these itself, so the bridge adds them to its answers.
**/
class CompilerDocs {
	static final conditionLine = ~/^\s*#(if|elseif)\b/;
	static final wordChar = ~/[A-Za-z0-9_\-]/;

	/** Defined by the compiler for the matching target; not part of `display/defines`. **/
	static final platformDefines = [
		"cpp", "cs", "eval", "flash", "hl", "interp", "java", "js", "jvm", "lua", "macro", "neko", "php", "python", "sys", "display", "debug"
	];

	final bridge:Router;

	/** Current display arguments, for the defines the project sets with `-D`. **/
	final currentArgs:() -> Array<String>;
	var defines:Null<Promise<Array<DefineDoc>>>;
	var metadata:Null<Promise<Array<MetadataDoc>>>;

	public function new(bridge:Router, currentArgs:() -> Array<String>) {
		this.bridge = bridge;
		this.currentArgs = currentArgs;
	}

	/** Forget cached docs, e.g. after the display arguments changed. **/
	public function invalidate() {
		defines = null;
		metadata = null;
	}

	/** The define or metadata name touching `character`, if the line puts it in such a context. **/
	public static function contextAt(line:String, character:Int):Null<DocContext> {
		var start = character;
		while (start > 0 && wordChar.match(line.charAt(start - 1))) {
			start--;
		}
		var end = character;
		while (end < line.length && wordChar.match(line.charAt(end))) {
			end++;
		}
		final word = line.substring(start, end);
		if (start >= 2 && line.substr(start - 2, 2) == "@:") {
			return Metadata(word);
		}
		if (conditionLine.match(line) && start > line.indexOf("#") + 1 + conditionLine.matched(1).length) {
			return Define(word);
		}
		return null;
	}

	/**
		Adds the docs of the define or metadata under the cursor to the server's hover answer.
		When the server answered, it already shows the compiler's own doc, so only library docs are added.
		Library docs come first either way: e.g. OpenFL's `@:bitmap` before the compiler's Flash-only one.
	**/
	public function hover(response:Message, context:DocContext):Promise<Message> {
		final existing:Null<String> = response.error == null ? response.result?.contents?.value : null;
		final serverAnswered = existing != null && existing != "";
		function keep(origin:Dynamic) {
			return !serverAnswered || !isCompiler(origin);
		}
		final found:Promise<Array<String>> = switch context {
			case Define(name): getDefines().then(all -> {
					final matches = all.filter(d -> sameDefine(d.name, name) && keep(d.origin));
					matches.sort((a, b) -> rank(a.origin) - rank(b.origin));
					matches.map(describeDefine);
				});
			case Metadata(name): getMetadata().then(all -> {
					final matches = all.filter(m -> (m.name == ':$name' || m.name == name) && keep(m.origin));
					matches.sort((a, b) -> rank(a.origin) - rank(b.origin));
					matches.map(describeMetadata);
				});
		}
		return found.then(function(sections):Message {
			if (sections.length == 0) {
				return response;
			}
			final markdown = sections.join("\n\n---\n");
			final value = serverAnswered ? '$existing\n\n---\n$markdown' : markdown;
			return {id: response.id, result: {contents: {kind: "markdown", value: value}}};
		});
	}

	/**
		Replaces the server's completion inside `#if` and after `@:`, where it only offers keywords,
		with the known defines or metadata.
	**/
	public function completion(response:Message, context:DocContext):Promise<Message> {
		final items:Promise<Array<Dynamic>> = switch context {
			case Define(_): getDefines().then(defineItems);
			case Metadata(_): getMetadata().then(all -> [for (doc in all) if (doc.internal != true) metadataItem(doc)]);
		}
		return items.then(function(items):Message {
			return {id: response.id, result: {isIncomplete: false, items: items}};
		});
	}

	/** Documented defines, then the ones the project sets with `-D`, then platform names. **/
	function defineItems(documented:Array<DefineDoc>):Array<Dynamic> {
		final items:Array<Dynamic> = [];
		final seen = new Map<String, Bool>();
		for (doc in documented) {
			final item = defineItem(doc);
			if (!seen.exists(item.label)) {
				seen.set(item.label, true);
				items.push(item);
			}
		}
		final args = currentArgs();
		for (i in 0...args.length - 1) {
			if (args[i] != "-D" && args[i] != "--define") {
				continue;
			}
			final parts = args[i + 1].split("=");
			final name = StringTools.replace(parts[0], "-", "_");
			if (!seen.exists(name)) {
				seen.set(name, true);
				items.push({
					label: name,
					kind: 21,
					detail: parts.length > 1 ? 'set by the project to ${parts.slice(1).join("=")}' : "set by the project",
					data: {haxeZed: true}
				});
			}
		}
		for (name in platformDefines) {
			if (!seen.exists(name)) {
				seen.set(name, true);
				items.push({label: name, kind: 21, detail: "target", data: {haxeZed: true}});
			}
		}
		return items;
	}

	/** Sort key putting library docs before the compiler's own. **/
	static function rank(from:Dynamic):Int {
		return isCompiler(from) ? 1 : 0;
	}

	/** The compiler's own entries have no origin or `"haxe compiler"`; library entries name the library. **/
	static function isCompiler(from:Dynamic):Bool {
		return origin(from) == null;
	}

	function getDefines():Promise<Array<DefineDoc>> {
		if (defines == null) {
			defines = fetch("display/defines");
		}
		return defines;
	}

	function getMetadata():Promise<Array<MetadataDoc>> {
		if (metadata == null) {
			metadata = fetch("display/metadata");
		}
		return metadata;
	}

	function fetch<T>(method:String):Promise<Array<T>> {
		return bridge.requestServer("haxe/runMethod", {method: method, params: {compiler: true, user: true}}).then(function(result:Null<Array<T>>) {
			return result ?? [];
		}, function(error) {
			Log.info('$method failed: ${haxe.Json.stringify(error)}');
			return [];
		});
	}

	/** In `#if`, `no-compilation` is written `no_compilation`. **/
	static function sameDefine(a:String, b:String):Bool {
		return StringTools.replace(a, "-", "_") == StringTools.replace(b, "-", "_");
	}

	static function metadataName(name:String):String {
		return StringTools.startsWith(name, ":") ? name.substr(1) : name;
	}

	static function defineItem(doc:DefineDoc):Dynamic {
		final name = StringTools.replace(doc.name, "-", "_");
		return {
			label: name,
			kind: 21, // Constant
			detail: origin(doc.origin) ?? "compiler define",
			documentation: {kind: "markdown", value: describeDefine(doc)},
			data: {haxeZed: true}
		};
	}

	static function metadataItem(doc:MetadataDoc):Dynamic {
		final name = metadataName(doc.name);
		return {
			label: name,
			kind: 14, // Keyword
			detail: '@:$name' + (origin(doc.origin) == null ? "" : ' (${origin(doc.origin)})'),
			documentation: {kind: "markdown", value: describeMetadata(doc)},
			data: {haxeZed: true}
		};
	}

	static function describeDefine(doc:DefineDoc):String {
		final name = StringTools.replace(doc.name, "-", "_");
		return '**`$name`**' + (doc.parameters != null && doc.parameters.length > 0 ? ' `=${doc.parameters.join(", ")}`' : "") + '\n\n${doc.doc}'
			+ details(doc.platforms, doc.links, doc.origin);
	}

	static function describeMetadata(doc:MetadataDoc):String {
		final params = doc.parameters != null && doc.parameters.length > 0 ? '(${doc.parameters.join(", ")})' : "";
		return '**`@${doc.name}$params`**\n\n${doc.doc}' + details(doc.platforms, doc.links, doc.origin);
	}

	static function details(platforms:Null<Array<String>>, links:Null<Array<String>>, from:Dynamic):String {
		var text = "";
		if (platforms != null && platforms.length > 0) {
			text += '\n\nPlatforms: ${platforms.join(", ")}';
		}
		for (link in links ?? []) {
			text += '\n\n<$link>';
		}
		final source = origin(from);
		if (source != null) {
			text += '\n\n*from $source*';
		}
		return text;
	}

	/** The library a doc comes from, or null for the compiler's own docs. **/
	static function origin(value:Dynamic):Null<String> {
		return Std.isOfType(value, String) && value != "" && value != "haxe compiler" ? value : null;
	}
}
