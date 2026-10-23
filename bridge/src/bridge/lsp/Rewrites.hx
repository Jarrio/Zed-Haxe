package bridge.lsp;

import bridge.Settings.ProjectSettings;
import bridge.project.DocPacks;
import bridge.project.ProjectProvider.ProjectContext;
import bridge.project.ProjectResolver;
import bridge.lsp.CompilerDocs.DocContext;
import bridge.lsp.Documents.Position;
import bridge.lsp.Ranking.EditingContext;
import bridge.lsp.Ranking.PrivateMembers;
import bridge.rpc.Message;
import bridge.toolchain.Haxerc;
import bridge.toolchain.Toolchain;
import bridge.util.Exec;
import bridge.util.Files;
import haxe.DynamicAccess;
import haxe.Json;
import haxe.io.Path;
import js.Node.process;
import js.lib.Promise;
import js.node.Url;
import js.node.url.URL;
import sys.FileSystem;

private enum abstract MessageType(Int) to Int {
	final Error = 1;
	final Warning = 2;
	final Info = 3;
}

/**
	The messages the bridge changes on their way between Zed and haxe-language-server.
	Anything not listed in `fromClient` / `fromServer` passes through untouched.

	This is the only part of the bridge that knows about LSP and Zed. Project detection
	(`bridge.project`) and Haxe selection (`bridge.toolchain`) are plain functions of a folder and settings.
**/
class Rewrites {
	/** Opens the target buttons. `haxe.selectTarget` is the older name, still accepted. **/
	static inline final chooseTargetCommand = "Haxe: choose target";

	static final targetCommand = ~/^Haxe: target (.+?)( \(current\))?$/;
	static final buildTypeCommand = ~/^Haxe: build type (.+?)( \(current\))?$/;

	/** Extra completion triggers for markup: `<` for tags, `"` for attribute values, `/` for closing tags. **/
	static final markupTriggers = ["<", "\"", "/"];

	final bridge:Router;
	final state:State;
	final documents = new Documents();
	final docs:CompilerDocs;
	final markup:MarkupFeature;
	final serverCache:ServerCache;

	/** Hover and completion requests whose answers get define/metadata docs added, by request id. **/
	final docRequests = new Map<String, {method:String, context:DocContext}>();

	/** Completion requests whose answers get ranked (`Ranking`), by request id, with what is being edited. **/
	final completionRequests = new Map<String, EditingContext>();

	var clientCapabilities:Dynamic = {};
	var workspaceRoot:String = process.cwd();
	var settings:ProjectSettings = {};

	/** `displayArguments` / `displayServerConfig` given explicitly in Zed's initialization_options. **/
	var userDisplayArguments:Null<Array<String>>;
	var userDisplayServer:DynamicAccess<Dynamic> = {};

	var project:Null<ResolvedProject>;
	var toolchain:Null<ResolvedToolchain>;

	var initializeId:Dynamic;
	var initialized = false;

	/** Zed messages that arrive while `initialize` waits for project detection. **/
	var held:Null<Array<Message>>;

	/** Target and build type picked with the `Haxe: ...` commands; they win over the settings for this session. **/
	var targetOverride:Null<String>;
	var buildTypeOverride:Null<String>;

	/** The command list last given to Zed, to only re-register it when it changes. **/
	var registeredCommands:Null<String>;

	var tasksWarned = false;
	var warnings:Array<String> = [];
	var reresolveTimer:Null<haxe.Timer>;
	var resolving = false;
	var resolveAgain = false;

	public function new(bridge:Router, ?state:State) {
		this.bridge = bridge;
		this.state = state ?? new State();
		docs = new CompilerDocs(bridge, displayArguments);
		markup = new MarkupFeature(bridge, documents, displayArguments, () -> workspaceRoot, privateMembers);
		serverCache = new ServerCache(bridge, documents);
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
				// VS Code sends this on every tab switch; the server uses it for diagnostics and `package` completion.
				bridge.notifyServer("haxe/didChangeActiveTextEditor", {uri: message.params.textDocument.uri});
			case "textDocument/didChange":
				documents.change(message.params.textDocument.uri, message.params.contentChanges);
				bridge.toServer(message);
			case "textDocument/didClose":
				documents.close(message.params.textDocument.uri);
				bridge.toServer(message);
			case "textDocument/didSave":
				bridge.toServer(message);
				final path = uriToPath(message.params.textDocument.uri);
				if (path != null) {
					markup.fileChanged(path);
					serverCache.filesChanged([path]);
				}
			case "textDocument/completion" | "textDocument/hover" | "textDocument/definition" | "textDocument/signatureHelp"
				if (markupEnabled() && markup.handleHaxe(message)):
				// Inside markup such as HaxeUI's @:xml: answered by the bridge.
			case "textDocument/completion" if (markupTriggers.contains(message.params.context?.triggerCharacter)):
				// A markup trigger character typed in ordinary Haxe code.
				bridge.replyToClient(message.id, {isIncomplete: false, items: []});
			case "textDocument/hover" | "textDocument/completion":
				rememberDocContext(message);
				if (message.method == "textDocument/completion" && !docRequests.exists(Std.string(message.id))) {
					rememberCompletion(message);
				}
				bridge.toServer(message);
			case "completionItem/resolve" if (message.params.data?.haxeZed == true):
				// One of the bridge's own items: markup attributes get their docs now, the rest are complete.
				markup.resolveItem(message);
			case "workspace/symbol" if (toolchain != null && toolchain.major >= 5):
				WorkspaceSymbols.handle(bridge, message);
			case "workspace/executeCommand" if (isBridgeCommand(message.params.command)):
				bridge.replyToClient(message.id, null);
				runCommand(message.params.command);
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
					final enclosing = completionRequests.get(Std.string(message.id));
					completionRequests.remove(Std.string(message.id));
					rankCompletion(message, enclosing);
				}
				if (message.id == initializeId && message.result != null) {
					patchCapabilities(message.result.capabilities);
				}
				bridge.toClient(message);
			case "client/registerCapability":
				filterRegistrations(message, "registrations");
			case "client/unregisterCapability":
				filterRegistrations(message, "unregisterations");
			case "haxe/listLibraries":
				listLibraries(message);
			case "haxe/cacheBuildFailed":
				Log.info('completion cache build failed with: ${describeArgs()}');
				showMessage(Warning, 'Haxe: building the completion cache failed${describeTarget()}. '
					+ "The project may not compile as configured; the language server log has the compiler output.");
			case "haxe/haxeKeepsCrashing":
				showMessage(Error, "Haxe: the compiler keeps crashing. See the language server log for details.");
			case "haxe/didDetectOldHaxeVersion":
				showMessage(Warning, 'Haxe ${message.params.version} is too old for haxe-language-server. Use Haxe 4.3 or newer.');
			case "haxe/didRunHaxeMethod" | "haxe/didChangeRequestQueue" | "haxe/didChangeDisplayPort" | "haxe/didRunGlobalDiagnostics" |
				"haxe/executeClientCommand":
				// Feed vshaxe's VS Code views; Zed has nowhere to show them.
			case _:
				bridge.toClient(message);
		}
	}

	function onInitialize(message:Message) {
		final params = message.params;
		initializeId = message.id;
		clientCapabilities = params.capabilities ?? {};
		markup.snippets = clientCapabilities.textDocument?.completion?.completionItem?.snippetSupport == true;
		workspaceRoot = rootPath(params) ?? process.cwd();

		final options:DynamicAccess<Dynamic> = params.initializationOptions ?? {};
		settings = options.get("project") ?? {};
		options.remove("project");
		userDisplayArguments = options.get("displayArguments");
		userDisplayServer = options.get("displayServerConfig") ?? {};
		applyTraceFile();

		held = [];
		resolveProject().then(function(_) {
			options.set("displayArguments", displayArguments());
			options.set("displayServerConfig", displayServerConfig());
			params.initializationOptions = options;
			Log.info(describe());
			bridge.toServer(message);
			writeTasks();

			final queued = held;
			held = null;
			for (queuedMessage in queued) {
				fromClient(queuedMessage);
			}
		});
	}

	function onInitialized() {
		initialized = true;
		registerFileWatchers();
		registerMarkupFiles();
		flushWarnings();
		// Plain hxml projects usually have one obvious build file, so only ask for framework targets.
		if (project?.provider != "hxml" && !state.wasPrompted(projectRoot()) && settings.target == null) {
			promptForTarget();
		}
	}

	function onDidChangeConfiguration(message:Message) {
		final all:DynamicAccess<Dynamic> = message.params.settings ?? {};
		final next:ProjectSettings = all.get("project") ?? {};
		all.remove("project");
		all.remove("server");
		message.params.settings = all;
		bridge.toServer(message);

		if (Json.stringify(next) != Json.stringify(settings)) {
			settings = next;
			applyTraceFile();
			scheduleReresolve("settings changed");
		}
	}

	function onDidChangeWatchedFiles(message:Message) {
		bridge.toServer(message);
		final reported:Null<Array<{uri:String, type:Int}>> = message.params.changes;
		final changes = reported ?? [];
		final paths = [];
		for (change in changes) {
			final changed = uriToPath(change.uri);
			if (changed != null) {
				markup.fileChanged(changed);
				paths.push(changed);
			}
		}
		serverCache.filesChanged(paths);
		for (change in changes) {
			final path = uriToPath(change.uri);
			if (path != null && isProjectFile(path)) {
				scheduleReresolve('${Path.withoutDirectory(path)} changed');
				return;
			}
		}
	}

	function privateMembers():PrivateMembers {
		return settings.privateMembers ?? Last;
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

	function markupEnabled():Bool {
		return settings.markup != false;
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
			case "textDocument/completion" | "textDocument/hover" | "textDocument/definition" | "textDocument/signatureHelp" if (markupEnabled()):
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

	function isProjectFile(path:String):Bool {
		final current = project;
		if (current == null) {
			return false;
		}
		final name = Path.withoutDirectory(path);
		return name == ".haxerc"
			|| current.watch.contains(name)
			|| (current.provider == "hxml" && StringTools.endsWith(name, ".hxml"))
			|| (current.file != null && Path.normalize(current.file) == Path.normalize(path));
	}

	/** Re-runs detection shortly after a burst of changes, then tells the server what changed. **/
	function scheduleReresolve(reason:String) {
		if (reresolveTimer != null) {
			reresolveTimer.stop();
		}
		reresolveTimer = haxe.Timer.delay(() -> reresolve(reason), 300);
	}

	function reresolve(reason:String) {
		if (resolving) {
			resolveAgain = true;
			return;
		}
		resolving = true;
		final argsBefore = Json.stringify(displayArguments());
		final serverBefore = Json.stringify(displayServerConfig());
		final toolchainBefore = toolchain;
		final done = startProgress('Haxe: updating project ($reason)');
		resolveProject().then(function(_) {
			if (Json.stringify(displayServerConfig()) != serverBefore) {
				if (needsFullRestart(toolchainBefore, toolchain)) {
					showMessage(Warning, 'Haxe changed from ${toolchainBefore?.version} to ${toolchain?.version}. '
						+ "Restart the language server to use it: haxe-language-server can't switch a Haxe 4 project with a .haxerc to Haxe 5 in place.");
					// Keep describing the Haxe the server still runs.
					toolchain = toolchainBefore;
				} else {
					bridge.notifyServer("haxe/didChangeDisplayServerConfig", displayServerConfig());
				}
			}
			if (Json.stringify(displayArguments()) != argsBefore) {
				bridge.notifyServer("haxe/didChangeDisplayArguments", {arguments: displayArguments()});
			}
			docs.invalidate();
			markup.reset();
			Log.info(describe());
			writeTasks();
			updateCommands();
			done();
			flushWarnings();
			resolving = false;
			if (resolveAgain) {
				resolveAgain = false;
				reresolve("further changes");
			}
		});
	}

	/**
		The server talks to Haxe 4 over stdio when the workspace has a `.haxerc`, and to Haxe 5 over a socket.
		Restarting from the first mode into the second fails inside the server (IO.No_more_input).
	**/
	function needsFullRestart(before:Null<ResolvedToolchain>, after:Null<ResolvedToolchain>):Bool {
		return before != null && after != null && before.major < 5 && after.major >= 5
			&& FileSystem.exists(Path.join([workspaceRoot, ".haxerc"]));
	}

	/** Runs project detection and toolchain selection. Never rejects. **/
	function resolveProject():Promise<Bool> {
		final root = projectRoot();
		final ctx:ProjectContext = {
			workspaceRoot: workspaceRoot,
			projectRoot: root,
			settings: effectiveSettings(),
			env: process.env
		};
		return ProjectResolver.resolve(ctx, state.target(root)).then(function(resolved) {
			project = resolved;
			final haxerc = Haxerc.find(root, workspaceRoot);
			toolchain = Toolchain.resolve({
				workspaceRoot: workspaceRoot,
				projectRoot: root,
				haxerc: haxerc?.data,
				providerHaxePath: resolved.haxePath,
				env: process.env
			}, settings);
			warnings = warnings.concat(resolved.warnings).concat(toolchain.notes);
			if (haxerc?.data.resolveLibs == "scoped" && toolchain.source != "lix") {
				warnings.push('${haxerc.path} uses lix-style libraries (haxe_libraries/), but Haxe comes from ${toolchain.source}. '
					+ "If libraries are missing, run `hx lix-libs` (haxe-manager) or install lix.");
			}
			return true;
		}, function(error) {
			warnings.push('Haxe project detection failed: $error');
			return true;
		});
	}

	function projectRoot():String {
		return settings.root == null ? workspaceRoot : Path.join([workspaceRoot, settings.root]);
	}

	/** What the server receives as `displayArguments`. **/
	function displayArguments():Array<String> {
		final userArgs = userDisplayArguments;
		if (userArgs != null) {
			return userArgs;
		}
		final current = project;
		if (current == null) {
			return [];
		}
		if (!supportsDocPacks() || current.docs.length == 0) {
			return current.args;
		}
		return DocPacks.macros(current.docs, current.args, projectRoot(), Path.join([state.dir, "docs"])).concat(current.args);
	}

	/** What the server receives as `displayServerConfig`; the user's own values win. **/
	function displayServerConfig():DynamicAccess<Dynamic> {
		final haxe = toolchain;
		final env:DynamicAccess<String> = haxe == null ? {} : haxe.env.copy();
		final userEnv:Null<DynamicAccess<String>> = userDisplayServer.get("env");
		if (userEnv != null) {
			for (key => value in userEnv) {
				env.set(key, value);
			}
		}
		final path = haxe == null ? "haxe" : haxe.path;
		final config:DynamicAccess<Dynamic> = {
			// The server starts Haxe through a shell, so paths with spaces need quotes.
			path: path.indexOf(" ") >= 0 ? '"$path"' : path,
			env: env,
			arguments: [],
			useSocket: true,
			print: {completion: false, reusing: false}
		};
		for (key => value in userDisplayServer) {
			if (key != "env") {
				config.set(key, value);
			}
		}
		return config;
	}

	function supportsDocPacks():Bool {
		final version = toolchain?.version;
		if (version == null) {
			return false;
		}
		final parts = version.split(".").map(Std.parseInt);
		return parts[0] > 4 || (parts[0] == 4 && parts[1] >= 3);
	}

	/**
		The server only registers Go to Type Definition and Go to Implementation at runtime,
		which Zed ignores. Declare them up front instead, and add the bridge's own command.
	**/
	function patchCapabilities(capabilities:Dynamic) {
		capabilities.typeDefinitionProvider = true;
		capabilities.implementationProvider = true;
		if (capabilities.completionProvider?.triggerCharacters != null) {
			addTriggers(capabilities.completionProvider.triggerCharacters);
		}
		final existing:Null<Array<String>> = capabilities.executeCommandProvider?.commands;
		final commands = (existing ?? []).concat(bridgeCommands());
		registeredCommands = Json.stringify(commands);
		capabilities.executeCommandProvider = {commands: commands};
	}

	/**
		The commands Zed lists in `lsp command selector: toggle`, which is the closest Zed has to a
		target switcher: extensions can't add status bar items.
	**/
	function bridgeCommands():Array<String> {
		final commands = [chooseTargetCommand];
		final current = project;
		if (current == null) {
			return commands;
		}
		for (target in current.targets) {
			commands.push('Haxe: target $target' + (target == current.target ? " (current)" : ""));
		}
		final buildType = currentBuildType();
		for (type in current.buildTypes) {
			commands.push('Haxe: build type $type' + (type == buildType ? " (current)" : ""));
		}
		return commands;
	}

	/** Zed replaces the startup command list with the latest registration, so the whole list is sent each time. **/
	function updateCommands() {
		final commands = bridgeCommands();
		final json = Json.stringify(commands);
		if (json == registeredCommands || clientCapabilities.workspace?.executeCommand?.dynamicRegistration != true) {
			return;
		}
		registeredCommands = json;
		bridge.requestClient("client/registerCapability", {
			registrations: [
				{
					id: "haxe-zed-commands",
					method: "workspace/executeCommand",
					registerOptions: {commands: commands}
				}
			]
		}).then(null, error -> Log.info('Zed refused the command list: ${Json.stringify(error)}'));
	}

	function isBridgeCommand(command:String):Bool {
		return command == chooseTargetCommand || command == "haxe.selectTarget" || targetCommand.match(command) || buildTypeCommand.match(command);
	}

	function runCommand(command:String) {
		final root = projectRoot();
		if (targetCommand.match(command)) {
			targetOverride = targetCommand.matched(1);
			state.setTarget(root, targetCommand.matched(1));
			scheduleReresolve('target "${targetCommand.matched(1)}" picked');
		} else if (buildTypeCommand.match(command)) {
			buildTypeOverride = buildTypeCommand.matched(1);
			state.setBuildType(root, buildTypeCommand.matched(1));
			scheduleReresolve('build type "${buildTypeCommand.matched(1)}" picked');
		} else {
			promptForTarget();
		}
	}

	/** The settings with the target and build type picked by command applied. **/
	function effectiveSettings():ProjectSettings {
		final effective:ProjectSettings = Reflect.copy(settings) ?? {};
		effective.target = targetOverride ?? settings.target;
		effective.buildType = buildTypeOverride ?? settings.buildType ?? state.buildType(projectRoot());
		return effective;
	}

	function currentBuildType():Null<String> {
		final types = project?.buildTypes ?? [];
		final chosen = effectiveSettings().buildType;
		return chosen ?? (types.contains("release") ? "release" : null);
	}

	/** Writes the project's tasks to `.zed/tasks.json`, unless turned off or the file is the user's. **/
	function writeTasks() {
		final current = project;
		if (settings.tasks == false || current == null || current.tasks.length == 0) {
			return;
		}
		// Haxe from PATH stays `haxe`, so the file works on any machine; a project-specific Haxe
		// (haxe-manager, lix, Ceramic's) is written out with its std path.
		final haxe = toolchain;
		final fromPath = haxe == null || haxe.source == "path" || haxe.source == "default";
		final content = ZedTasks.render(current.tasks, workspaceRoot, {
			haxe: fromPath ? "haxe" : haxe.path,
			haxelib: fromPath ? "haxelib" : haxelibExecutable(),
			env: fromPath ? {} : haxe.env
		}, current.target);
		try {
			switch ZedTasks.write(workspaceRoot, content) {
				case Written:
					Log.info('wrote ${current.tasks.length} tasks to ${ZedTasks.path(workspaceRoot)}');
				case NotOurs if (!tasksWarned):
					tasksWarned = true;
					Log.info('${ZedTasks.path(workspaceRoot)} is your own file, so the Haxe tasks were not written to it');
				case _:
			}
		} catch (e) {
			Log.info('could not write ${ZedTasks.path(workspaceRoot)}: $e');
		}
	}

	function filterRegistrations(message:Message, field:String) {
		final staticMethods = ["textDocument/typeDefinition", "textDocument/implementation"];
		final listed:Null<Array<{method:String}>> = Reflect.field(message.params, field);
		final all = listed ?? [];
		for (registration in all) {
			// Haxe completion also triggers on markup characters, for HaxeUI's @:xml.
			final options:Dynamic = (cast registration).registerOptions;
			if (registration.method == "textDocument/completion" && options?.triggerCharacters != null
				&& Json.stringify(options.documentSelector).indexOf('"haxe"') >= 0) {
				addTriggers(options.triggerCharacters);
			}
		}
		final kept = all.filter(registration -> !staticMethods.contains(registration.method));
		if (kept.length == 0) {
			bridge.replyToServer(message.id, null);
			return;
		}
		Reflect.setField(message.params, field, kept);
		bridge.toClient(message);
	}

	static function addTriggers(triggers:Array<String>) {
		for (trigger in markupTriggers) {
			if (!triggers.contains(trigger)) {
				triggers.push(trigger);
			}
		}
	}

	/**
		Asks Zed for completion, hover, go to definition and signature help in `.xml` files too, which the
		server never registers, so the bridge can answer them for UI layouts (HaxeUI). The XML language
		comes from Zed's XML extension.
	**/
	function registerMarkupFiles() {
		if (!markupEnabled()) {
			return;
		}
		final selector = [{language: "xml"}];
		final wanted:Array<{method:String, capability:String, options:Dynamic}> = [
			{
				method: "textDocument/completion",
				capability: "completion",
				options: {documentSelector: selector, triggerCharacters: ["<", " ", "\"", "/", ".", "("], resolveProvider: true}
			},
			{method: "textDocument/hover", capability: "hover", options: {documentSelector: selector}},
			{method: "textDocument/definition", capability: "definition", options: {documentSelector: selector}},
			{method: "textDocument/signatureHelp", capability: "signatureHelp", options: {documentSelector: selector, triggerCharacters: ["(", ","]}}
		];
		final registrations = [
			for (entry in wanted)
				if (Reflect.field(clientCapabilities.textDocument ?? {}, entry.capability)?.dynamicRegistration == true)
					{id: 'haxe-zed-markup-${entry.capability}', method: entry.method, registerOptions: entry.options}
		];
		if (registrations.length > 0) {
			bridge.requestClient("client/registerCapability", {registrations: registrations})
				.then(null, error -> Log.info('Zed refused markup registrations: ${Json.stringify(error)}'));
		}
	}

	/** Lets Zed tell the server about created and deleted files, which it otherwise never does. **/
	function registerFileWatchers() {
		if (clientCapabilities.workspace?.didChangeWatchedFiles?.dynamicRegistration != true) {
			return;
		}
		final globs = ["**/*.hx", "**/*.hxml", "**/.haxerc", "**/module.xml"];
		for (name in project?.watch ?? []) {
			final glob = '**/$name';
			if (!globs.contains(glob)) {
				globs.push(glob);
			}
		}
		bridge.requestClient("client/registerCapability", {
			registrations: [
				{
					id: "haxe-zed-file-watchers",
					method: "workspace/didChangeWatchedFiles",
					registerOptions: {watchers: [for (glob in globs) {globPattern: glob}]}
				}
			]
		}).then(null, error -> Log.info('Zed refused the file watchers: ${Json.stringify(error)}'));
	}

	/** Offers the detected targets as buttons. Shown once per project, or on `Haxe: choose target`. **/
	function promptForTarget() {
		final current = project;
		if (current == null || current.targets.length < 2) {
			return;
		}
		final root = projectRoot();
		state.setPrompted(root);
		final targets = current.targets.slice(0, 12);
		bridge.requestClient("window/showMessageRequest", {
			type: Info,
			message: 'Haxe: using the ${current.provider} target "${current.target}". Pick another target, or set `project.target` in your settings.',
			actions: [for (target in targets) {title: target}]
		}).then(function(choice:Null<{title:String}>) {
			if (choice == null) {
				return;
			}
			state.setTarget(root, choice.title);
			if (choice.title != current.target) {
				targetOverride = choice.title;
				scheduleReresolve('target "${choice.title}" picked');
			}
		}, error -> Log.info('target prompt failed: ${Json.stringify(error)}'));
	}

	/** Answers the server's request for library names (used for `-lib` completion in hxml files). **/
	function listLibraries(message:Message) {
		final names = [];
		final scoped = Path.join([projectRoot(), "haxe_libraries"]);
		if (FileSystem.exists(scoped)) {
			for (file in FileSystem.readDirectory(scoped)) {
				if (StringTools.endsWith(file, ".hxml")) {
					names.push(Path.withoutExtension(file));
				}
			}
		}
		final haxelib = haxelibExecutable();
		final env = process.env.copy();
		for (key => value in toolchain?.env ?? {}) {
			env.set(key, value);
		}
		Exec.run([haxelib, "list"], {cwd: projectRoot(), env: env, timeout: 20000}).then(function(result) {
			for (line in result.stdout.split("\n")) {
				final colon = line.indexOf(":");
				if (colon > 0) {
					final name = StringTools.trim(line.substr(0, colon));
					if (!names.contains(name)) {
						names.push(name);
					}
				}
			}
			bridge.replyToServer(message.id, [for (name in names) {name: name}]);
		}, function(_) {
			bridge.replyToServer(message.id, [for (name in names) {name: name}]);
		});
	}

	/** haxelib next to the chosen Haxe (Ceramic and haxe-manager ship one), else from PATH. **/
	function haxelibExecutable():String {
		final haxe = toolchain?.path;
		if (haxe != null && Path.isAbsolute(haxe)) {
			final sibling = Files.executableIn(Path.directory(haxe), "haxelib");
			if (sibling != null) {
				return sibling;
			}
		}
		return "haxelib";
	}

	function startProgress(title:String):() -> Void {
		if (!initialized || clientCapabilities.window?.workDoneProgress != true) {
			return function() {};
		}
		final token = 'haxe-zed-progress-${Date.now().getTime()}';
		bridge.requestClient("window/workDoneProgress/create", {token: token}).then(null, _ -> null);
		bridge.notifyClient("$/progress", {token: token, value: {kind: "begin", title: title}});
		return () -> bridge.notifyClient("$/progress", {token: token, value: {kind: "end"}});
	}

	function showMessage(type:MessageType, message:String) {
		bridge.notifyClient("window/showMessage", {type: type, message: message});
	}

	/** Warnings collected before `initialized` are shown afterwards, all at once. **/
	function flushWarnings() {
		if (!initialized || warnings.length == 0) {
			return;
		}
		for (warning in warnings) {
			Log.info('warning: $warning');
		}
		showMessage(Warning, warnings.join("\n\n"));
		warnings = [];
	}

	function applyTraceFile() {
		final file = settings.traceFile ?? process.env.get("HAXE_ZED_TRACE");
		Log.traceFile = file == "" ? null : file;
	}

	function describe():String {
		final current = project;
		final haxe = toolchain;
		final target = current?.target == null ? "" : ' target=${current.target}';
		return 'project: provider=${current?.provider}$target args=${describeArgs()} haxe=${haxe?.path} (${haxe?.source}, ${haxe?.version ?? "version unknown"})';
	}

	function describeTarget():String {
		final current = project;
		if (current == null || current.target == null) {
			return "";
		}
		return ' for the ${current.provider} target "${current.target}"';
	}

	function describeArgs():String {
		return displayArguments().join(" ");
	}

	static function rootPath(params:Dynamic):Null<String> {
		if (params.rootUri != null) {
			return uriToPath(params.rootUri);
		}
		return params.rootPath;
	}

	public static function uriToPath(uri:String):Null<String> {
		return try Url.fileURLToPath(new URL(uri)) catch (_) null;
	}

	public static function pathToUri(path:String):String {
		return Url.pathToFileURL(path).href;
	}
}
