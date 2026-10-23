package bridge.markup;

import bridge.markup.MarkupProvider;
import bridge.project.DocPacks;
import bridge.project.Hxml;
import bridge.util.Files;
import bridge.util.HaxeTypes;
import haxe.io.Path;
import js.lib.Promise;
import sys.FileSystem;
import sys.io.File;

/**
	HaxeUI layouts: `@:xml('...')` / `@:xml(<...>)` on component classes, and `.xml` layout files.

	Follows HaxeUI's own rules (haxeui-core's `ModuleMacros`, `ComponentClassMap`, `ComponentMacros`):
	- `module.*` files anywhere in the class paths list component packages and classes
	- a tag is the class name, case-insensitive, with any `-` ignored: `<drop-down>` is `DropDown`
	- attributes set the component's public properties; `on<event>` attributes are Haxe code,
	  compiled in the class the XML belongs to, where `this` is the component and ids are locals
**/
class HaxeUiProvider implements MarkupProvider {
	/** XML files that are never layouts. **/
	static final notLayouts = ["project.xml", "include.xml", "haxelib.xml", "androidmanifest.xml"];

	/** HaxeUI's renames from attribute to field (`haxe.ui.core.ComponentFieldMap`). **/
	static final fieldAliases = ["group" => "componentGroup", "contentLayout" => "contentLayoutName"];

	static final metadata = ~/@:xml\s*\(/;
	static final classDeclaration = ~/\bclass\s+([A-Za-z_]\w*)/;
	static final buildReference = ~/(?:ComponentMacros|ComponentBuilder)\.build\(\s*["']([^"']+\.xml)["']/g;

	public var name(default, null):String = "haxeui";

	var catalog:Null<Promise<Array<Component>>>;
	var events:Null<Promise<Array<String>>>;
	final fieldCache = new Map<String, Promise<Array<AttributeInfo>>>();
	var hosts:Null<Array<LayoutReference>>;

	public function new() {}

	public function appliesTo(args:Array<String>):Bool {
		return DocPacks.mentions(args, "haxeui-core") || DocPacks.mentions(args, "haxeui_core")
			|| Lambda.exists(args, arg -> arg.indexOf("haxeui-core") >= 0);
	}

	public function regionInHaxe(text:String, offset:Int):Null<Region> {
		final start = text.lastIndexOf("@:xml", offset);
		if (start < 0 || !metadata.match(text.substr(start, 64)) || metadata.matchedPos().pos != 0) {
			return null;
		}
		var i = start + metadata.matchedPos().len;
		while (i < text.length && StringTools.isSpace(text, i)) {
			i++;
		}
		final region:Region = switch text.charAt(i) {
			case "'" | '"':
				{start: i + 1, end: closingQuote(text, i + 1, text.charAt(i))};
			case "<":
				{start: i, end: XmlCursor.elementEnd(text, i)};
			case _:
				return null;
		}
		return offset >= region.start && offset <= region.end ? region : null;
	}

	public function hostInHaxe(path:String, text:String, region:Region):Null<HostClass> {
		final rest = text.substr(region.end);
		return classDeclaration.match(rest) ? {file: path, className: classDeclaration.matched(1)} : null;
	}

	public function claimsFile(project:MarkupProject, path:String, text:String):Promise<Bool> {
		final fileName = Path.withoutDirectory(path).toLowerCase();
		if (notLayouts.contains(fileName) || StringTools.startsWith(fileName, "module.")) {
			return Promise.resolve(false);
		}
		final root = XmlCursor.elements(text)[0];
		if (root == null) {
			return Promise.resolve(false);
		}
		return components(project).then(all -> Lambda.exists(all, c -> c.alias == alias(root.name)));
	}

	public function hostOfFile(project:MarkupProject, path:String):Promise<Null<HostClass>> {
		if (hosts == null) {
			hosts = findHosts(project);
		}
		final layout = Path.normalize(path);
		for (reference in hosts) {
			if (reference.resolved.contains(layout)) {
				return Promise.resolve(reference.host);
			}
		}
		// A path relative to somewhere else (a resource folder): match the end of it.
		final stripped = (reference:LayoutReference) -> ~/^(\.\.?\/)+/.replace(Path.normalize(reference.path), "");
		for (reference in hosts) {
			if (StringTools.endsWith(layout, "/" + stripped(reference))) {
				return Promise.resolve(reference.host);
			}
		}
		return Promise.resolve(null);
	}

	public function matchesTag(tag:TagInfo, name:String):Bool {
		return alias(tag.name) == alias(name);
	}

	/**
		HaxeUI's own layouts write tags as the lowercase class name (`<dropdown>`, `<textfield>`), so that is
		offered, unless the markup already writes that tag with hyphens (`<window-title>`). Either spelling matches.
	**/
	public function tags(project:MarkupProject, style:String):Promise<Array<TagInfo>> {
		return components(project).then(all -> [
			for (c in all) {
				name: c.kebab != c.alias && style.indexOf('<${c.kebab}') >= 0 ? c.kebab : c.alias,
				typePath: c.typePath,
				filterText: c.kebab
			}
		]);
	}

	public function attributes(project:MarkupProject, tag:TagInfo):Promise<Array<AttributeInfo>> {
		final cached = fieldCache.get(tag.typePath);
		if (cached != null) {
			return cached;
		}
		final host = project.defaultHost();
		if (host == null) {
			return Promise.resolve([]);
		}
		final result = Promise.all([project.compiler.fields(tag.typePath, host), eventNames(project)]).then(function(results:Array<Dynamic>) {
			final items:Array<Dynamic> = results[0];
			final eventList:Array<String> = results[1];
			final attributes:Array<AttributeInfo> = [];
			final byField = new Map<String, AttributeInfo>();
			for (item in items) {
				final attribute = attributeOf(item);
				if (attribute != null) {
					attributes.push(attribute);
					byField.set(attribute.name, attribute);
				}
			}
			for (xmlName => field in fieldAliases) {
				final target = byField.get(field);
				if (target != null) {
					attributes.push({name: xmlName, type: target.type, doc: target.doc, field: field});
				}
			}
			for (event in eventList) {
				attributes.push({name: 'on$event', code: true, doc: 'Haxe code run on the `$event` event. `this` is the component; components with an id are variables.'});
			}
			return attributes;
		});
		fieldCache.set(tag.typePath, result);
		return result;
	}

	public function codeContext(project:MarkupProject, tag:TagInfo, attribute:String, markup:String, host:Null<HostClass>):Promise<Null<CodeContext>> {
		if (!StringTools.startsWith(attribute, "on")) {
			return Promise.resolve(null);
		}
		return components(project).then(function(all):Null<CodeContext> {
			final locals = new Map<String, String>();
			for (element in XmlCursor.elements(markup)) {
				final id = element.attributes.get("id");
				final component = Lambda.find(all, c -> c.alias == alias(element.name));
				if (id != null && component != null) {
					locals.set(safeId(id), component.typePath);
				}
			}
			return {thisType: tag.typePath, thisAlias: "__this__", locals: locals, host: host};
		});
	}

	public function invalidate(path:String) {
		if (StringTools.endsWith(path, ".hx")) {
			fieldCache.clear();
			hosts = null;
		}
		final fileName = Path.withoutDirectory(path);
		if (StringTools.endsWith(path, ".hx") || StringTools.startsWith(fileName, "module.")) {
			catalog = null;
		}
	}

	/** HaxeUI's lookup key for a tag or class name (`ComponentClassMap`). **/
	public static function alias(name:String):String {
		return StringTools.replace(name, "-", "").toLowerCase();
	}

	/** `DropDown` -> `drop-down`, `HSVColorPicker` -> `hsv-color-picker`. **/
	public static function kebab(className:String):String {
		final words = ~/([a-z0-9])([A-Z])/g.replace(~/([A-Z]+)([A-Z][a-z])/g.replace(className, "$1-$2"), "$1-$2");
		return words.toLowerCase();
	}

	/** HaxeUI turns `my-button` ids into `myButton` variables (`StringUtil.capitalizeHyphens`). **/
	public static function safeId(id:String):String {
		final parts = id.split("-");
		return parts[0] + [for (part in parts.slice(1)) part.charAt(0).toUpperCase() + part.substr(1)].join("");
	}

	/** An attribute for a writable public property; methods, callbacks (`onClick`) and internals are skipped. **/
	static function attributeOf(item:Dynamic):Null<AttributeInfo> {
		if (item.kind != "ClassField") {
			return null;
		}
		final field:Dynamic = item.args.field;
		final name:String = field.name;
		if (field.kind.kind != "FVar" || StringTools.startsWith(name, "_") || ~/^on[A-Z]/.match(name)) {
			return null;
		}
		final write:String = field.kind.args?.write?.kind;
		if (write == "AccNo" || write == "AccNever") {
			return null;
		}
		final type = HaxeTypes.print(field.type);
		return {
			name: name,
			type: type,
			values: type == "Bool" || type == "Null<Bool>" ? ["true", "false"] : null,
			doc: field.doc == null ? null : StringTools.trim(field.doc)
		};
	}

	/** The component classes, from HaxeUI's module files and the sources of the packages they list. **/
	function components(project:MarkupProject):Promise<Array<Component>> {
		if (catalog == null) {
			catalog = project.compiler.classPaths().then(buildCatalog);
		}
		return catalog;
	}

	static function buildCatalog(classPaths:Array<String>):Array<Component> {
		final packages = [];
		final classes = [];
		for (classPath in classPaths) {
			for (module in moduleFiles(classPath)) {
				readModule(module, packages, classes);
			}
		}
		// Every class in the listed packages, with the name of its superclass.
		final candidates = new Map<String, {typePath:String, superName:Null<String>}>();
		for (classPath in classPaths) {
			for (pack in packages) {
				final dir = Path.join([classPath].concat(pack.split(".")));
				final files = try FileSystem.readDirectory(dir) catch (_) [];
				for (file in files) {
					if (StringTools.endsWith(file, ".hx") && !StringTools.endsWith(file, ".macro.hx")) {
						final className = file.substr(0, file.length - 3);
						candidates.set(className, {typePath: '$pack.$className', superName: superclass(Path.join([dir, file]), className)});
					}
				}
			}
			for (typePath in classes) {
				final parts = typePath.split(".");
				final className = parts[parts.length - 1];
				final file = Path.join([classPath].concat(parts)) + ".hx";
				if (FileSystem.exists(file)) {
					candidates.set(className, {typePath: typePath, superName: superclass(file, className)});
				}
			}
		}
		function isComponent(name:String, depth:Int):Bool {
			if (name == "Component") {
				return true;
			}
			final candidate = candidates.get(name);
			return depth < 32 && candidate != null && candidate.superName != null && isComponent(candidate.superName, depth + 1);
		}
		final result = [];
		for (className => candidate in candidates) {
			if (isComponent(className, 0)) {
				result.push({
					alias: alias(className),
					kebab: kebab(className),
					typePath: candidate.typePath
				});
			}
		}
		result.sort((a, b) -> Reflect.compare(a.alias, b.alias));
		return result;
	}

	/** Files named `module.*` under a class path (HaxeUI's `ModuleMacros.loadModules`). **/
	static function moduleFiles(classPath:String):Array<String> {
		return Files.findByExtension(classPath, ".xml", 12).map(f -> f.path).filter(path -> StringTools.startsWith(Path.withoutDirectory(path), "module."));
	}

	/** Reads the `<components>` section of a HaxeUI module file. **/
	static function readModule(path:String, packages:Array<String>, classes:Array<String>) {
		final text = try File.getContent(path) catch (_) return;
		final inComponents = ~/<components[^>]*>([\s\S]*?)<\/components>/g;
		var rest = text;
		while (inComponents.match(rest)) {
			for (element in XmlCursor.elements(inComponents.matched(1))) {
				if (element.name != "class") {
					continue;
				}
				final pack = element.attributes.get("package");
				final className = element.attributes.get("name") ?? element.attributes.get("class");
				if (pack != null && !packages.contains(pack)) {
					packages.push(pack);
				}
				if (className != null && !classes.contains(className)) {
					classes.push(className);
				}
			}
			rest = inComponents.matchedRight();
		}
	}

	/** Simple name of the class `className` extends in `file`, read from the source. **/
	static function superclass(file:String, className:String):Null<String> {
		final text = try File.getContent(file) catch (_) return null;
		final declaration = new EReg('\\bclass\\s+$className\\b[^{]*?\\bextends\\s+([\\w.]+)', "");
		if (!declaration.match(text)) {
			return null;
		}
		final parts = declaration.matched(1).split(".");
		return parts[parts.length - 1];
	}

	/** Event names from `EventType.name("...")` in HaxeUI's `haxe.ui.events` package. **/
	function eventNames(project:MarkupProject):Promise<Array<String>> {
		if (events == null) {
			events = project.compiler.classPaths().then(function(classPaths) {
				final names = [];
				final eventName = ~/EventType\.name\("([a-z]+)"\)/g;
				for (classPath in classPaths) {
					final dir = Path.join([classPath, "haxe", "ui", "events"]);
					for (file in (try FileSystem.readDirectory(dir) catch (_) [])) {
						var text = try File.getContent(Path.join([dir, file])) catch (_) "";
						while (eventName.match(text)) {
							if (!names.contains(eventName.matched(1))) {
								names.push(eventName.matched(1));
							}
							text = eventName.matchedRight();
						}
					}
				}
				names.sort(Reflect.compare);
				return names;
			});
		}
		return events;
	}

	/** Classes built from `.xml` files: `ComponentMacros.build("...")` / `ComponentBuilder.build("...")` in the project's sources. **/
	static function findHosts(project:MarkupProject):Array<LayoutReference> {
		final found = [];
		final classPaths = projectClassPaths(project);
		for (classPath in classPaths) {
			for (file in Files.findByExtension(classPath, ".hx", 12)) {
				var text = project.readFile(file.path) ?? "";
				while (buildReference.match(text)) {
					final reference = buildReference.matched(1);
					final after = buildReference.matchedRight();
					if (classDeclaration.match(after)) {
						// The path may be relative to the Haxe file, the project, or a class path.
						final bases = [Path.directory(file.path), project.workspaceRoot].concat(classPaths);
						found.push({
							path: reference,
							resolved: Path.isAbsolute(reference) ? [Path.normalize(reference)] : [for (base in bases) Path.normalize(Path.join([base, reference]))],
							host: {file: file.path, className: classDeclaration.matched(1)}
						});
					}
					text = after;
				}
			}
		}
		return found;
	}

	/** The project's own class paths (`-cp` in the display arguments), not libraries. **/
	public static function projectClassPaths(project:MarkupProject):Array<String> {
		final args = Hxml.expand(project.args, project.workspaceRoot);
		final result = [];
		var cwd = project.workspaceRoot;
		for (i in 0...args.length - 1) {
			if (args[i] == "--cwd") {
				cwd = args[i + 1];
			} else if (args[i] == "-cp" || args[i] == "-p" || args[i] == "--class-path") {
				final path = Path.isAbsolute(args[i + 1]) ? args[i + 1] : Path.join([cwd, args[i + 1]]);
				if (!result.contains(path)) {
					result.push(path);
				}
			}
		}
		return result;
	}

	static function closingQuote(text:String, start:Int, quote:String):Int {
		var i = start;
		while (i < text.length) {
			final char = text.charAt(i);
			if (char == "\\") {
				i += 2;
				continue;
			}
			if (char == quote) {
				return i;
			}
			i++;
		}
		return text.length;
	}
}

private typedef LayoutReference = {
	/** As written in `ComponentMacros.build("...")`. **/
	final path:String;

	/** Absolute paths it can mean. **/
	final resolved:Array<String>;

	final host:HostClass;
}

private typedef Component = {
	/** Lowercase class name, HaxeUI's tag lookup key. **/
	final alias:String;

	/** Hyphenated form, for markup that writes multi-word tags with hyphens. **/
	final kebab:String;

	final typePath:String;
}
