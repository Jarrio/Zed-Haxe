package bridge.util;

import haxe.DynamicAccess;
import haxe.io.Path;
import js.Node.process;
import sys.FileSystem;

class Files {
	/** Folders never searched for project files. `haxe_modules` holds git-submodule libraries (gsm). **/
	public static final ignoredFolders = [
		".git", ".haxelib", ".zed", "node_modules", "haxe_libraries", "haxe_modules", "Export", "export", "bin", "dump", "out"
	];

	/**
		Finds files named one of `names` in `root` and its subfolders, up to `maxDepth` levels down.
		Shallower matches come first; within a folder, `names` order decides.
	**/
	public static function findByName(root:String, names:Array<String>, maxDepth:Int):Array<String> {
		return find(root, maxDepth, file -> names.contains(file)).map(match -> match.path);
	}

	/** Finds files whose name ends with `extension` (e.g. `".hxml"`), shallowest first. **/
	public static function findByExtension(root:String, extension:String, maxDepth:Int):Array<{path:String, depth:Int}> {
		return find(root, maxDepth, file -> StringTools.endsWith(file, extension));
	}

	static function find(root:String, maxDepth:Int, matches:String->Bool):Array<{path:String, depth:Int}> {
		final result = [];
		var level = [root];
		for (depth in 0...maxDepth + 1) {
			final next = [];
			for (dir in level) {
				final entries = try FileSystem.readDirectory(dir) catch (_) [];
				entries.sort(Reflect.compare);
				for (entry in entries) {
					final path = Path.join([dir, entry]);
					final isDir = try FileSystem.isDirectory(path) catch (_) false;
					if (isDir) {
						// A folder with a haxelib.json is a library kept inside the project, not part of it.
						if (!ignoredFolders.contains(entry) && !StringTools.startsWith(entry, ".")
							&& !FileSystem.exists(Path.join([path, "haxelib.json"]))) {
							next.push(path);
						}
					} else if (matches(entry)) {
						result.push({path: path, depth: depth});
					}
				}
			}
			level = next;
		}
		return result;
	}

	/** Looks up an executable on `PATH`, like the `which` command. **/
	public static function which(name:String, env:DynamicAccess<String>):Null<String> {
		final windows = process.platform == "win32";
		final pathVariable = env.get(windows ? "Path" : "PATH") ?? env.get("PATH") ?? "";
		final extensions = windows ? ["", ".exe", ".cmd", ".bat"] : [""];
		for (dir in pathVariable.split(windows ? ";" : ":")) {
			if (dir == "") {
				continue;
			}
			for (extension in extensions) {
				final candidate = Path.join([dir, name + extension]);
				if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate)) {
					return candidate;
				}
			}
		}
		return null;
	}

	/** Returns `dir/name` or `dir/name.exe`, whichever exists. **/
	public static function executableIn(dir:String, name:String):Null<String> {
		for (candidate in [Path.join([dir, name]), Path.join([dir, name + ".exe"])]) {
			if (FileSystem.exists(candidate) && !FileSystem.isDirectory(candidate)) {
				return candidate;
			}
		}
		return null;
	}
}
