import bridge.lsp.HaxeItems;
import bridge.lsp.Ranking;
import bridge.markup.HaxeUiProvider;
import bridge.markup.MarkupProvider;
import bridge.markup.XmlCursor;
import bridge.project.Hxml;
import bridge.util.HaxeTypes;
import haxe.io.Path;
import js.lib.Promise;
import utest.Assert;
import utest.Async;

/** Answers like the compiler would, from canned data. **/
class FakeCompiler implements Compiler {
	final paths:Array<String>;
	final fieldsByType:Map<String, Array<Dynamic>>;

	public function new(paths:Array<String>, ?fieldsByType:Map<String, Array<Dynamic>>) {
		this.paths = paths;
		this.fieldsByType = fieldsByType ?? new Map();
	}

	public function classPaths():Promise<Array<String>> {
		return Promise.resolve(paths);
	}

	public function fields(typePath:String, host:HostClass):Promise<Array<Dynamic>> {
		return Promise.resolve(fieldsByType.get(typePath) ?? []);
	}
}

/** Markup support: the XML scanner, HaxeUI's rules, and turning compiler results into LSP items. **/
class MarkupTest extends utest.Test {
	function testCursorPositions() {
		final xml = '<vbox>\n\t<button id="ok" text="Save" onclick="if (a > b) ok.text = \'x\';" />\n\t<!-- <label> -->\n\t</vbox>';
		Assert.same(TagName("button", 9, 15, ["vbox"]), XmlCursor.at(xml, 11));
		Assert.same(TagName("", 1, 1, []), XmlCursor.at("<", 1));
		Assert.same(AttributeName("button", "text", 24, 28, ["id", "onclick"]), XmlCursor.at(xml, 26));
		Assert.same(AttributeName("button", "id", 16, 18, ["text", "onclick"]), XmlCursor.at(xml, 16)); // at the start of an attribute
		Assert.same(AttributeName("button", "", 8, 8, []), XmlCursor.at("<button ", 8)); // room for a new one
		Assert.same(AttributeName("button", "", 8, 8, ["id"]), XmlCursor.at('<button  id="a" />', 8));
		final value = xml.indexOf("if (a");
		Assert.same(AttributeValue("button", "onclick", "if (a > b) ok.text = 'x';", value), XmlCursor.at(xml, value + 3));
		Assert.same(Other, XmlCursor.at(xml, xml.indexOf("<label>") + 2)); // inside a comment
		Assert.same(CloseTagName("vbox", xml.length - 5, xml.length - 1, "vbox"), XmlCursor.at(xml, xml.length - 2));
	}

	function testCursorWhileTyping() {
		Assert.same(AttributeName("button", "te", 8, 10, []), XmlCursor.at("<button te", 10));
		Assert.same(AttributeValue("button", "onclick", "ok.", 17), XmlCursor.at('<button onclick="ok.', 20));
	}

	function testElementsAndEnds() {
		final xml = '<window title="A"><button id="ok" onclick="a > b" /><hbox><label id="l" /></hbox></window>) class X {}';
		final elements = XmlCursor.elements(xml);
		Assert.same(["window", "button", "hbox", "label"], elements.map(e -> e.name));
		Assert.equals("ok", elements[1].attributes.get("id"));
		Assert.equals(xml.indexOf(")"), XmlCursor.elementEnd(xml, 0));
	}

	function testHaxeUiRegions() {
		final provider = new HaxeUiProvider();
		final quoted = "package ui;\n@:xml('\n<vbox>\n\t<button text=\"Hi\" />\n</vbox>\n')\nclass Hello extends VBox {}";
		final inside = quoted.indexOf("button");
		final region = provider.regionInHaxe(quoted, inside);
		Assert.equals(quoted.indexOf("'") + 1, region?.start);
		Assert.equals(quoted.lastIndexOf("'"), region?.end);
		Assert.isNull(provider.regionInHaxe(quoted, quoted.indexOf("extends")));
		Assert.same({file: "/p/Hello.hx", className: "Hello"}, provider.hostInHaxe("/p/Hello.hx", quoted, region));

		final markup = "@:xml(<window title=\"T\">\n\t<button id=\"b\" />\n</window>)\nclass W extends Window {}";
		final markupRegion = provider.regionInHaxe(markup, markup.indexOf("button"));
		Assert.equals(markup.indexOf("<window"), markupRegion?.start);
		Assert.equals(markup.indexOf(")"), markupRegion?.end);
	}

	function testHaxeUiNames() {
		Assert.equals("dropdown", HaxeUiProvider.alias("drop-down"));
		Assert.equals("drop-down", HaxeUiProvider.kebab("DropDown"));
		Assert.equals("hsv-color-picker", HaxeUiProvider.kebab("HSVColorPicker"));
		Assert.equals("myButton", HaxeUiProvider.safeId("my-button"));
		Assert.isTrue(new HaxeUiProvider().appliesTo(["--library", "haxeui-core"]));
		Assert.isFalse(new HaxeUiProvider().appliesTo(["-lib", "flixel"]));
	}

	@:timeout(5000)
	function testHaxeUiCatalogFollowsModulesAndInheritance(async:Async) {
		final root = haxeUiFixture();
		final project = projectOf(root, new FakeCompiler([Path.join([root, "lib"]), Path.join([root, "src"])]));
		final provider = new HaxeUiProvider();
		provider.tags(project, "<vbox><window-title /></vbox>").then(function(tags) {
			final names = tags.map(t -> t.name);
			Assert.contains("button", names);
			Assert.contains("dropdown", names); // HaxeUI's usual spelling...
			Assert.contains("window-title", names); // ...unless the markup already hyphenates the tag
			Assert.contains("fancy", names); // project component, via a superclass in another package
			Assert.isFalse(names.contains("screen")); // in a listed package, but not a component
			Assert.isFalse(names.contains("helper"));
			async.done();
		}, error -> fail(async, error));
	}

	@:timeout(5000)
	function testHaxeUiAttributes(async:Async) {
		final root = haxeUiFixture();
		final fields:Map<String, Array<Dynamic>> = [
			"haxe.ui.components.Button" => [
				field("text", "FVar", "String", "AccCall"),
				field("selected", "FVar", "Bool", "AccCall"),
				field("componentGroup", "FVar", "String", "AccCall"),
				field("onClick", "FVar", "String", "AccCall"),
				field("_internal", "FVar", "String", "AccNormal"),
				field("readOnly", "FVar", "String", "AccNo"),
				field("show", "FMethod", "Void", null)
			]
		];
		final project = projectOf(root, new FakeCompiler([Path.join([root, "lib"])], fields));
		new HaxeUiProvider().attributes(project, {name: "button", typePath: "haxe.ui.components.Button"}).then(function(attributes) {
			final names = attributes.map(a -> a.name);
			Assert.same(["text", "selected", "componentGroup", "group", "onclick"], names);
			Assert.same(["true", "false"], attributes[1].values);
			Assert.equals("componentGroup", attributes[3].field);
			Assert.isTrue(attributes[4].code);
			async.done();
		}, error -> fail(async, error));
	}

	@:timeout(5000)
	function testHaxeUiCodeContext(async:Async) {
		final root = haxeUiFixture();
		final project = projectOf(root, new FakeCompiler([Path.join([root, "lib"])]));
		final markup = '<vbox><button id="save-button" onclick="x" /><dropdown id="list" /></vbox>';
		final host:HostClass = {file: "/p/A.hx", className: "A"};
		final provider = new HaxeUiProvider();
		final button = {name: "button", typePath: "haxe.ui.components.Button"};
		Promise.all([provider.codeContext(project, button, "onclick", markup, host), provider.codeContext(project, button, "text", markup, host)])
			.then(function(results:Array<Dynamic>) {
				final context:CodeContext = results[0];
				Assert.equals("haxe.ui.components.Button", context.thisType);
				Assert.equals("__this__", context.thisAlias);
				Assert.equals("haxe.ui.components.Button", context.locals.get("saveButton"));
				Assert.equals("haxe.ui.components.DropDown", context.locals.get("list"));
				Assert.isNull(results[1]); // `text` isn't code
				async.done();
			}, error -> fail(async, error));
	}

	@:timeout(5000)
	function testHaxeUiLayoutFiles(async:Async) {
		final root = haxeUiFixture();
		final project = projectOf(root, new FakeCompiler([Path.join([root, "lib"]), Path.join([root, "src"])]));
		final provider = new HaxeUiProvider();
		Promise.all([
			provider.claimsFile(project, Path.join([root, "assets/main.xml"]), "<vbox><button /></vbox>"),
			provider.claimsFile(project, Path.join([root, "project.xml"]), "<project></project>"),
			provider.claimsFile(project, Path.join([root, "assets/data.xml"]), "<data><item /></data>"),
			provider.hostOfFile(project, Path.join([root, "assets/main.xml"])),
			provider.hostOfFile(project, Path.join([root, "assets/panel.xml"]))
		]).then(function(results:Array<Dynamic>) {
			Assert.isTrue(results[0]);
			Assert.isFalse(results[1]);
			Assert.isFalse(results[2]);
			Assert.same({file: Path.join([root, "src/ui/Main.hx"]), className: "MainView"}, results[3]);
			Assert.same({file: Path.join([root, "src/ui/Panel.hx"]), className: "Panel"}, results[4]); // relative to the Haxe file
			async.done();
		}, error -> fail(async, error));
	}

	function testHxmlExpansion() {
		final dir = Fixture.create({"common.hxml": "-lib haxeui-core\n-cp src", "sub/build.hxml": "-main Main", "app.hxml": "common.hxml\n--cpp bin"});
		Assert.same(["-lib", "haxeui-core", "-cp", "src", "--cpp", "bin"], Hxml.expand(["app.hxml"], dir));
		Assert.same(["--cwd", Path.join([dir, "sub"]), "-main", "Main"], Hxml.expand(["--cwd", "sub", "build.hxml"], dir));
	}

	function testDocCleanup() {
		final doc = "\n     * Whether to disable interactivity.\n     *\n     * The user can't interact with disabled components.\n     ";
		Assert.equals("Whether to disable interactivity.\n\nThe user can't interact with disabled components.", bridge.lsp.MarkupFeature.cleanDoc(doc));
		Assert.equals("The image resource", bridge.lsp.MarkupFeature.cleanDoc("The image resource"));
		Assert.isNull(bridge.lsp.MarkupFeature.cleanDoc(" * "));
		// Indented class docs (HaxeUI's) would otherwise render as a code block.
		Assert.equals("A button.\n\n| Id | Type |\n| -- | -- |", bridge.lsp.MarkupFeature.cleanDoc("\n    A button.\n\n    | Id | Type |\n    | -- | -- |\n"));
	}

	function testRankingServerItems() {
		final mine = {label: "_cache", detail: "private var _cache:Int\n from class 'Windows'"};
		final inheritedPrivate = {label: "handleClick", detail: "private function handleClick():Void\n from class 'Component'"};
		final internal = {label: "_onMouseClick", detail: "public function _onMouseClick():Void\n from class 'Component'"};
		final publicField = {label: "text", detail: "public var text:String\n from class 'Component'"};
		final local = {label: "_tmp", detail: "Int"};
		final context = Ranking.editingContext("class Windows extends VBox {\n\tvar _ownCache:Int;\n\tfunction f() {}\n}", 40);
		Assert.equals(0, Ranking.ofServerItem(mine, context));
		Assert.equals(1, Ranking.ofServerItem(inheritedPrivate, context));
		Assert.equals(2, Ranking.ofServerItem(internal, context));
		Assert.equals(0, Ranking.ofServerItem(publicField, context));
		Assert.equals(0, Ranking.ofServerItem(local, context));
		// Without the "from class" line (as the server sends it in some places), names declared in the file are the class's own.
		Assert.equals(0, Ranking.ofServerItem({label: "_ownCache", detail: "private var _ownCache:Int"}, context));
		Assert.equals(2, Ranking.ofServerItem({label: "_onMouseClick", detail: "private function _onMouseClick():Void"}, context));
		Assert.equals(1, Ranking.ofServerItem({label: "layout", detail: "private var layout:Layout"}, context));

		final items:Array<Dynamic> = [{label: "a", sortText: "01"}, {label: "_b", sortText: "02"}, {label: "c", sortText: "03"}];
		Assert.same(["0" + "01", "2" + "02", "0" + "03"], Ranking.apply(items.copy(), [0, 2, 0], Last).map(i -> i.sortText));
		Assert.same(["a", "c"], Ranking.apply([{label: "a"}, {label: "_b"}, {label: "c"}], [0, 2, 0], Hide).map(i -> i.label));
		// Without a sortText, the compiler's order is kept in every mode instead of falling back to labels.
		Assert.same(["000000", "000001", "000002"], Ranking.apply([{label: "c"}, {label: "_b"}, {label: "a"}], [0, 2, 0], Show).map(i -> i.sortText));
		Assert.same(["000000", "000002"], Ranking.apply([{label: "c"}, {label: "_b"}, {label: "a"}], [0, 2, 0], Hide).map(i -> i.sortText));
	}

	function testRankingDisplayItems() {
		final own = {kind: "ClassField", args: {field: {name: "_cache", isPublic: false}, origin: {kind: 0}}};
		final inherited = {kind: "ClassField", args: {field: {name: "_onMouseClick", isPublic: false}, origin: {kind: 2}}};
		final privateInherited = {kind: "ClassField", args: {field: {name: "layout", isPublic: false}, origin: {kind: 2}}};
		Assert.equals(0, Ranking.ofDisplayItem(own, false)); // the current class's own member, by bare name
		Assert.equals(2, Ranking.ofDisplayItem(own, true)); // the same member after `id.` is an internal
		Assert.equals(2, Ranking.ofDisplayItem(inherited, false));
		Assert.equals(1, Ranking.ofDisplayItem(privateInherited, false));
		Assert.equals(0, Ranking.ofDisplayItem({kind: "Local", args: {name: "_x"}}, false));
	}

	@:access(bridge.lsp.MarkupFeature)
	function testProbePositionsMapBackToTheFile() {
		final text = "@:xml('<vbox><button\n')\nclass Windows {\n\tfunction onClick() {}\n}";
		final markupStart = text.indexOf("<vbox");
		final markupEnd = text.indexOf("')");
		final markup = text.substring(markupStart, markupEnd);
		Assert.isFalse(bridge.lsp.MarkupFeature.parses(markup)); // a tag is half typed
		Assert.equals("<vbox />", bridge.lsp.MarkupFeature.rootOnly(markup));

		final edits = [{at: markupStart, removed: markupEnd - markupStart, text: "<vbox />"}];
		final probe = bridge.lsp.Probe.inClass("/p/Windows.hx", text, "Windows", "\n\tfunction haxeZedProbe() { { onCl", "; } }\n", edits);
		Assert.equals("@:xml('<vbox />')\nclass Windows {\n\tfunction haxeZedProbe() { { onCl; } }\n\n\tfunction onClick() {}\n}", probe.text);
		Assert.equals("onCl", probe.text.substring(probe.offset - 4, probe.offset));

		// Haxe's answer for `onClick` points into the probe's text: line 4 there is line 3 in the file.
		final inProbe = probe.text.indexOf("onClick");
		final location = {uri: "file:///p/Windows.hx", range: {start: bridge.lsp.Documents.positionAt(probe.text, inProbe), end: bridge.lsp.Documents.positionAt(probe.text, inProbe + 7)}};
		final real:Dynamic = probe.realLocations([location])[0];
		Assert.same({line: 3, character: 10}, real.range.start);
		Assert.same({line: 3, character: 17}, real.range.end);
	}

	function testProbeAtTheEndOfAFile() {
		final probe = bridge.lsp.Probe.atEnd("/p/Main.hx", "class Main {}", "var haxeZedValue:Button = null;", 22);
		Assert.equals("class Main {}\nprivate class HaxeZedProbe { static function haxeZedProbe() { var haxeZedValue:Button = null; } }\n", probe.text);
		Assert.equals("n", probe.text.charAt(probe.offset)); // the last character of `Button`
		Assert.equals(4, probe.toOriginal(4)); // the file's own text doesn't move
	}

	function testLocationsSkipNothing() {
		Assert.same([], HaxeItems.locations(null));
		Assert.same([], HaxeItems.locations([null])); // what Haxe answers for the type of a function
		final range = {start: {line: 1, character: 0}, end: {line: 1, character: 4}};
		Assert.same([{uri: "file:///p/A.hx", range: range}], HaxeItems.locations([{file: "/p/A.hx", range: range}]));
	}

	function testEnclosingClass() {
		final text = "class A {\n}\nclass B extends A {\n\tfunction f() { this. }\n}";
		Assert.equals("B", Ranking.enclosingClass(text, text.indexOf("this.")));
		Assert.equals("A", Ranking.enclosingClass(text, text.indexOf("}")));
		Assert.isNull(Ranking.enclosingClass(text, 0));
		final documented = "/** The class that ranks. **/\nabstract class Child extends Base {\n\t/** Uses the class of things. **/\n\tfunction work() { this. }\n}";
		Assert.equals("Child", Ranking.enclosingClass(documented, documented.indexOf("this.")));
		Assert.equals("Flags", Ranking.enclosingClass("enum abstract Flags(Int) {\n\tvar A;\n}", 30));
	}

	function testTypePrinting() {
		final string:Dynamic = {kind: "TInst", args: {path: {typeName: "String", pack: []}, params: []}};
		final nullable = {kind: "TAbstract", args: {path: {typeName: "Null", pack: []}, params: [string]}};
		Assert.equals("Null<String>", HaxeTypes.print(nullable));
		final fun = {kind: "TFun", args: {args: [{name: "a", opt: false, t: string}, {name: "b", opt: true, t: nullable}], ret: string}};
		Assert.equals("(a:String, ?b:Null<String>) -> String", HaxeTypes.print(fun));
		Assert.equals("{ x:String }", HaxeTypes.print({kind: "TAnonymous", args: {fields: [{name: "x", type: string}]}}));
	}

	function testCompletionItemConversion() {
		final range = {start: {line: 0, character: 0}, end: {line: 0, character: 2}};
		final item = HaxeItems.completionItem(field("hide", "FMethod", "Void", null, "Hides it."), range);
		Assert.equals("hide", item.label);
		Assert.equals(2, item.kind);
		Assert.equals("Hides it.", item.documentation.value);
		Assert.same({range: range, newText: "hide"}, item.textEdit);
		Assert.isNull(HaxeItems.completionItem({kind: "Local", args: {name: "haxeZedValue", type: null}}, range));
		Assert.isNull(HaxeItems.completionItem({kind: "Local", args: {name: "__this__", type: null}}, range));

		final string:Dynamic = {kind: "TInst", args: {path: {typeName: "String", pack: []}, params: []}};
		final help = HaxeItems.signatureHelp({signatures: [{args: [{name: "message", opt: false, t: string}], ret: string}], activeParameter: 0});
		Assert.equals("(message:String):String", help.signatures[0].label);
		Assert.same([1, 15], help.signatures[0].parameters[0].label);
	}

	/**
		A tiny HaxeUI: a library with a module file listing two packages (one class isn't a component),
		and a project with its own module file, a component extending a library one, and a layout file.
	**/
	static function haxeUiFixture():String {
		return Fixture.create({
			"lib/haxe/ui/module.xml": '<module><components><class package="haxe.ui.core" /><class package="haxe.ui.components" /><class package="haxe.ui.containers" /><class package="haxe.ui.containers.windows" /></components></module>',
			"lib/haxe/ui/core/Component.hx": "package haxe.ui.core;\nclass Component {}",
			"lib/haxe/ui/core/Screen.hx": "package haxe.ui.core;\nclass Screen {}",
			"lib/haxe/ui/events/MouseEvent.hx": 'package haxe.ui.events;\nclass MouseEvent {\n\tpublic static final CLICK:EventType<MouseEvent> = EventType.name("click");\n}',
			"lib/haxe/ui/components/Button.hx": "package haxe.ui.components;\nimport haxe.ui.core.Component;\nclass Button extends Component {}",
			"lib/haxe/ui/components/DropDown.hx": "package haxe.ui.components;\nclass DropDown extends Button {}",
			"lib/haxe/ui/containers/Box.hx": "package haxe.ui.containers;\nclass Box extends haxe.ui.core.Component {}",
			"lib/haxe/ui/containers/VBox.hx": "package haxe.ui.containers;\nclass VBox extends Box {}",
			"lib/haxe/ui/containers/windows/WindowTitle.hx": "package haxe.ui.containers.windows;\nclass WindowTitle extends haxe.ui.containers.Box {}",
			"src/module.xml": '<module><components><class package="ui" /></components></module>',
			"src/ui/Fancy.hx": "package ui;\nimport haxe.ui.containers.VBox;\nclass Fancy extends VBox {}",
			"src/ui/Helper.hx": "package ui;\nclass Helper {}",
			"src/ui/Main.hx": 'package ui;\n@:build(haxe.ui.ComponentBuilder.build("assets/main.xml"))\nclass MainView extends haxe.ui.containers.VBox {}',
			"src/ui/Panel.hx": 'package ui;\n@:build(haxe.ui.macros.ComponentMacros.build("../../assets/panel.xml"))\nclass Panel extends haxe.ui.containers.VBox {}',
			"assets/panel.xml": "<vbox />",
			"assets/main.xml": "<vbox><button /></vbox>"
		});
	}

	static function projectOf(root:String, compiler:Compiler):MarkupProject {
		return {
			workspaceRoot: root,
			args: ["-cp", "src", "--library", "haxeui-core"],
			compiler: compiler,
			readFile: path -> try sys.io.File.getContent(path) catch (_) null,
			defaultHost: () -> {file: Path.join([root, "src/ui/Main.hx"]), className: "MainView"}
		};
	}

	static function field(name:String, kind:String, typeName:String, write:Null<String>, ?doc:String):Dynamic {
		final type = {kind: "TInst", args: {path: {typeName: typeName, pack: []}, params: []}};
		return {
			kind: "ClassField",
			args: {field: {name: name, type: type, doc: doc, kind: {kind: kind, args: write == null ? ("MethNormal" : Dynamic) : {read: {kind: "AccCall"}, write: {kind: write}}}}}
		};
	}

	static function fail(async:Async, error:Dynamic) {
		Assert.fail(Std.string(error));
		async.done();
	}
}
