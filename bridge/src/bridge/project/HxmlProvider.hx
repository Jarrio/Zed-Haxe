package bridge.project;

import bridge.project.ProjectProvider;
import bridge.util.Files;
import haxe.io.Path;
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

	public function detect(ctx:ProjectContext):Array<String> {
		final found = [
			for (file in Files.findByExtension(ctx.projectRoot, ".hxml", 3))
				if (Path.withoutDirectory(file.path) != "extraParams.hxml") {path: file.path, score: score(file.path, file.depth)}
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

	/** `haxe <file>` for every hxml that builds something; ones only included by others are skipped. **/
	public function tasks(ctx:ProjectContext, file:String, targets:Array<String>):Array<TaskSpec> {
		return [
			for (target in targets) {
				final path = Path.join([ctx.projectRoot, target]);
				if (read(path, []).hasOutput) {
					{label: 'haxe: $target', command: ["haxe", Path.withoutDirectory(path)], cwd: Path.directory(path), target: target};
				}
			}
		];
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
	static function score(path:String, depth:Int):Int {
		final name = Path.withoutDirectory(path).toLowerCase();
		final info = read(path, []);
		var score = -20 * depth + (info.hasOutput ? 40 : -40) + 15 * info.classPaths.length;
		if (name.indexOf("lsp") >= 0 || name.indexOf("devenv") >= 0 || name.indexOf("display") >= 0) score += 100;
		if (name.indexOf("main") >= 0) score += 50;
		if (name.indexOf("build") >= 0 || name.indexOf("compile") >= 0) score += 30;
		if (name.indexOf("include") >= 0 || name.indexOf("common") >= 0) score -= 50;
		if (name.indexOf("test") >= 0 || name.indexOf("debug") >= 0) score -= 10;
		if (name.indexOf("sample") >= 0) score -= 5;
		return score;
	}

	/** Whether the hxml (or an hxml it includes) sets an output target, and the class paths it adds. **/
	static function read(path:String, seen:Array<String>):{hasOutput:Bool, classPaths:Array<String>} {
		final info = {hasOutput: false, classPaths: []};
		if (seen.contains(path) || !FileSystem.exists(path)) {
			return info;
		}
		seen.push(path);
		final args = try Hxml.parse(File.getContent(path)) catch (_) [];
		for (i in 0...args.length) {
			final arg = args[i];
			if (outputFlags.contains(arg)) {
				info.hasOutput = true;
			} else if ((arg == "-cp" || arg == "-p" || arg == "--class-path") && i + 1 < args.length) {
				final classPath = Path.normalize(args[i + 1]);
				if (!info.classPaths.contains(classPath)) {
					info.classPaths.push(classPath);
				}
			} else if (StringTools.endsWith(arg, ".hxml")) {
				final included = read(Path.join([Path.directory(path), arg]), seen);
				info.hasOutput = info.hasOutput || included.hasOutput;
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
