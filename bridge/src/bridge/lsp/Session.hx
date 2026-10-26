package bridge.lsp;

import bridge.Settings.ProjectSettings;
import bridge.lsp.Client.MessageType;
import bridge.project.DocPacks;
import bridge.project.ProjectProvider.ProjectContext;
import bridge.project.ProjectProvider.TaskSpec;
import bridge.project.ProjectResolver;
import bridge.toolchain.Haxerc;
import bridge.toolchain.Toolchain;
import bridge.util.Exec;
import bridge.util.Files;
import bridge.util.Uris;
import haxe.DynamicAccess;
import haxe.Json;
import haxe.io.Path;
import js.Node.process;
import js.lib.Promise;
import sys.FileSystem;

/**
	The workspace this language server runs for: its settings, the detected project and the Haxe it
	uses, kept up to date when settings, project files or the picked target change.

	Project detection (`bridge.project`) and Haxe selection (`bridge.toolchain`) are plain functions
	of a folder and settings; this is where their results meet the server.
**/
class Session {
	public var workspaceRoot(default, null):String = process.cwd();
	public var settings(default, null):ProjectSettings = {};
	public var project(default, null):Null<ResolvedProject>;
	public var toolchain(default, null):Null<ResolvedToolchain>;
	public final state:State;

	/** Called after the project was resolved again, to refresh what depends on it. **/
	public var onChanged:() -> Void = () -> {};

	final bridge:Router;
	final client:Client;

	/** `displayArguments` / `displayServerConfig` given explicitly in Zed's initialization_options. **/
	var userDisplayArguments:Null<Array<String>>;
	var userDisplayServer:DynamicAccess<Dynamic> = {};

	/** Target and build type picked with the `Haxe: ...` commands; they win over the settings for this session. **/
	var targetOverride:Null<String>;
	var buildTypeOverride:Null<String>;

	var tasksWarned = false;
	var debugWarned = false;
	var reresolveTimer:Null<haxe.Timer>;
	var resolving = false;
	var resolveAgain = false;

	public function new(bridge:Router, client:Client, state:State) {
		this.bridge = bridge;
		this.client = client;
		this.state = state;
	}

	/**
		Reads Zed's `initialize` parameters and resolves the project. The result is what the server
		receives as `initializationOptions`, with the display arguments and Haxe filled in.
	**/
	public function initialize(params:Dynamic):Promise<DynamicAccess<Dynamic>> {
		workspaceRoot = rootPath(params) ?? process.cwd();
		final options:DynamicAccess<Dynamic> = params.initializationOptions ?? {};
		settings = options.get("project") ?? {};
		options.remove("project");
		userDisplayArguments = options.get("displayArguments");
		userDisplayServer = options.get("displayServerConfig") ?? {};
		applyTraceFile();
		return resolveProject().then(function(_) {
			options.set("displayArguments", displayArguments());
			options.set("displayServerConfig", displayServerConfig());
			Log.info(describe());
			writeTasks();
			return options;
		});
	}

	public function updateSettings(next:ProjectSettings) {
		if (Json.stringify(next) != Json.stringify(settings)) {
			settings = next;
			applyTraceFile();
			scheduleReresolve("settings changed");
		}
	}

	/** Uses `target` from now on (picked by command or prompt), and remembers it for the project. **/
	public function pickTarget(target:String) {
		targetOverride = target;
		state.setTarget(projectRoot(), target);
		scheduleReresolve('target "$target" picked');
	}

	public function pickBuildType(buildType:String) {
		buildTypeOverride = buildType;
		state.setBuildType(projectRoot(), buildType);
		scheduleReresolve('build type "$buildType" picked');
	}

	/** Re-resolves when one of `paths` is a project file (an hxml, `project.xml`, `.haxerc`...). **/
	public function filesChanged(paths:Array<String>) {
		for (path in paths) {
			if (isProjectFile(path)) {
				scheduleReresolve('${Path.withoutDirectory(path)} changed');
				return;
			}
		}
	}

	public function projectRoot():String {
		return settings.root == null ? workspaceRoot : Path.join([workspaceRoot, settings.root]);
	}

	public function markupEnabled():Bool {
		return settings.markup != false;
	}

	/** What the server receives as `displayArguments`. **/
	public function displayArguments():Array<String> {
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

	public function currentBuildType():Null<String> {
		final types = project?.buildTypes ?? [];
		final chosen = effectiveSettings().buildType;
		return chosen ?? (types.contains("release") ? "release" : null);
	}

	/** Library names for `-lib` completion in hxml files: lix's `haxe_libraries/`, then `haxelib list`. **/
	public function libraryNames():Promise<Array<String>> {
		final names = [];
		final scoped = Path.join([projectRoot(), "haxe_libraries"]);
		if (FileSystem.exists(scoped)) {
			for (file in FileSystem.readDirectory(scoped)) {
				if (StringTools.endsWith(file, ".hxml")) {
					names.push(Path.withoutExtension(file));
				}
			}
		}
		final env = process.env.copy();
		for (key => value in toolchain?.env ?? {}) {
			env.set(key, value);
		}
		return Exec.run([haxelibExecutable(), "list"], {cwd: projectRoot(), env: env, timeout: 20000}).then(function(result) {
			for (line in result.stdout.split("\n")) {
				final colon = line.indexOf(":");
				if (colon > 0) {
					final name = StringTools.trim(line.substr(0, colon));
					if (!names.contains(name)) {
						names.push(name);
					}
				}
			}
			return names;
		}, _ -> names);
	}

	public function describe():String {
		final current = project;
		final haxe = toolchain;
		final target = current?.target == null ? "" : ' target=${current.target}';
		return 'project: provider=${current?.provider}$target args=${describeArgs()} haxe=${haxe?.path} (${haxe?.source}, ${haxe?.version ?? "version unknown"})';
	}

	/** ` for the lime target "html5"`, or nothing when there are no targets. **/
	public function describeTarget():String {
		final current = project;
		if (current == null || current.target == null) {
			return "";
		}
		return ' for the ${current.provider} target "${current.target}"';
	}

	public function describeArgs():String {
		return displayArguments().join(" ");
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
		final done = client.startProgress('Haxe: updating project ($reason)');
		resolveProject().then(function(_) {
			if (Json.stringify(displayServerConfig()) != serverBefore) {
				if (needsFullRestart(toolchainBefore, toolchain)) {
					client.showMessage(Warning, 'Haxe changed from ${toolchainBefore?.version} to ${toolchain?.version}. '
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
			Log.info(describe());
			writeTasks();
			onChanged();
			done();
			client.flushWarnings();
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
			for (warning in resolved.warnings.concat(toolchain.notes)) {
				client.warn(warning);
			}
			if (haxerc?.data.resolveLibs == "scoped" && toolchain.source != "lix") {
				client.warn('${haxerc.path} uses lix-style libraries (haxe_libraries/), but Haxe comes from ${toolchain.source}. '
					+ "If libraries are missing, run `hx lix-libs` (haxe-manager) or install lix.");
			}
			return true;
		}, function(error) {
			client.warn('Haxe project detection failed: $error');
			return true;
		});
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

	/** The settings with the target and build type picked by command applied. **/
	function effectiveSettings():ProjectSettings {
		final effective:ProjectSettings = Reflect.copy(settings) ?? {};
		effective.target = targetOverride ?? settings.target;
		effective.buildType = buildTypeOverride ?? settings.buildType ?? state.buildType(projectRoot());
		return effective;
	}

	/** Writes the project's tasks to `.zed/tasks.json`, unless turned off or the file is the user's. **/
	function writeTasks() {
		final current = project;
		// Off with the tasks unless set on its own: turning tasks off means no generated files in .zed.
		if (current != null && (settings.debugConfigurations ?? settings.tasks) != false) {
			writeDebugConfigurations(current.tasks, current.target);
		}
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

	/** `.zed/debug.json` for the Haxe debugger extension, from the same tasks (see `ZedDebug`). **/
	function writeDebugConfigurations(tasks:Array<TaskSpec>, target:Null<String>) {
		final file = ZedDebug.path(workspaceRoot);
		final count = [for (task in tasks) if (task.debug != null) task].length;
		try {
			switch ZedDebug.write(workspaceRoot, ZedDebug.render(tasks, workspaceRoot, target), count) {
				case Written:
					Log.info('wrote $count debug configurations to $file');
				case NotOurs if (!debugWarned):
					debugWarned = true;
					Log.info('$file is your own file, so the Haxe debug configurations were not written to it');
				case _:
			}
		} catch (e) {
			Log.info('could not write $file: $e');
		}
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

	function applyTraceFile() {
		final file = settings.traceFile ?? process.env.get("HAXE_ZED_TRACE");
		Log.traceFile = file == "" ? null : file;
	}

	static function rootPath(params:Dynamic):Null<String> {
		if (params.rootUri != null) {
			return Uris.toPath(params.rootUri);
		}
		return params.rootPath;
	}
}
