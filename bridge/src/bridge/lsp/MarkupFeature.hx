package bridge.lsp;

import bridge.lsp.Documents.Position;
import bridge.lsp.Ranking.PrivateMembers;
import bridge.markup.HaxeUiProvider;
import bridge.markup.MarkupProvider;
import bridge.markup.XmlCursor;
import bridge.project.Hxml;
import bridge.util.Files;
import bridge.rpc.Message;
import haxe.Json;
import haxe.io.Path;
import js.lib.Promise;
import sys.FileSystem;
import sys.io.File;

/** A request position resolved to a piece of markup. **/
private typedef Located = {
	final provider:MarkupProvider;
	final uri:String;
	final text:String;
	final offset:Int;
	final region:Region;

	/** The class the markup is compiled into, if known. **/
	final host:Null<HostClass>;
}

/**
	Completion, hover, go to definition and signature help inside UI markup: XML embedded in Haxe files
	(HaxeUI's `@:xml`) and standalone `.xml` layouts. The rules for each framework come from a
	`MarkupProvider`; Haxe code inside attribute values is completed by the compiler, in the class the
	markup is compiled into.
**/
class MarkupFeature {
	/** Frameworks with markup support. Add a provider here to support another one. **/
	static function createProviders():Array<MarkupProvider> {
		return [new HaxeUiProvider()];
	}

	final bridge:Router;
	final documents:Documents;
	final displayArgs:() -> Array<String>;
	final workspaceRoot:() -> String;
	final compiler:ServerCompiler;
	final privateMembers:() -> PrivateMembers;
	var providers:Array<MarkupProvider>;
	var expandedFor:Null<String>;
	var expanded:Array<String> = [];
	var host:Null<HostClass>;
	final docCache = new Map<String, Promise<Null<{doc:Null<String>, style:Bool}>>>();

	/** Whether the client inserts snippets (`$1`) in completion items. **/
	public var snippets = false;

	public function new(bridge:Router, documents:Documents, displayArgs:() -> Array<String>, workspaceRoot:() -> String,
			privateMembers:() -> PrivateMembers) {
		this.bridge = bridge;
		this.documents = documents;
		this.displayArgs = displayArgs;
		this.workspaceRoot = workspaceRoot;
		this.privateMembers = privateMembers;
		compiler = new ServerCompiler(bridge, readFile, compilerCwd);
		providers = createProviders();
	}

	/** Forget everything learned, e.g. after the display arguments changed. **/
	public function reset() {
		providers = createProviders();
		compiler.invalidate();
		expandedFor = null;
		host = null;
		docCache.clear();
	}

	/** A file was saved or changed outside the editor. **/
	public function fileChanged(path:String) {
		for (provider in providers) {
			provider.invalidate(path);
		}
		host = null;
		if (StringTools.endsWith(path, ".hx")) {
			docCache.clear();
		}
	}

	/** Whether a request in a Haxe file is inside markup. Answers it and returns true if so. **/
	public function handleHaxe(message:Message):Bool {
		final uri:String = message.params.textDocument.uri;
		final text = documents.text(uri);
		final path = Rewrites.uriToPath(uri);
		if (text == null || path == null || text.indexOf("@:") < 0) {
			return false;
		}
		final offset = Documents.offsetAt(text, message.params.position);
		for (provider in activeProviders()) {
			final region = provider.regionInHaxe(text, offset);
			if (region != null) {
				answer(message, {
					provider: provider,
					uri: uri,
					text: text,
					offset: offset,
					region: region,
					host: provider.hostInHaxe(path, text, region)
				});
				return true;
			}
		}
		return false;
	}

	/** Answers a request in a standalone markup file (`.xml`); empty when no framework claims the file. **/
	public function handleFile(message:Message) {
		final uri:String = message.params.textDocument.uri;
		final text = documents.text(uri);
		final path = Rewrites.uriToPath(uri);
		if (text == null || path == null) {
			bridge.replyToClient(message.id, null);
			return;
		}
		final offset = Documents.offsetAt(text, message.params.position);
		final project = this.project();
		claimant(activeProviders(), project, path, text).then(function(provider:Null<MarkupProvider>) {
			if (provider == null) {
				bridge.replyToClient(message.id, null);
			} else {
				answerInFile(message, provider, project, path, uri, text, offset);
			}
		}, function(error) {
			Log.info('markup: ${Std.string(error)}');
			bridge.replyToClient(message.id, null);
		});
	}

	function answerInFile(message:Message, provider:MarkupProvider, project:MarkupProject, path:String, uri:String, text:String, offset:Int) {
		provider.hostOfFile(project, path).then(function(host) {
			answer(message, {
				provider: provider,
				uri: uri,
				text: text,
				offset: offset,
				region: {start: 0, end: text.length},
				host: host
			});
		});
	}

	function claimant(candidates:Array<MarkupProvider>, project:MarkupProject, path:String, text:String):Promise<Null<MarkupProvider>> {
		if (candidates.length == 0) {
			return Promise.resolve(null);
		}
		return candidates[0].claimsFile(project, path, text).then(claimed -> claimed ? Promise.resolve(candidates[0]) : claimant(candidates.slice(1), project, path, text));
	}

	function answer(message:Message, at:Located) {
		final result:Promise<Dynamic> = switch message.method {
			case "textDocument/completion": completion(at);
			case "textDocument/hover": hover(at);
			case "textDocument/definition": definition(at);
			case "textDocument/signatureHelp": signatureHelp(at);
			case _: Promise.resolve(null);
		}
		result.then(value -> bridge.replyToClient(message.id, value), function(error) {
			Log.info('markup ${message.method} failed: ${Std.string(error)}');
			bridge.replyToClient(message.id, null);
		});
	}

	function completion(at:Located):Promise<Dynamic> {
		final markup = at.text.substring(at.region.start, at.region.end);
		final project = this.project();
		final list = (items:Array<Dynamic>) -> ({isIncomplete: false, items: items} : Dynamic);
		return switch XmlCursor.at(markup, at.offset - at.region.start) {
			case TagName(_, start, _, _):
				final range = rangeOf(at, at.region.start + start, at.offset);
				at.provider.tags(project, markup).then(tags -> list([
					for (tag in tags)
						{
							label: tag.name,
							kind: 7,
							detail: tag.typePath,
							filterText: tag.filterText ?? tag.name,
							textEdit: {range: range, newText: tag.name},
							data: {haxeZed: true}
						}
				]));
			case CloseTagName(_, start, _, open):
				final range = rangeOf(at, at.region.start + start, at.offset);
				Promise.resolve(list(open == null ? [] : [{label: open, kind: 7, textEdit: {range: range, newText: open}, data: {haxeZed: true}}]));
			case AttributeName(tagName, _, start, _, present):
				final range = rangeOf(at, at.region.start + start, at.offset);
				final followedByValue = at.text.charAt(at.offset) == "=";
				tagOf(at, project, tagName, markup).then(tag -> tag == null ? Promise.resolve([]) : at.provider.attributes(project, tag).then(attributes -> [
					for (attribute in attributes)
						if (!present.contains(attribute.name)) {
							final insert = followedByValue ? attribute.name : snippets ? attribute.name + '="$$1"' : attribute.name;
							final item:Dynamic = {
								label: attribute.name,
								// The compiler's order (the component's own properties first), then events.
								sortText: (attribute.code == true ? "1" : "0") + StringTools.lpad(Std.string(attributes.indexOf(attribute)), "0", 4),
								kind: attribute.code == true ? 23 : 10, // Event, Property
								textEdit: {range: range, newText: insert},
								// Docs are looked up when Zed resolves the highlighted item, not for the whole list.
								data: attribute.code == true ? {haxeZed: true} : {haxeZed: true, typePath: tag.typePath, field: attribute.field ?? attribute.name}
							};
							if (snippets && !followedByValue) {
								item.insertTextFormat = 2;
							}
							if (attribute.type != null) {
								item.detail = attribute.type;
							}
							if (attribute.doc != null && attribute.doc != "") {
								item.documentation = {kind: "markdown", value: attribute.doc};
							}
							item;
						}
				])).then(list);
			case AttributeValue(tagName, attributeName, value, valueStart):
				final valueOffset = at.offset - at.region.start - valueStart;
				codeAt(at, project, tagName, attributeName, value, valueOffset, markup).then(function(code:Null<Probe>) {
					if (code != null) {
						return compiler.display("display/completion", code.file, code.text, code.offset).then(function(result:Dynamic) {
							final range = rangeOf(at, wordStart(at.text, at.offset), at.offset);
							final items:Array<Dynamic> = result?.items ?? [];
							// After `id.` (mode Field), a component's private and `_` members are its internals.
							final fieldAccess = result?.mode?.kind == 0;
							// A component id is both a local of the probe and, with @:xml / build macros, a field of the class.
							final seen = new Map<String, Bool>();
							final converted = [];
							final groups = [];
							for (item in items) {
								final lsp = HaxeItems.completionItem(item, range);
								if (lsp != null && !seen.exists(lsp.label)) {
									seen.set(lsp.label, true);
									converted.push(lsp);
									groups.push(Ranking.ofDisplayItem(item, fieldAccess));
								}
							}
							// The compiler stops at a limit (1000 items); when it did, Zed must ask again as you type.
							return ({isIncomplete: result?.isIncomplete == true, items: Ranking.apply(converted, groups, privateMembers())} : Dynamic);
						});
					}
					return attributesOf(at, project, tagName, markup).then(function(attributes) {
						final attribute = Lambda.find(attributes, a -> a.name == attributeName);
						final range = rangeOf(at, at.region.start + valueStart, at.region.start + valueStart + value.length);
						return list([
							for (value in attribute?.values ?? [])
								{label: value, kind: 12, textEdit: {range: range, newText: value}, data: {haxeZed: true}}
						]);
					});
				});
			case Other:
				Promise.resolve(list([]));
		}
	}

	function hover(at:Located):Promise<Dynamic> {
		final markup = at.text.substring(at.region.start, at.region.end);
		final project = this.project();
		return switch XmlCursor.at(markup, at.offset - at.region.start) {
			case TagName(name, _, _, _) | CloseTagName(name, _, _, _):
				tagOf(at, project, name, markup).then(function(tag:Null<TagInfo>) {
					if (tag == null) {
						return null;
					}
					return typeProbe(tag.typePath, "display/hover").then(function(result:Dynamic) {
						final doc = cleanDoc(result?.documentation);
						var value = '```haxe\n${tag.typePath}\n```';
						if (doc != null && StringTools.trim(doc) != "") {
							value += "\n\n" + StringTools.trim(doc);
						}
						return {contents: {kind: "markdown", value: value}};
					});
				});
			case AttributeName(tagName, name, _, _, _):
				tagOf(at, project, tagName, markup).then(function(tag:Null<TagInfo>) {
					if (tag == null) {
						return Promise.resolve(null);
					}
					return at.provider.attributes(project, tag).then(function(attributes) {
						final attribute = Lambda.find(attributes, a -> a.name == name);
						if (attribute == null) {
							return Promise.resolve(null);
						}
						final heading = '```haxe\n${attribute.name}' + (attribute.type == null ? "" : ':${attribute.type}') + "\n```";
						if (attribute.code == true) {
							return Promise.resolve(markdown(heading, attribute.doc));
						}
						return fieldDoc(tag.typePath, attribute.field ?? attribute.name).then(found -> markdown(heading, found?.doc ?? attribute.doc,
							found?.style == true ? "Also a style property, so it can be set from CSS." : null));
					});
				});
			case AttributeValue(tagName, attributeName, value, valueStart):
				final valueOffset = at.offset - at.region.start - valueStart;
				codeAt(at, project, tagName, attributeName, value, valueOffset, markup, true).then(function(code:Null<Probe>) {
					return code == null ? null : compiler.display("display/hover", code.file, code.text, code.offset).then(HaxeItems.hover);
				});
			case Other:
				Promise.resolve(null);
		}
	}

	function definition(at:Located):Promise<Dynamic> {
		final markup = at.text.substring(at.region.start, at.region.end);
		final project = this.project();
		return switch XmlCursor.at(markup, at.offset - at.region.start) {
			case TagName(name, _, _, _) | CloseTagName(name, _, _, _):
				tagOf(at, project, name, markup).then(tag -> tag == null ? null : typeProbe(tag.typePath, "display/definition").then(HaxeItems.locations));
			case AttributeName(tagName, name, _, _, _):
				tagOf(at, project, tagName, markup).then(function(tag:Null<TagInfo>) {
					if (tag == null) {
						return null;
					}
					return attributesOf(at, project, tagName, markup).then(function(attributes) {
						final attribute = Lambda.find(attributes, a -> a.name == name);
						return attribute == null || attribute.code == true ? null : fieldProbe(tag.typePath, attribute.field ?? attribute.name)
							.then(HaxeItems.locations);
					});
				});
			case AttributeValue(tagName, attributeName, value, valueStart):
				final valueOffset = at.offset - at.region.start - valueStart;
				codeAt(at, project, tagName, attributeName, value, valueOffset, markup, true).then(function(code:Null<Probe>) {
					return code == null ? null : compiler.display("display/definition", code.file, code.text, code.offset)
						.then(result -> realLocations(code, HaxeItems.locations(result)));
				});
			case Other:
				Promise.resolve(null);
		}
	}

	function signatureHelp(at:Located):Promise<Dynamic> {
		final markup = at.text.substring(at.region.start, at.region.end);
		return switch XmlCursor.at(markup, at.offset - at.region.start) {
			case AttributeValue(tagName, attributeName, value, valueStart):
				final valueOffset = at.offset - at.region.start - valueStart;
				codeAt(at, project(), tagName, attributeName, value, valueOffset, markup).then(function(code:Null<Probe>) {
					return code == null ? null : compiler.display("display/signatureHelp", code.file, code.text, code.offset).then(HaxeItems.signatureHelp);
				});
			case _:
				Promise.resolve(null);
		}
	}

	/**
		A probe for Haxe code in an attribute value: a method added to the class the markup is compiled into,
		declaring what the code can see, then the code itself.
		@param whole include the code after the cursor too (for hover and definition)
	**/
	function codeAt(at:Located, project:MarkupProject, tagName:String, attributeName:String, value:String, valueOffset:Int, markup:String,
			whole = false):Promise<Null<Probe>> {
		return tagOf(at, project, tagName, markup).then(function(tag:Null<TagInfo>) {
			if (tag == null) {
				return null;
			}
			return at.provider.codeContext(project, tag, attributeName, markup, at.host).then(function(context:Null<CodeContext>):Null<Probe> {
				if (context == null) {
					return null;
				}
				final host = context.host ?? project.defaultHost();
				final hostText = host == null ? null : readFile(host.file);
				if (host == null || hostText == null) {
					return null;
				}
				var before = value.substr(0, valueOffset);
				var after = whole ? value.substr(valueOffset) : "";
				if (context.thisAlias != null) {
					before = ~/\bthis\b/g.replace(before, context.thisAlias);
					after = ~/\bthis\b/g.replace(after, context.thisAlias);
				}
				var declarations = "";
				if (context.thisType != null) {
					declarations += 'var ${context.thisAlias ?? "haxeZedThis"}:${context.thisType} = null; ';
				}
				for (name => type in context.locals) {
					declarations += 'var $name:$type = null; ';
				}
				final method = '\n\tfunction haxeZedProbe() { $declarations{ $before';
				final rest = '$after; } }\n';
				final edits:Array<TextEdit> = [];
				if (Rewrites.uriToPath(at.uri) == host.file && !parses(markup)) {
					// HaxeUI's build macro parses @:xml, so while a tag is half typed the class doesn't compile and the
					// probe finds nothing. The ids are locals of the probe already, so its root element is enough.
					edits.push({at: at.region.start, removed: at.region.end - at.region.start, text: rootOnly(markup)});
				}
				return insertIntoClass(host, hostText, method, rest, edits);
			});
		});
	}

	static function parses(markup:String):Bool {
		return try {
			Xml.parse(markup);
			true;
		} catch (_) false;
	}

	/** `<vbox width="100%">...` -> `<vbox />`. **/
	static function rootOnly(markup:String):String {
		final root = XmlCursor.elements(markup)[0]?.name ?? "box";
		return '<$root />';
	}

	/** Puts `head + tail` at the start of `host`'s class body, after `edits`; the probe offset is between the two. **/
	static function insertIntoClass(host:HostClass, text:String, head:String, tail:String, edits:Array<TextEdit>):Probe {
		final declaration = new EReg('\\bclass\\s+${host.className}\\b[^{]*\\{', "");
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
		return {file: host.file, text: applyEdits(text, all), offset: at + shift + opening.length, original: text, edits: all};
	}

	static function applyEdits(text:String, edits:Array<TextEdit>):String {
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

	/** Where an offset in the probe's text is in the real file; inside inserted text, the start of the edit. **/
	static function toOriginal(edits:Array<TextEdit>, offset:Int):Int {
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
	static function realLocations(code:Probe, locations:Array<Dynamic>):Array<Dynamic> {
		final uri = Rewrites.pathToUri(code.file);
		for (location in locations) {
			if (location.uri == uri) {
				final start = toOriginal(code.edits, Documents.offsetAt(code.text, location.range.start));
				final end = toOriginal(code.edits, Documents.offsetAt(code.text, location.range.end));
				location.range = {start: Documents.positionAt(code.original, start), end: Documents.positionAt(code.original, end)};
			}
		}
		return locations;
	}

	/** Hover or definition of a type, asked at its name in `var haxeZedValue:Type = null;`. **/
	function typeProbe(typePath:String, method:String):Promise<Dynamic> {
		final host = defaultHost();
		final text = host == null ? null : readFile(host.file);
		if (host == null || text == null) {
			return Promise.resolve(null);
		}
		final code = 'var haxeZedValue:$typePath = null;';
		final probe = text + '\nprivate class HaxeZedProbe { static function haxeZedProbe() { $code } }\n';
		final offset = probe.lastIndexOf(code) + 'var haxeZedValue:'.length + typePath.length - 1;
		return compiler.display(method, host.file, probe, offset);
	}

	/** Definition of a field, asked at its name in `haxeZedValue.field;`. **/
	/** Definition or hover of a field, asked at its name in `haxeZedValue.field;`. **/
	function fieldProbe(typePath:String, field:String, method = "display/definition"):Promise<Dynamic> {
		final host = defaultHost();
		final text = host == null ? null : readFile(host.file);
		if (host == null || text == null) {
			return Promise.resolve(null);
		}
		final code = 'var haxeZedValue:$typePath = null; haxeZedValue.$field;';
		final probe = text + '\nprivate class HaxeZedProbe { static function haxeZedProbe() { $code } }\n';
		return compiler.display(method, host.file, probe, probe.lastIndexOf(code) + code.length - 2);
	}

	/**
		A property's documentation, from the compiler's hover (completion results don't carry it).
		`style` tells whether it is also a style property (`@:style`).
	**/
	function fieldDoc(typePath:String, field:String):Promise<Null<{doc:Null<String>, style:Bool}>> {
		final key = '$typePath.$field';
		final cached = docCache.get(key);
		if (cached != null) {
			return cached;
		}
		final result = fieldProbe(typePath, field, "display/hover").then(function(hover:Dynamic) {
			if (hover == null) {
				return null;
			}
			final listed:Null<Array<{name:String}>> = hover.item?.args?.field?.meta;
			final meta = listed ?? [];
			return {doc: cleanDoc(hover.documentation), style: Lambda.exists(meta, m -> m.name == ":style")};
		});
		docCache.set(key, result);
		return result;
	}

	/** Adds the property's documentation to an attribute item Zed is showing. **/
	public function resolveItem(message:Message) {
		final item:Dynamic = message.params;
		final data:Dynamic = item.data;
		if (data?.typePath == null || data?.field == null || item.documentation != null) {
			bridge.replyToClient(message.id, item);
			return;
		}
		fieldDoc(data.typePath, data.field).then(function(found) {
			final parts = [found?.doc, found?.style == true ? "Also a style property, so it can be set from CSS." : null].filter(part -> part != null && part != "");
			if (parts.length > 0) {
				item.documentation = {kind: "markdown", value: parts.join("\n\n")};
			}
			bridge.replyToClient(message.id, item);
		}, _ -> bridge.replyToClient(message.id, item));
	}

	static function markdown(heading:String, ?doc:String, ?note:String):Dynamic {
		var value = heading;
		for (part in [doc, note]) {
			if (part != null && StringTools.trim(part) != "") {
				value += "\n\n" + StringTools.trim(part);
			}
		}
		return {contents: {kind: "markdown", value: value}};
	}

	/**
		Haxe doc comments keep their `*` line prefixes and the source's indentation, which Markdown
		would show as a code block. Strip both for display.
	**/
	public static function cleanDoc(doc:Null<String>):Null<String> {
		if (doc == null) {
			return null;
		}
		final lines = [for (line in doc.split("\n")) ~/^\s*\*(\s|$)/.replace(StringTools.rtrim(line), "")];
		var indent = 1 << 30;
		for (line in lines) {
			if (StringTools.trim(line) != "") {
				indent = Std.int(Math.min(indent, line.length - StringTools.ltrim(line).length));
			}
		}
		final text = StringTools.trim([for (line in lines) line.substr(Std.int(Math.min(indent, line.length)))].join("\n"));
		return text == "" ? null : ~/\n{3,}/g.replace(text, "\n\n");
	}

	function tagOf(at:Located, project:MarkupProject, name:String, markup:String):Promise<Null<TagInfo>> {
		return at.provider.tags(project, markup).then(tags -> Lambda.find(tags, tag -> at.provider.matchesTag(tag, name)));
	}

	function attributesOf(at:Located, project:MarkupProject, tagName:String, markup:String):Promise<Array<AttributeInfo>> {
		return tagOf(at, project, tagName, markup).then(tag -> tag == null ? Promise.resolve([]) : at.provider.attributes(project, tag));
	}

	function activeProviders():Array<MarkupProvider> {
		final args = expandedArgs();
		return providers.filter(provider -> provider.appliesTo(args));
	}

	function project():MarkupProject {
		return {
			workspaceRoot: workspaceRoot(),
			args: expandedArgs(),
			compiler: compiler,
			readFile: readFile,
			defaultHost: defaultHost
		};
	}

	function expandedArgs():Array<String> {
		final args = displayArgs();
		final key = Json.stringify(args);
		if (expandedFor != key) {
			expandedFor = key;
			expanded = Hxml.expand(args, workspaceRoot());
		}
		return expanded;
	}

	/** Where the compiler's relative class paths start: the last `--cwd` in the arguments, or the workspace. **/
	function compilerCwd():String {
		var cwd = workspaceRoot();
		final args = expandedArgs();
		for (i in 0...args.length - 1) {
			if (args[i] == "--cwd") {
				cwd = args[i + 1];
			}
		}
		return cwd;
	}

	/** The `-main` class, else the first class found in the project's class paths. **/
	function defaultHost():Null<HostClass> {
		if (host != null) {
			return host;
		}
		final project:MarkupProject = {
			workspaceRoot: workspaceRoot(),
			args: expandedArgs(),
			compiler: compiler,
			readFile: readFile,
			defaultHost: () -> null
		};
		final classPaths = HaxeUiProvider.projectClassPaths(project);
		final args = expandedArgs();
		final mainIndex = args.indexOf("-main") >= 0 ? args.indexOf("-main") : args.indexOf("--main");
		if (mainIndex >= 0 && mainIndex + 1 < args.length) {
			final parts = args[mainIndex + 1].split(".");
			for (classPath in classPaths) {
				final file = Path.join([classPath].concat(parts)) + ".hx";
				if (FileSystem.exists(file)) {
					return host = {file: file, className: parts[parts.length - 1]};
				}
			}
		}
		final declaration = ~/\bclass\s+([A-Za-z_]\w*)/;
		for (classPath in classPaths) {
			for (file in Files.findByExtension(classPath, ".hx", 6)) {
				final text = readFile(file.path);
				if (text != null && declaration.match(text)) {
					return host = {file: file.path, className: declaration.matched(1)};
				}
			}
		}
		return null;
	}

	function readFile(path:String):Null<String> {
		final open = documents.text(Rewrites.pathToUri(path));
		if (open != null) {
			return open;
		}
		return try File.getContent(path) catch (_) null;
	}

	function rangeOf(at:Located, start:Int, end:Int):Dynamic {
		return {start: Documents.positionAt(at.text, start), end: Documents.positionAt(at.text, end)};
	}

	/** Start of the identifier ending at `offset`. **/
	static function wordStart(text:String, offset:Int):Int {
		var start = offset;
		while (start > 0 && ~/[A-Za-z0-9_]/.match(text.charAt(start - 1))) {
			start--;
		}
		return start;
	}
}

private typedef Probe = {
	final file:String;
	final text:String;
	final offset:Int;

	/** The file's own text, and the edits that made `text` from it (in order, offsets in `original`). **/
	final original:String;
	final edits:Array<TextEdit>;
}

private typedef TextEdit = {
	final at:Int;
	final removed:Int;
	final text:String;
}
