import bridge.Router;
import bridge.State;
import bridge.lsp.Rewrites;
import bridge.rpc.Message;
import bridge.util.Uris;
import haxe.Timer;
import haxe.io.Path;
import js.lib.Promise;
import utest.Assert;
import utest.Async;

/** Records what the bridge sends to each side; requests resolve with `null`. **/
class RecordingRouter implements Router {
	public final server:Array<Message> = [];
	public final client:Array<Message> = [];

	public function new() {}

	public function toServer(message:Message)
		server.push(message);

	public function toClient(message:Message)
		client.push(message);

	public function notifyServer(method:String, params:Dynamic)
		server.push({method: method, params: params});

	public function notifyClient(method:String, params:Dynamic)
		client.push({method: method, params: params});

	public function requestServer(method:String, params:Dynamic):Promise<Dynamic> {
		server.push({id: "bridge", method: method, params: params});
		return Promise.resolve(null);
	}

	public function requestClient(method:String, params:Dynamic):Promise<Dynamic> {
		client.push({id: "bridge", method: method, params: params});
		return Promise.resolve(null);
	}

	public function replyToServer(id:Dynamic, result:Dynamic)
		server.push({id: id, result: result});

	public function replyToClient(id:Dynamic, result:Dynamic)
		client.push({id: id, result: result});

	public function sentToServer(method:String):Null<Message> {
		return Lambda.find(server, m -> m.method == method);
	}
}

/** The messages the bridge changes between Zed and the server. **/
class RewritesTest extends utest.Test {
	@:timeout(15000)
	function testInitializeGetsDisplayArgumentsAndHaxe(async:Async) {
		final dir = Fixture.create({"build.hxml": "-cp src"});
		final router = new RecordingRouter();
		final rewrites = initialize(router, dir, {haxePath: "/fake/haxe"});
		waitFor(() -> router.sentToServer("initialize") != null, function() {
			final options = router.sentToServer("initialize").params.initializationOptions;
			Assert.same(["build.hxml"], options.displayArguments);
			Assert.equals("/fake/haxe", options.displayServerConfig.path);
			Assert.isFalse(Reflect.hasField(options, "project"));

			// The answer to initialize declares the two methods the server only registers later.
			rewrites.fromServer({id: 1, result: {capabilities: {}}});
			final capabilities = router.client[router.client.length - 1].result.capabilities;
			Assert.isTrue(capabilities.typeDefinitionProvider);
			Assert.isTrue(capabilities.implementationProvider);
			Assert.same(["Haxe: choose target", "Haxe: target build.hxml (current)"], capabilities.executeCommandProvider.commands);
			async.done();
		});
	}

	@:timeout(15000)
	function testMessagesWaitForInitialize(async:Async) {
		final dir = Fixture.create({"build.hxml": ""});
		final router = new RecordingRouter();
		final rewrites = initialize(router, dir, {});
		rewrites.fromClient({method: "$/cancelRequest", params: {id: 0}});
		Assert.equals(0, router.server.length);
		waitFor(() -> router.server.length == 2, function() {
			Assert.equals("initialize", router.server[0].method);
			Assert.equals("$/cancelRequest", router.server[1].method);
			async.done();
		});
	}

	function testRuntimeRegistrationsAreFiltered() {
		final router = new RecordingRouter();
		final rewrites = new Rewrites(router, testState());
		rewrites.fromServer({
			id: 5,
			method: "client/registerCapability",
			params: {registrations: [{id: "a", method: "textDocument/typeDefinition"}, {id: "b", method: "textDocument/hover"}]}
		});
		Assert.same([{id: "b", method: "textDocument/hover"}], router.client[0].params.registrations);

		rewrites.fromServer({id: 6, method: "client/registerCapability", params: {registrations: [{id: "a", method: "textDocument/implementation"}]}});
		Assert.equals(1, router.client.length); // not forwarded...
		Assert.same({id: 6, result: null}, router.server[0]); // ...answered by the bridge
	}

	function testVsCodeOnlyNotificationsAreDropped() {
		final router = new RecordingRouter();
		final rewrites = new Rewrites(router, testState());
		rewrites.fromServer({method: "haxe/didChangeRequestQueue", params: {queue: []}});
		rewrites.fromServer({method: "haxe/cacheBuildFailed"});
		Assert.equals(1, router.client.length);
		// With a button, so Zed keeps it on screen instead of hiding it after five seconds.
		Assert.equals("window/showMessageRequest", router.client[0].method);
		Assert.same([{title: "OK"}], router.client[0].params.actions);
	}

	@:timeout(5000)
	function testTypeDefinitionIsAnsweredWhenHaxeFindsNothing(async:Async) {
		final router = new RecordingRouter();
		final rewrites = new Rewrites(router, testState());
		rewrites.fromClient({method: "textDocument/didOpen", params: {textDocument: {uri: "file:///p/src/Main.hx", text: "class Main {\n\tvar s = \"\u{1F600}\".charAt(0);\n}"}}});
		rewrites.fromClient({id: 7, method: "textDocument/typeDefinition", params: {textDocument: {uri: "file:///p/src/Main.hx"}, position: {line: 1, character: 15}}});
		final call = Lambda.find(router.server, m -> m.method == "haxe/runMethod" && m.params.method == "display/typeDefinition");
		Assert.notNull(call);
		Assert.equals("/p/src/Main.hx", call.params.params.file);
		Assert.equals(13 + 14, call.params.params.offset); // the emoji is two UTF-16 units but one code point
		Assert.isNull(router.sentToServer("textDocument/typeDefinition")); // the server's handler never answers when Haxe finds nothing
		// The recording router answers with null, as Haxe does for a function's type: Zed gets an empty list.
		waitFor(() -> router.client.length > 0, function() {
			Assert.same({id: 7, result: []}, router.client[0]);
			async.done();
		});
	}

	function testChangedHaxeFilesRefreshTheCompilerCache() {
		final router = new RecordingRouter();
		final rewrites = new Rewrites(router, testState());
		for (name in ["Base.hx", "Child.hx", "layout.xml"]) {
			rewrites.fromClient({method: "textDocument/didOpen", params: {textDocument: {uri: 'file:///p/src/$name', text: ""}}});
		}
		final compilerCalls = () -> [
			for (m in router.server)
				if (m.method == "haxe/runMethod") m.params.method + (m.params.params.file == null ? "" : " " + m.params.params.file)
		];
		final edit = (name:String) -> rewrites.fromClient({method: "textDocument/didChange", params: {textDocument: {uri: 'file:///p/src/$name'}, contentChanges: [{text: "x"}]}});
		final hover = (name:String) -> rewrites.fromClient({id: 1, method: "textDocument/hover", params: {textDocument: {uri: 'file:///p/src/$name'}, position: {line: 0, character: 0}}});

		// Opening files makes the server check the open files from disk: each is re-read when next used, once.
		router.server.resize(0);
		edit("Child.hx");
		hover("Child.hx");
		Assert.same(["server/invalidate /p/src/Child.hx"], compilerCalls());

		// Saving a Haxe file turns file checks back on, and the same happens again.
		rewrites.fromClient({method: "textDocument/didSave", params: {textDocument: {uri: "file:///p/src/Base.hx"}}});
		hover("Child.hx");
		Assert.same(["server/invalidate /p/src/Child.hx", "server/configure", "server/invalidate /p/src/Child.hx"], compilerCalls());

		// A Haxe file changed on disk does the same; other files change nothing.
		router.server.resize(0);
		rewrites.fromClient({method: "workspace/didChangeWatchedFiles", params: {changes: [{uri: "file:///p/assets/logo.png", type: 2}]}});
		edit("Child.hx");
		Assert.same([], compilerCalls());
		rewrites.fromClient({method: "workspace/didChangeWatchedFiles", params: {changes: [{uri: "file:///p/src/Gen.hx", type: 2}]}});
		edit("Base.hx");
		Assert.same(["server/configure", "server/invalidate /p/src/Base.hx"], compilerCalls());
	}

	@:timeout(15000)
	function testListLibrariesIsAnsweredByTheBridge(async:Async) {
		final dir = Fixture.create({"build.hxml": "", "haxe_libraries/mylib.hxml": ""});
		final router = new RecordingRouter();
		final rewrites = initialize(router, dir, {haxePath: "/fake/haxe"});
		waitFor(() -> router.sentToServer("initialize") != null, function() {
			rewrites.fromServer({id: 9, method: "haxe/listLibraries"});
			waitFor(() -> Lambda.exists(router.server, m -> m.id == 9), function() {
				final reply = Lambda.find(router.server, m -> m.id == 9);
				final names:Array<String> = [for (library in (reply.result : Array<{name:String}>)) library.name];
				Assert.contains("mylib", names);
				async.done();
			});
		});
	}

	@:timeout(15000)
	function testSettingsChangeUpdatesDisplayArguments(async:Async) {
		final dir = Fixture.create({"build.hxml": "", "other.hxml": ""});
		final router = new RecordingRouter();
		final rewrites = initialize(router, dir, {haxePath: "/fake/haxe"});
		waitFor(() -> router.sentToServer("initialize") != null, function() {
			rewrites.fromClient({
				method: "workspace/didChangeConfiguration",
				params: {settings: {project: {haxePath: "/fake/haxe", target: "other.hxml"}, server: {path: "/x"}, haxe: {enableCodeLens: true}}}
			});
			final forwarded = router.sentToServer("workspace/didChangeConfiguration");
			Assert.same({haxe: {enableCodeLens: true}}, forwarded.params.settings);
			waitFor(() -> router.sentToServer("haxe/didChangeDisplayArguments") != null, function() {
				Assert.same({arguments: ["other.hxml"]}, router.sentToServer("haxe/didChangeDisplayArguments").params);
				async.done();
			});
		});
	}

	@:timeout(15000)
	function testMarkupRequestsAreAnsweredByTheBridge(async:Async) {
		final dir = Fixture.create({"src/Hello.hx": ""});
		final router = new RecordingRouter();
		final rewrites = initialize(router, dir, {args: ["--library", "haxeui-core"], haxePath: "/fake/haxe"});
		final uri = Uris.fromPath('$dir/src/Hello.hx');
		final text = "@:xml('<vbox><but')\nclass Hello extends VBox {\n\tfunction f() {}\n}";
		waitFor(() -> router.sentToServer("initialize") != null, function() {
			rewrites.fromClient({method: "textDocument/didOpen", params: {textDocument: {uri: uri, text: text, languageId: "haxe", version: 1}}});
			// Inside @:xml: answered here, never sent to the server.
			rewrites.fromClient({id: 20, method: "textDocument/completion", params: {textDocument: {uri: uri}, position: {line: 0, character: 16}}});
			// In Haxe code: forwarded as usual.
			rewrites.fromClient({id: 21, method: "textDocument/completion", params: {textDocument: {uri: uri}, position: {line: 2, character: 14}}});
			// A markup trigger character in Haxe code: an empty answer instead of a popup.
			rewrites.fromClient({
				id: 22,
				method: "textDocument/completion",
				params: {textDocument: {uri: uri}, position: {line: 2, character: 14}, context: {triggerKind: 2, triggerCharacter: "<"}}
			});
			waitFor(() -> Lambda.exists(router.client, m -> m.id == 20), function() {
				final forwarded = router.server.filter(m -> m.method == "textDocument/completion").map(m -> m.id);
				Assert.same([21], forwarded);
				Assert.same({isIncomplete: false, items: []}, Lambda.find(router.client, m -> m.id == 22).result);
				async.done();
			});
		});
	}

	@:timeout(15000)
	function testXmlFilesNeverReachTheServer(async:Async) {
		final dir = Fixture.create({"build.hxml": ""});
		final router = new RecordingRouter();
		final rewrites = initialize(router, dir, {haxePath: "/fake/haxe"});
		final uri = Uris.fromPath('$dir/assets/main.xml');
		waitFor(() -> router.sentToServer("initialize") != null, function() {
			final before = router.server.length;
			rewrites.fromClient({method: "textDocument/didOpen", params: {textDocument: {uri: uri, text: "<vbox />", languageId: "xml", version: 1}}});
			rewrites.fromClient({id: 30, method: "textDocument/completion", params: {textDocument: {uri: uri}, position: {line: 0, character: 2}}});
			rewrites.fromClient({id: 31, method: "textDocument/documentColor", params: {textDocument: {uri: uri}}});
			waitFor(() -> Lambda.exists(router.client, m -> m.id == 30) && Lambda.exists(router.client, m -> m.id == 31), function() {
				Assert.equals(before, router.server.length);
				async.done();
			});
		});
	}

	function testHaxeCompletionTriggersIncludeMarkupCharacters() {
		final router = new RecordingRouter();
		final rewrites = new Rewrites(router, testState());
		rewrites.fromServer({
			id: 7,
			method: "client/registerCapability",
			params: {
				registrations: [
					{
						id: "haxeDocument/completion",
						method: "textDocument/completion",
						registerOptions: {documentSelector: [{language: "haxe", scheme: "file"}], triggerCharacters: [".", "@"]}
					},
					{
						id: "hxmlDocument/completion",
						method: "textDocument/completion",
						registerOptions: {documentSelector: [{language: "hxml", scheme: "file"}], triggerCharacters: ["-"]}
					}
				]
			}
		});
		final registrations:Array<Dynamic> = router.client[0].params.registrations;
		Assert.same([".", "@", "<", '"', "/"], registrations[0].registerOptions.triggerCharacters);
		Assert.same(["-"], registrations[1].registerOptions.triggerCharacters);
	}

	@:timeout(15000)
	function testXmlCapabilitiesAreRegistered(async:Async) {
		final dir = Fixture.create({"build.hxml": ""});
		final router = new RecordingRouter();
		final rewrites = new Rewrites(router, testState());
		rewrites.fromClient({
			id: 1,
			method: "initialize",
			params: {
				rootUri: Uris.fromPath(dir),
				capabilities: {textDocument: {completion: {dynamicRegistration: true}, hover: {dynamicRegistration: true}}},
				initializationOptions: {project: {haxePath: "/fake/haxe"}}
			}
		});
		waitFor(() -> router.sentToServer("initialize") != null, function() {
			rewrites.fromClient({method: "initialized", params: {}});
			final registration = Lambda.find(router.client, m -> m.method == "client/registerCapability");
			final methods = [for (r in (registration.params.registrations : Array<Dynamic>)) r.method];
			Assert.same(["textDocument/completion", "textDocument/hover"], methods);
			Assert.same([{language: "xml"}], registration.params.registrations[0].registerOptions.documentSelector);
			async.done();
		});
	}

	@:timeout(15000)
	function testTargetCommandsSwitchAndReRegister(async:Async) {
		final dir = Fixture.create({"game.cfg": ""});
		final provider = {
			name: "fake",
			priority: 100,
			detect: ["game.cfg"],
			targets: ["web", "desktop"],
			buildTypes: {debug: ["-debug"]},
			args: {command: Fixture.node("console.log('-D ' + process.argv[1])", ["${target}"])},
			tasks: [{label: "fake: run ${target}", command: ["haxe", "run.hxml", "${target}"]}]
		};
		final router = new RecordingRouter();
		final rewrites = new Rewrites(router, testState());
		rewrites.fromClient({
			id: 1,
			method: "initialize",
			params: {
				rootUri: Uris.fromPath(dir),
				capabilities: {workspace: {executeCommand: {dynamicRegistration: true}}},
				initializationOptions: {project: {haxePath: "/fake/haxe", providers: [provider]}}
			}
		});
		waitFor(() -> router.sentToServer("initialize") != null, function() {
			rewrites.fromServer({id: 1, result: {capabilities: {}}});
			final initial:Array<String> = router.client[router.client.length - 1].result.capabilities.executeCommandProvider.commands;
			Assert.same([
				"Haxe: choose target",
				"Haxe: target web (current)",
				"Haxe: target desktop",
				"Haxe: build type debug",
				"Haxe: build type release (current)"
			], initial);

			// The tasks were written for the detected targets, the current one first.
			final tasks = sys.io.File.getContent(Path.join([dir, ".zed", "tasks.json"]));
			Assert.isTrue(bridge.lsp.ZedTasks.isGenerated(tasks));
			Assert.isTrue(tasks.indexOf("fake: run web") < tasks.indexOf("fake: run desktop"));

			rewrites.fromClient({id: 40, method: "workspace/executeCommand", params: {command: "Haxe: target desktop", arguments: []}});
			Assert.same({id: 40, result: null}, Lambda.find(router.client, m -> m.id == 40));
			waitFor(() -> router.sentToServer("haxe/didChangeDisplayArguments") != null, function() {
				Assert.same({arguments: ["-D", "desktop"]}, router.sentToServer("haxe/didChangeDisplayArguments").params);
				final registration = Lambda.find(router.client, m -> m.method == "client/registerCapability" && m.params.registrations[0].id == "haxe-zed-commands");
				Assert.contains("Haxe: target desktop (current)", (registration.params.registrations[0].registerOptions.commands : Array<String>));
				async.done();
			});
		});
	}

	static function initialize(router:RecordingRouter, dir:String, project:Dynamic):Rewrites {
		final rewrites = new Rewrites(router, testState());
		rewrites.fromClient({
			id: 1,
			method: "initialize",
			params: {rootUri: Uris.fromPath(dir), capabilities: {}, initializationOptions: {project: project}}
		});
		return rewrites;
	}

	static function testState():State {
		return new State(Path.join([Fixture.create({}), "state"]));
	}

	/** Polls `condition` every 20 ms, then runs `then`; fails after 10 seconds. **/
	static function waitFor(condition:() -> Bool, then:() -> Void, waited = 0) {
		if (condition()) {
			then();
		} else if (waited > 10000) {
			Assert.fail("timed out");
		} else {
			Timer.delay(() -> waitFor(condition, then, waited + 20), 20);
		}
	}
}
