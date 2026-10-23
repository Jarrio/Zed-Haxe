package bridge.lsp;

import bridge.Settings.ProjectSettings;
import bridge.lsp.Client.MessageType;
import bridge.lsp.CompilerDocs.DocContext;
import bridge.lsp.Documents.Position;
import bridge.lsp.Ranking.EditingContext;
import bridge.lsp.Ranking.PrivateMembers;
import bridge.rpc.Message;
import bridge.util.Uris;
import haxe.DynamicAccess;

/**
	The messages the bridge changes on their way between Zed and haxe-language-server.
	Anything not listed in `fromClient` / `fromServer` passes through untouched.

	This is the routing; the work lives next to it: `Session` (the project and its Haxe),
	`TargetCommands`, `Registrations`, `MarkupFeature`, `CompilerDocs` and the smaller features.
**/
class Rewrites {
	final bridge:Router;
	final documents = new Documents();
	final client:Client;
	final session:Session;
	final commands:TargetCommands;
	final registrations:Registrations;
	final docs:CompilerDocs;
	final markup:MarkupFeature;
	final serverCache:ServerCache;

	/** Hover and completion requests whose answers get define/metadata docs added, by request id. **/
	final docRequests = new Map<String, {method:String, context:DocContext}>();

	/** Completion requests whose answers get ranked (`Ranking`), by request id, with what is being edited. **/
	final completionRequests = new Map<String, EditingContext>();

	var initializeId:Dynamic;

	/** Zed messages that arrive while `initialize` waits for project detection. **/
	var held:Null<Array<Message>>;

	/** The Haxe document opened last, as far as the bridge can tell the one in front. **/
	var lastOpened:Null<String>;

	/** The server's progress titles by token, to tell when its completion cache is built. **/
	final progressTitles = new Map<String, String>();

	public function new(bridge:Router, ?state:State) {
		this.bridge = bridge;
		client = new Client(bridge);
		session = new Session(bridge, client, state ?? new State());
		commands = new TargetCommands(bridge, client, session);
		registrations = new Registrations(bridge, client, session, commands);
		docs = new CompilerDocs(bridge, session.displayArguments);
		markup = new MarkupFeature(bridge, documents, session.displayArguments, () -> session.workspaceRoot, privateMembers);
		serverCache = new ServerCache(bridge, documents);
		session.onChanged = function() {
			docs.invalidate();
			markup.reset();
			commands.update();
		};
	}

	/** Messages from Zed. **/
	public function fromClient(message:Message) {
		if (held != null) {
			held.push(message);
			return;
		}
		final uri:Null<String> = message.params?.textDocument?.uri;
		if (uri != null && !isServerDocument(uri)) {
			fromClientForMarkupFile(message, uri);
			return;
		}
		if (uri != null && (message.id != null || message.method == "textDocument/didChange")) {
			serverCache.beforeUse(uri);
		}
		switch message.method {
			case "initialize":
				onInitialize(message);
			case "initialized":
				bridge.toServer(message);
				onInitialized();
			case "workspace/didChangeConfiguration":
				onDidChangeConfiguration(message);
			case "workspace/didChangeWatchedFiles":
				onDidChangeWatchedFiles(message);
			case "textDocument/didOpen":
				documents.open(message.params.textDocument.uri, message.params.textDocument.text);
				bridge.toServer(message);
				serverCache.documentOpened();
				lastOpened = message.params.textDocument.uri;
				// VS Code sends this on every tab switch; the server uses it for diagnostics and `package` completion.
				bridge.notifyServer("haxe/didChangeActiveTextEditor", {uri: message.params.textDocument.uri});
			case "textDocument/didChange":
				documents.change(message.params.textDocument.uri, message.params.contentChanges);
				bridge.toServer(message);
			case "textDocument/didClose":
				documents.close(message.params.textDocument.uri);
				bridge.toServer(message);
				if (lastOpened == message.params.textDocument.uri) {
					lastOpened = null;
				}
			case "textDocument/didSave":
				bridge.toServer(message);
				final path = Uris.toPath(message.params.textDocument.uri);
				if (path != null) {
					markup.fileChanged(path);
					serverCache.filesChanged([path]);
				}
			case "textDocument/completion" | "textDocument/hover" | "textDocument/definition" | "textDocument/signatureHelp"
				if (session.markupEnabled() && markup.handleHaxe(message)):
				// Inside markup such as HaxeUI's @:xml: answered by the bridge.
			case "textDocument/completion" if (Registrations.markupTriggers.contains(message.params.context?.triggerCharacter)):
				// A markup trigger character typed in ordinary Haxe code.
				bridge.replyToClient(message.id, {isIncomplete: false, items: []});
			case "textDocument/hover" | "textDocument/completion":
				rememberDocContext(message);
				if (message.method == "textDocument/completion" && !docRequests.exists(Std.string(message.id))) {
					rememberCompletion(message);
				}
				bridge.toServer(message);
			case "textDocument/typeDefinition":
				Locations.handle(bridge, documents, message, "display/typeDefinition");
			case "textDocument/implementation":
				Locations.handle(bridge, documents, message, "display/implementation");
			case "completionItem/resolve" if (message.params.data?.haxeZed == true):
				// One of the bridge's own items: markup attributes get their docs now, the rest are complete.
				markup.resolveItem(message);
			case "workspace/symbol" if (session.toolchain != null && session.toolchain.major >= 5):
				WorkspaceSymbols.handle(bridge, message);
			case "workspace/executeCommand" if (commands.handles(message.params.command)):
				bridge.replyToClient(message.id, null);
				commands.run(message.params.command);
			case _:
				bridge.toServer(message);
		}
	}

	/** Messages from haxe-language-server. **/
	public function fromServer(message:Message) {
		switch message.method {
			case null:
				final docRequest = docRequests.get(Std.string(message.id));
				if (docRequest != null) {
					docRequests.remove(Std.string(message.id));
					final augmented = docRequest.method == "textDocument/hover" ? docs.hover(message, docRequest.context) : docs.completion(message,
						docRequest.context);
					augmented.then(bridge.toClient, _ -> bridge.toClient(message));
					return;
				}
				if (completionRequests.exists(Std.string(message.id))) {
					final context = completionRequests.get(Std.string(message.id));
					completionRequests.remove(Std.string(message.id));
					rankCompletion(message, context);
				}
				if (message.id == initializeId && message.result != null) {
					registrations.patchCapabilities(message.result.capabilities);
				}
				bridge.toClient(message);
			case "client/registerCapability":
				registrations.filter(message, "registrations");
			case "client/unregisterCapability":
				registrations.filter(message, "unregisterations");
			case "haxe/listLibraries":
				session.libraryNames().then(names -> bridge.replyToServer(message.id, [for (name in names) {name: name}]));
			case "haxe/cacheBuildFailed":
				Log.info('completion cache build failed with: ${session.describeArgs()}');
				client.showMessage(Warning, 'Haxe: building the completion cache failed${session.describeTarget()}. '
					+ "The project may not compile as configured; the language server log has the compiler output.");
			case "haxe/haxeKeepsCrashing":
				client.showMessage(Error, "Haxe: the compiler keeps crashing. See the language server log for details.");
			case "haxe/didDetectOldHaxeVersion":
				// The server sends this for Haxe 3 (it falls back to the old --display API) and Haxe 4 previews.
				client.showMessage(Warning, message.params.haxe4Preview == true
					? 'Haxe ${message.params.version} is a Haxe 4 preview, which haxe-language-server only partly supports. Use a Haxe 4 release or newer.'
					: 'Haxe ${message.params.version} is older than Haxe 4, so haxe-language-server falls back to a limited mode. Use Haxe 4 or newer.');
			case "$/progress":
				onServerProgress(message.params);
				bridge.toClient(message);
			case "haxe/didRunHaxeMethod" | "haxe/didChangeRequestQueue" | "haxe/didChangeDisplayPort" | "haxe/didRunGlobalDiagnostics" |
				"haxe/executeClientCommand":
				// Feed vshaxe's VS Code views; Zed has nowhere to show them.
			case _:
				bridge.toClient(message);
		}
	}

	/**
		The server builds its completion cache when Haxe (re)starts and when the display arguments change
		("Haxe: Building Cache..."). The build reads the project from disk, and files opened before it
		finished (tabs Zed restores at startup) never got their diagnostics: the server only checks files
		as they open. Announcing the front document again, as VS Code does on focus, makes it check them.
	**/
	function onServerProgress(params:Dynamic) {
		final token = Std.string(params?.token);
		switch params?.value?.kind {
			case "begin":
				progressTitles.set(token, params.value.title ?? "");
				serverCache.cacheRebuilding();
			case "end":
				final title = progressTitles.get(token);
				progressTitles.remove(token);
				if (title != null && title.indexOf("Building Cache") >= 0 && lastOpened != null) {
					// The server skips this within 0.1 s of the document opening (it checked it then), and a
					// small project builds its cache faster than that.
					final front = lastOpened;
					haxe.Timer.delay(() -> bridge.notifyServer("haxe/didChangeActiveTextEditor", {uri: front}), 200);
				}
			case _:
		}
	}

	function onInitialize(message:Message) {
		initializeId = message.id;
		client.capabilities = message.params.capabilities ?? {};
		markup.snippets = client.capabilities.textDocument?.completion?.completionItem?.snippetSupport == true;
		held = [];
		session.initialize(message.params).then(function(options) {
			message.params.initializationOptions = options;
			bridge.toServer(message);
			final queued = held;
			held = null;
			for (queuedMessage in queued) {
				fromClient(queuedMessage);
			}
		});
	}

	function onInitialized() {
		client.markInitialized();
		registrations.registerFileWatchers();
		registrations.registerMarkupFiles();
		client.flushWarnings();
		commands.promptOnce();
	}

	function onDidChangeConfiguration(message:Message) {
		final all:DynamicAccess<Dynamic> = message.params.settings ?? {};
		final next:ProjectSettings = all.get("project") ?? {};
		all.remove("project");
		all.remove("server");
		message.params.settings = all;
		bridge.toServer(message);
		session.updateSettings(next);
	}

	function onDidChangeWatchedFiles(message:Message) {
		bridge.toServer(message);
		final reported:Null<Array<{uri:String, type:Int}>> = message.params.changes;
		final paths = [];
		for (change in reported ?? []) {
			final path = Uris.toPath(change.uri);
			if (path != null) {
				markup.fileChanged(path);
				paths.push(path);
			}
		}
		serverCache.filesChanged(paths);
		session.filesChanged(paths);
	}

	function privateMembers():PrivateMembers {
		return session.settings.privateMembers ?? Last;
	}

	/** Notes a completion request so its answer can be ranked, with the class the cursor is in. **/
	function rememberCompletion(message:Message) {
		if (privateMembers() == Show) {
			return;
		}
		final uri:String = message.params.textDocument.uri;
		final text = documents.text(uri);
		final context:EditingContext = text == null ? {enclosingClass: null, declared: new Map()} : Ranking.editingContext(text, Documents.offsetAt(text, message.params.position));
		completionRequests.set(Std.string(message.id), context);
	}

	/** Puts private members and `_` internals of other classes last (or hides them) in the server's answer. **/
	function rankCompletion(message:Message, context:EditingContext) {
		final result:Dynamic = message.result;
		if (result == null) {
			return;
		}
		final isList = Std.isOfType(result, Array);
		final items:Array<Dynamic> = isList ? result : (result.items ?? []);
		final ranked = Ranking.apply(items, [for (item in items) Ranking.ofServerItem(item, context)], privateMembers());
		if (isList) {
			message.result = ranked;
		} else {
			result.items = ranked;
		}
	}

	/** Documents the server handles; other files (`.xml` layouts) only get markup support. **/
	static function isServerDocument(uri:String):Bool {
		final lower = uri.toLowerCase();
		return StringTools.endsWith(lower, ".hx") || StringTools.endsWith(lower, ".hxml");
	}

	/** Messages about a file the server doesn't handle, such as a HaxeUI `.xml` layout. **/
	function fromClientForMarkupFile(message:Message, uri:String) {
		switch message.method {
			case "textDocument/didOpen":
				documents.open(uri, message.params.textDocument.text);
			case "textDocument/didChange":
				documents.change(uri, message.params.contentChanges);
			case "textDocument/didClose":
				documents.close(uri);
			case "textDocument/completion" | "textDocument/hover" | "textDocument/definition" | "textDocument/signatureHelp" if (session.markupEnabled()):
				markup.handleFile(message);
			case _ if (message.id != null):
				bridge.replyToClient(message.id, null);
			case _:
		}
	}

	/** Notes hover/completion requests on a define or metadata name, so their answers can get docs. **/
	function rememberDocContext(message:Message) {
		final uri:String = message.params.textDocument.uri;
		final position:Position = message.params.position;
		if (!StringTools.endsWith(uri, ".hx")) {
			return;
		}
		final line = documents.line(uri, position.line);
		final context = line == null ? null : CompilerDocs.contextAt(line, position.character);
		if (context != null) {
			docRequests.set(Std.string(message.id), {method: message.method, context: context});
		}
	}
}
