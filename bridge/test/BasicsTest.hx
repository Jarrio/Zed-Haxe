import bridge.lsp.CompilerDocs;
import bridge.lsp.Documents;
import bridge.lsp.ZedDebug;
import bridge.lsp.ZedTasks;
import bridge.lsp.ZedTasks.TaskToolchain;
import bridge.project.DocPacks;
import bridge.project.Hxml;
import bridge.util.Vars;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import utest.Assert;

/** Pure helpers: hxml parsing, placeholders, doc packs, cursor contexts, document edits. **/
class BasicsTest extends utest.Test {
	function testHxmlFollowsCompilerRules() {
		final hxml = '-cp src\n-main Main\n# comment\n\n--macro include("pack")\nMain\n-D "key=value with space"\r\n--interp';
		Assert.same(["-cp", "src", "-main", "Main", "--macro", 'include("pack")', "Main", "-D", "key=value with space", "--interp"], Hxml.parse(hxml));
	}

	function testVarsExpandPlaceholdersAndLists() {
		Assert.equals("/game/out", Vars.expand("${projectDir}/out", {projectDir: "/game"}));
		Assert.same(["lime", "display", "html5", "-debug"],
			Vars.expandArgs(["lime", "display", "${target}", "${buildTypeArgs}"], {target: "html5"}, {buildTypeArgs: ["-debug"]}));
		// An empty list and an empty value both disappear.
		Assert.same(["lime", "display"], Vars.expandArgs(["lime", "display", "${target}", "${buildTypeArgs}"], {}, {buildTypeArgs: []}));
	}

	function testDocPacksMatchLibraries() {
		Assert.isTrue(DocPacks.mentions(["-lib", "flixel:6.1.0"], "flixel"));
		Assert.isTrue(DocPacks.mentions(["-D", "flixel=6.1.0"], "flixel"));
		Assert.isFalse(DocPacks.mentions(["-D", "flixel-addons=3.3.2"], "flixel"));
		Assert.isFalse(DocPacks.mentions(["-cp", "flixel"], "flixel"));
	}

	function testDocPacksBecomeMacros() {
		final dir = Fixture.create({"docs/my.defines.json": "[]"});
		final macros = DocPacks.macros([
			{lib: "mylib", defines: "docs/my.defines.json"},
			{lib: "absent", metadata: "docs/my.defines.json"},
			{lib: "mylib", metadata: "docs/missing.json"}
		], ["-lib", "mylib"], dir, Path.join([dir, "builtin"]));
		final file = Path.join([dir, "docs/my.defines.json"]);
		Assert.same(["--macro", 'haxe.macro.Compiler.registerDefinesDescriptionFile(\'$file\', \'mylib\')'], macros);
	}

	function testBuiltInDocPacksAreWrittenOut() {
		final dir = Fixture.create({});
		final macros = DocPacks.macros([{lib: "flixel", defines: "builtin:flixel.defines.json"}], ["-D", "flixel=6.1.0"], dir, Path.join([dir, "builtin"]));
		Assert.equals(2, macros.length);
		Assert.isTrue(FileSystem.exists(Path.join([dir, "builtin", "flixel.defines.json"])));
	}

	function testDocContexts() {
		Assert.same(Define("FLX_NO_MOUSE"), CompilerDocs.contextAt("#if FLX_NO_MOUSE", 6));
		Assert.same(Define("html5"), CompilerDocs.contextAt("\t#elseif (js && !html5)", 19));
		Assert.same(Define(""), CompilerDocs.contextAt("#if ", 4));
		Assert.isNull(CompilerDocs.contextAt("#if FLX", 2)); // on the keyword itself
		Assert.same(Metadata("bitmap"), CompilerDocs.contextAt('@:bitmap("logo.png")', 4));
		Assert.same(Metadata(""), CompilerDocs.contextAt("@:", 2));
		Assert.isNull(CompilerDocs.contextAt("var x = 1;", 5));
	}

	function testZedTasksFile() {
		final dir = Fixture.create({});
		final tasks:Array<bridge.project.ProjectProvider.TaskSpec> = [
			{label: "haxe: other.hxml", command: ["haxe", "other.hxml"], cwd: dir, target: "other.hxml"},
			{label: "haxe: build.hxml", command: ["haxe", "build.hxml"], cwd: Path.join([dir, "sub"]), target: "build.hxml"}
		];
		final toolchain:TaskToolchain = {haxe: "/hx/versions/4.3.7/haxe", haxelib: "/hx/versions/4.3.7/haxelib", env: ({HAXE_STD_PATH: "/hx/versions/4.3.7/std"} : haxe.DynamicAccess<String>)};
		final content = ZedTasks.render(tasks, dir, toolchain, "build.hxml");
		Assert.isTrue(ZedTasks.isGenerated(content));
		final parsed:Array<Dynamic> = haxe.Json.parse(content.split("\n").filter(line -> !StringTools.startsWith(line, "//")).join("\n"));
		Assert.equals("haxe: build.hxml", parsed[0].label); // current target first
		Assert.equals("/hx/versions/4.3.7/haxe", parsed[0].command);
		Assert.equals("$ZED_WORKTREE_ROOT/sub", parsed[0].cwd);
		Assert.equals("/hx/versions/4.3.7/std", parsed[0].env.HAXE_STD_PATH);
		Assert.equals("$ZED_WORKTREE_ROOT", parsed[1].cwd);

		Assert.equals(Written, ZedTasks.write(dir, content));
		Assert.equals(Unchanged, ZedTasks.write(dir, content));
		sys.io.File.saveContent(ZedTasks.path(dir), "[] // mine");
		Assert.equals(NotOurs, ZedTasks.write(dir, content));
		Assert.equals("[] // mine", sys.io.File.getContent(ZedTasks.path(dir)));
	}

	function testZedDebugFile() {
		final dir = Fixture.create({});
		final tasks:Array<bridge.project.ProjectProvider.TaskSpec> = [
			{label: "haxe: script.hxml", command: ["haxe", "script.hxml"], cwd: dir, target: "script.hxml", debug: {hxml: "script.hxml", program: "bin/Main-debug"}},
			{label: "haxe: neko.hxml", command: ["haxe", "neko.hxml"], cwd: dir, target: "neko.hxml"},
			{label: "lime: test hl", command: ["haxelib", "run", "lime", "test", "project.xml", "hl"], cwd: Path.join([dir, "game"]), target: "hl",
				debug: {command: ["haxelib", "run", "lime", "test", "project.xml", "hl"]}}
		];
		Assert.equals(Unchanged, ZedDebug.write(dir, ZedDebug.render([], dir, null), 0)); // nothing to debug, no file
		Assert.isFalse(sys.FileSystem.exists(ZedDebug.path(dir)));

		final content = ZedDebug.render(tasks, dir, "hl");
		Assert.isTrue(StringTools.startsWith(content, "// Generated by the Haxe extension"));
		final parsed:Array<Dynamic> = haxe.Json.parse(content.split("\n").filter(line -> !StringTools.startsWith(line, "//")).join("\n"));
		Assert.same([
			{label: "Debug lime test hl", adapter: "Haxe", request: "launch", command: ["haxelib", "run", "lime", "test", "project.xml", "hl"], cwd: "game"},
			{label: "Debug script.hxml", adapter: "Haxe", request: "launch", hxml: "script.hxml", program: "bin/Main-debug"}
		], parsed); // current target first, nothing for neko, no cwd for the worktree itself

		Assert.equals(Written, ZedDebug.write(dir, content, 2));
		Assert.equals(Unchanged, ZedDebug.write(dir, content, 2));
		sys.io.File.saveContent(ZedDebug.path(dir), "[] // mine");
		Assert.equals(NotOurs, ZedDebug.write(dir, content, 2));
		Assert.equals("[] // mine", sys.io.File.getContent(ZedDebug.path(dir)));
	}

	function testDocumentsApplyIncrementalChanges() {
		final documents = new Documents();
		documents.open("file:///a.hx", "line one\nline two\r\nthree");
		documents.change("file:///a.hx", [{range: {start: {line: 1, character: 5}, end: {line: 1, character: 8}}, text: "2"}]);
		Assert.equals("line 2", documents.line("file:///a.hx", 1));
		documents.change("file:///a.hx", [{text: "replaced"}]);
		Assert.equals("replaced", documents.line("file:///a.hx", 0));
		Assert.isNull(documents.line("file:///other.hx", 0));
	}
}
