package bridge.project;

import bridge.project.ProjectProvider;
import bridge.util.Files;
import haxe.io.Path;
import js.Node.process;
import js.lib.Promise;
import sys.FileSystem;
import sys.io.File;

/**
	Plain hxml projects. Every `.hxml` file under the project root is a "target";
	the best-scoring one is the default.
**/
class HxmlProvider implements ProjectProvider {
	/** Flags that give a compilation an output target. Without one, Haxe types for the "cross" target. **/
	static final outputFlags = [
		"-js", "--js", "-cpp", "--cpp", "--cppia", "-hl", "--hl", "-neko", "--neko", "-python", "--python", "-lua", "--lua", "-php", "--php",
		"-cs", "--cs", "-java", "--java", "--jvm", "-swf", "--swf", "-x", "--interp", "--run", "--custom-target"
	];

	public var name(default, null):String = "hxml";
	public var priority(default, null):Int = 0;

	public function new() {}

	/**
		The hxml files that can drive completion, best first. Ones using `--run` are left out: `--run` passes
		everything after it to the program, and the language server adds its own arguments after the hxml.
	**/
	public function detect(ctx:ProjectContext):Array<String> {
		final found = [
			for (file in hxmlFiles(ctx)) {
				final info = read(file.path, []);
				if (!info.runs) {path: file.path, score: score(file.path, file.depth, info)}
			}
		];
		found.sort((a, b) -> b.score - a.score);
		return found.map(file -> file.path);
	}

	public function targets(ctx:ProjectContext, file:String):Promise<Array<String>> {
		return Promise.resolve(detect(ctx).map(path -> relative(ctx.projectRoot, path)));
	}

	public function resolve(ctx:ProjectContext, file:String, target:Null<String>):Promise<ProviderResult> {
		final hxml = target == null ? file : Path.join([ctx.projectRoot, target]);
		final dir = Path.directory(hxml);
		// The compiler resolves paths inside an hxml relative to the working directory,
		// so run it from the hxml's own folder, as users do on the command line.
		final args = if (Path.normalize(dir) == Path.normalize(ctx.workspaceRoot)) {
			[Path.withoutDirectory(hxml)];
		} else {
			["--cwd", dir, Path.withoutDirectory(hxml)];
		}
		return Promise.resolve({args: args, watch: [Path.withoutDirectory(hxml)]});
	}

	public function watch():Array<String> {
		return [];
	}

	/**
		`haxe <file>` for every hxml that builds something; ones only included by others are skipped.
		Files using `--run` can't be targets (see `detect`), but running them is what they are for.
	**/
	public function tasks(ctx:ProjectContext, file:String, targets:Array<String>):Array<TaskSpec> {
		final runs = [for (file in hxmlFiles(ctx)) if (read(file.path, []).runs) relative(ctx.projectRoot, file.path)];
		return [
			for (target in targets.concat(runs)) {
				final path = Path.join([ctx.projectRoot, target]);
				final info = read(path, []);
				if (info.hasOutput) {
					{
						label: 'haxe: $target',
						command: ["haxe", Path.withoutDirectory(path)],
						cwd: Path.directory(path),
						target: target,
						debug: debugFor(ctx, path, info)
					};
				}
			}
		];
	}

	/** How the Haxe debugger runs `path`, or null for targets it can't debug (and for `--run`). **/
	static function debugFor(ctx:ProjectContext, path:String, info:HxmlInfo):Null<TaskDebug> {
		final hxml = Path.withoutDirectory(path);
		return switch info.target {
			case "interp" | "cpp" | "hl" | "js":
				{hxml: hxml};
			case "cppia":
				// A script needs the host that runs it; without one there's nothing to debug.
				final program = cppiaHost(ctx, path, info);
				program == null ? null : {hxml: hxml, program: program};
			case _:
				null;
		}
	}

	/**
		The executable that runs a cppia script, relative to the script's hxml: built by the hxml with
		`-D scriptable` whose `--cpp` folder holds the script, and named like hxcpp names it: the main
		class (or `-D HAXE_OUTPUT_FILE`), `-debug` (or `-D DEBUGSUFFIX`) for a debug build, `.exe` on Windows.
	**/
	static function cppiaHost(ctx:ProjectContext, scriptHxml:String, script:HxmlInfo):Null<String> {
		final dir = Path.directory(scriptHxml);
		if (script.output == null) {
			return null;
		}
		final scriptFile = absolute(dir, script.output);
		for (file in hxmlFiles(ctx)) {
			final host = read(file.path, []);
			if (host.target != "cpp" || host.output == null || !host.defines.exists("scriptable")) {
				continue;
			}
			final hostDir = absolute(Path.directory(file.path), host.output);
			final name = host.defines.get("HAXE_OUTPUT_FILE") ?? host.main?.split(".").pop();
			if (name == null || !StringTools.startsWith(scriptFile, Path.addTrailingSlash(hostDir))) {
				continue;
			}
			final suffix = host.debug ? (host.defines.get("DEBUGSUFFIX") ?? "-debug") : "";
			return relative(dir, Path.join([hostDir, name + suffix + (process.platform == "win32" ? ".exe" : "")]));
		}
		return null;
	}

	static function absolute(base:String, path:String):String {
		return Path.normalize(Path.isAbsolute(path) ? path : Path.join([base, path]));
	}

	public function buildTypes():Array<String> {
		return [];
	}

	/**
		Prefers files that build something (an hxml that is only included by others, like `common.hxml`,
		has no target and can't be used on its own), then the ones that see the most of the project's own
		class paths (files outside every class path get no completion), then obvious "editor" or "main build"
		names near the root.
	**/
	static function score(path:String, depth:Int, info:HxmlInfo):Int {
		final name = Path.withoutDirectory(path).toLowerCase();
		var score = -20 * depth + (info.hasOutput ? 40 : -40) + 15 * info.classPaths.length;
		if (Lambda.exists(["lsp", "devenv", "display", "completion"], word -> name.indexOf(word) >= 0)) score += 100;
		if (name.indexOf("main") >= 0) score += 50;
		if (name.indexOf("build") >= 0 || name.indexOf("compile") >= 0) score += 30;
		if (name.indexOf("include") >= 0 || name.indexOf("common") >= 0) score -= 50;
		if (name.indexOf("test") >= 0 || name.indexOf("debug") >= 0) score -= 10;
		if (name.indexOf("sample") >= 0) score -= 5;
		return score;
	}

	static function hxmlFiles(ctx:ProjectContext):Array<{path:String, depth:Int}> {
		return [for (file in Files.findByExtension(ctx.projectRoot, ".hxml", 3)) if (Path.withoutDirectory(file.path) != "extraParams.hxml") file];
	}

	/**
		What an hxml (with the hxml files it includes) sets: its output target, class paths, main class,
		`--debug` and defines. Later arguments win, as in the compiler.
	**/
	static function read(path:String, seen:Array<String>):HxmlInfo {
		final info:HxmlInfo = {hasOutput: false, runs: false, classPaths: [], debug: false, defines: new Map()};
		if (seen.contains(path) || !FileSystem.exists(path)) {
			return info;
		}
		seen.push(path);
		final args = try Hxml.parse(File.getContent(path)) catch (_) [];
		for (i in 0...args.length) {
			final arg = args[i];
			final next = i + 1 < args.length ? args[i + 1] : null;
			if (outputFlags.contains(arg)) {
				info.hasOutput = true;
				info.runs = info.runs || arg == "--run";
				info.target = arg == "-x" ? "interp" : StringTools.replace(arg, "-", "");
				info.output = arg == "--interp" || arg == "-x" || arg == "--run" ? null : next;
				if (arg == "-x" || arg == "--run") {
					info.main = next;
				}
			} else if ((arg == "-main" || arg == "--main" || arg == "-m") && next != null) {
				info.main = next;
			} else if (arg == "--debug" || arg == "-debug") {
				info.debug = true;
			} else if ((arg == "-D" || arg == "--define") && next != null) {
				// The compiler treats - and _ in define names alike.
				final equals = next.indexOf("=");
				final name = StringTools.replace(equals < 0 ? next : next.substr(0, equals), "-", "_");
				info.defines.set(name, equals < 0 ? "1" : next.substr(equals + 1));
			} else if ((arg == "-cp" || arg == "-p" || arg == "--class-path") && i + 1 < args.length) {
				final classPath = Path.normalize(args[i + 1]);
				if (!info.classPaths.contains(classPath)) {
					info.classPaths.push(classPath);
				}
			} else if (StringTools.endsWith(arg, ".hxml")) {
				final included = read(Path.join([Path.directory(path), arg]), seen);
				info.hasOutput = info.hasOutput || included.hasOutput;
				info.runs = info.runs || included.runs;
				if (included.target != null) {
					info.target = included.target;
					info.output = included.output;
				}
				if (included.main != null) {
					info.main = included.main;
				}
				info.debug = info.debug || included.debug;
				for (name => value in included.defines) {
					info.defines.set(name, value);
				}
				for (classPath in included.classPaths) {
					if (!info.classPaths.contains(classPath)) {
						info.classPaths.push(classPath);
					}
				}
			}
		}
		return info;
	}

	static function relative(root:String, path:String):String {
		final prefix = Path.addTrailingSlash(Path.normalize(root));
		final normalized = Path.normalize(path);
		return StringTools.startsWith(normalized, prefix) ? normalized.substr(prefix.length) : normalized;
	}
}

private typedef HxmlInfo = {
	var hasOutput:Bool;
	var runs:Bool;
	var classPaths:Array<String>;

	/** The output flag without dashes (`cpp`, `cppia`, `hl`, `js`, `interp`, `run`, ...) and its path. **/
	var ?target:String;

	var ?output:String;
	var ?main:String;
	var debug:Bool;
	var defines:Map<String, String>;
}
