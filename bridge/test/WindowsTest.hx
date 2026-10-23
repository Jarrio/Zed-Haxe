import bridge.lsp.ClientUris;
import bridge.util.Exec;
import bridge.util.Files;
import bridge.util.Uris;
import utest.Assert;

/** What the bridge does differently on Windows, with Windows switched on so it runs on any system. **/
class WindowsTest extends utest.Test {
	function testWhichFollowsPathExt() {
		final dir = Fixture.create({"lime": "", "lime.cmd": "", "haxe.exe": ""});
		final env = {Path: dir, PATHEXT: ".COM;.EXE;.BAT;.CMD"};
		// A shell script without an extension (Git for Windows puts some on PATH) can't be started.
		Assert.equals('$dir/lime.cmd', Files.which("lime", env, true));
		Assert.equals('$dir/haxe.exe', Files.which("haxe", env, true));
		Assert.equals('$dir/lime.cmd', Files.which("lime.cmd", env, true));
		Assert.isNull(Files.which("ceramic", env, true));
		Assert.equals('$dir/lime', Files.which("lime", {PATH: dir}, false));
	}

	function testExecutableResolvesPaths() {
		final dir = Fixture.create({"tools/run.cmd": ""});
		Assert.equals('$dir/tools/run.cmd', Files.executable("tools/run", {}, dir, true));
		Assert.equals('$dir/tools/run.cmd', Files.executable('$dir/tools/run', {}, "/elsewhere", true));
		Assert.isNull(Files.executable("tools/missing", {}, dir, true));
	}

	function testExeStartsDirectly() {
		Assert.same({file: "C:\\Haxe\\haxe.exe", args: ["--cwd", "C:\\My Game"], verbatim: false},
			Exec.windowsStart("C:\\Haxe\\haxe.exe", ["--cwd", "C:\\My Game"], "cmd.exe"));
	}

	function testLauncherGoesThroughCmdEscaped() {
		// The same command line cross-spawn builds.
		final start = Exec.windowsStart("C:\\Program Files\\Haxe/haxelib.cmd", ["run", "lime", "C:\\My Game\\", 'say "hi"', "100%"], "C:\\cmd.exe");
		Assert.same({
			file: "C:\\cmd.exe",
			args: ["/d", "/s", "/c", '"C:\\Program^ Files\\Haxe\\haxelib.cmd ^"run^" ^"lime^" ^"C:\\My^ Game\\\\^" ^"say^ \\^"hi\\^"^" ^"100^%^""'],
			verbatim: true
		}, start);
		// Two backslashes before a quote become five: four for the backslashes, one for the quote.
		Assert.equals('"x.cmd ^"a\\\\\\\\\\^"b^""', Exec.windowsStart("x.cmd", ['a\\\\"b'], "cmd.exe").args[3]);
	}

	function testNpmShimsAreEscapedTwice() {
		Assert.equals('"C:\\game\\node_modules\\.bin\\haxe.cmd ^^^"a^^^ b^^^""',
			Exec.windowsStart("C:\\game\\node_modules\\.bin\\haxe.cmd", ["a b"], "cmd.exe").args[3]);
	}

	function testUrisCompareWindowsSpellings() {
		Assert.isTrue(Uris.sameFile("file:///d%3A/a/Game/Main.hx", "file:///D:/a/game/main.hx", true));
		Assert.isFalse(Uris.sameFile("file:///d%3A/a/Game/Main.hx", "file:///D:/a/game/main.hx", false));
		Assert.isFalse(Uris.sameFile("file:///D:/a/Main.hx", "file:///D:/a/Other.hx", true));
		Assert.equals("file:///D:/a/x.hx", Uris.withDrive("file:///d%3A/a/x.hx"));
		Assert.equals("file:///home/x.hx", Uris.withDrive("file:///home/x.hx"));
	}

	function testServerUrisGetZedsSpelling() {
		final uris = new ClientUris(true);
		uris.learn({method: "textDocument/didOpen", params: {textDocument: {uri: "file:///D:/a/My%20Game/src/Main.hx", text: "class Main {}"}}});

		final diagnostics:Dynamic = {
			method: "textDocument/publishDiagnostics",
			params: {
				uri: "file:///d%3A/a/My%20Game/src/Main.hx",
				diagnostics: [{message: "file:///d%3A/stays.hx is text", relatedInformation: [{location: {uri: "file:///d%3A/a/My%20Game/src/Other.hx"}}]}]
			}
		};
		uris.respell(diagnostics);
		Assert.equals("file:///D:/a/My%20Game/src/Main.hx", diagnostics.params.uri);
		// Not open in Zed: only the drive is respelled.
		Assert.equals("file:///D:/a/My%20Game/src/Other.hx", diagnostics.params.diagnostics[0].relatedInformation[0].location.uri);
		Assert.equals("file:///d%3A/stays.hx is text", diagnostics.params.diagnostics[0].message);

		final edit:Dynamic = {id: 3, result: {changes: {"file:///d%3A/a/My%20Game/src/Main.hx": [{newText: "x"}]}}};
		uris.respell(edit);
		Assert.same(["file:///D:/a/My%20Game/src/Main.hx"], Reflect.fields(edit.result.changes));

		final elsewhere:Dynamic = {params: {uri: "file:///d%3A/a/x.hx"}};
		new ClientUris(false).respell(elsewhere);
		Assert.equals("file:///d%3A/a/x.hx", elsewhere.params.uri);
	}
}
